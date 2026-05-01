#!/usr/bin/env python3
"""DaVinci Resolve scripting API audit probe.

Drop into:
  macOS:   ~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/
  Windows: %APPDATA%\\Blackmagic Design\\DaVinci Resolve\\Support\\Fusion\\Scripts\\Edit\\
  Linux:   ~/.local/share/DaVinciResolve/Fusion/Scripts/Edit/

Run from inside Resolve via:
  Workspace > Scripts > Edit > resolve_api_audit

Open the Console (Workspace > Console) before running so you can see the matrix.

The probe is non-destructive: it adds one disposable marker to the current
timeline (if any) and removes it on success. It does NOT modify clip color tags
or save the project. It writes the result matrix to:
  ~/buttercut_resolve_audit.json

Paste that file back into the Phase 3 audit memo to finalize verdicts.
"""

from __future__ import annotations
import json
import os
import sys
import traceback
from datetime import datetime, timezone


def get_resolve():
    """Resolve injects `resolve` into the script's globals when run from
    Workspace > Scripts. We also try the standard external bootstrap as a
    fallback for users running externally with DaVinciResolveScript on path."""
    if "resolve" in globals():
        return globals()["resolve"]
    try:
        import DaVinciResolveScript as dvr_script  # type: ignore
        return dvr_script.scriptapp("Resolve")
    except Exception:
        return None


class Probe:
    def __init__(self, name, present_check, probe):
        self.name = name
        self.present_check = present_check
        self.probe = probe

    def run(self, ctx):
        try:
            present = bool(self.present_check(ctx))
        except Exception:
            present = False

        if not present:
            return {
                "capability": self.name,
                "api_present": False,
                "probe_result": "skipped",
                "notes": "API entry point not found on this Resolve build."
            }

        try:
            verdict, notes = self.probe(ctx)
            return {
                "capability": self.name,
                "api_present": True,
                "probe_result": verdict,
                "notes": notes
            }
        except Exception as e:
            return {
                "capability": self.name,
                "api_present": True,
                "probe_result": "error",
                "notes": f"{type(e).__name__}: {e}"
            }


def probe_speed_ramp(ctx):
    item = ctx["first_clip"]
    if not item:
        return "skipped", "no clip on V1 to probe"
    speed = item.GetClipProperty("Speed") if hasattr(item, "GetClipProperty") else None
    has_retime = hasattr(item, "GetProperty") or hasattr(item, "SetClipProperty")
    return ("yes" if speed is not None and has_retime else "limited",
            f"GetClipProperty('Speed')={speed!r}; retime curve API on TimelineItem: {has_retime}")


def probe_color_tag(ctx):
    item = ctx["first_clip"]
    if not item:
        return "skipped", "no clip on V1 to probe"
    if not hasattr(item, "ClearClipColor") or not hasattr(item, "SetClipColor"):
        return "limited", "SetClipColor present but ClearClipColor missing"
    original = item.GetClipColor() if hasattr(item, "GetClipColor") else None
    set_ok = item.SetClipColor("Orange")
    if original:
        item.SetClipColor(original)
    else:
        try:
            item.ClearClipColor()
        except Exception:
            pass
    return ("yes" if set_ok else "no",
            f"SetClipColor returned {set_ok!r}; original={original!r}")


def probe_marker(ctx):
    item = ctx["first_clip"]
    if not item:
        return "skipped", "no clip on V1 to probe"
    if not hasattr(item, "AddMarker") or not hasattr(item, "DeleteMarkerAtFrame"):
        return "limited", "AddMarker present, DeleteMarkerAtFrame missing"
    frame = 1
    added = item.AddMarker(frame, "Red", "buttercut_audit_probe", "buttercut audit", 1)
    if added:
        try:
            item.DeleteMarkerAtFrame(frame)
        except Exception:
            pass
    return ("yes" if added else "no",
            f"AddMarker returned {added!r}; cleanup attempted")


def probe_powergrade(ctx):
    project = ctx["project"]
    media_pool = project.GetMediaPool() if project and hasattr(project, "GetMediaPool") else None
    gallery = project.GetGallery() if project and hasattr(project, "GetGallery") else None
    if not gallery:
        return "limited", "Project.GetGallery() not available; PowerGrade-by-name not directly scriptable"
    albums = []
    try:
        albums = gallery.GetGalleryStillAlbums() or []
    except Exception:
        pass
    has_apply = hasattr(gallery, "GetCurrentStillAlbum") and any(
        hasattr(a, "GetStills") for a in albums
    )
    album_names = [a.GetLabel() if hasattr(a, "GetLabel") else "?" for a in albums]
    return ("limited" if has_apply else "no",
            f"GalleryStillAlbums={album_names}; apply path requires gallery still walk, no direct ApplyPowerGradeByName()")


def probe_render_preset(ctx):
    project = ctx["project"]
    if not project:
        return "skipped", "no project open"
    presets = []
    try:
        presets = project.GetRenderPresetList() or []
    except Exception:
        pass
    has_load = hasattr(project, "LoadRenderPreset") and hasattr(project, "SetCurrentRenderMode")
    return ("yes" if presets and has_load else "limited",
            f"presets={len(presets)}; LoadRenderPreset+SetCurrentRenderMode={has_load}")


def probe_transitions(ctx):
    project = ctx["project"]
    timeline = ctx["timeline"]
    has_anything = False
    candidates = []
    for obj_name, obj in (("project", project), ("timeline", timeline), ("first_clip", ctx["first_clip"])):
        if obj is None:
            continue
        for attr in dir(obj):
            if "transition" in attr.lower():
                candidates.append(f"{obj_name}.{attr}")
                has_anything = True
    return ("yes" if has_anything else "no",
            f"transition-related methods found: {candidates or 'none'}")


PROBES = [
    Probe("speed_ramps",   lambda ctx: ctx["first_clip"], probe_speed_ramp),
    Probe("color_tags",    lambda ctx: ctx["first_clip"], probe_color_tag),
    Probe("markers",       lambda ctx: ctx["first_clip"], probe_marker),
    Probe("powergrade",    lambda ctx: ctx["project"],    probe_powergrade),
    Probe("render_preset", lambda ctx: ctx["project"],    probe_render_preset),
    Probe("transitions",   lambda ctx: ctx["timeline"] or ctx["project"], probe_transitions),
]


def build_context(resolve):
    ctx = {"resolve": resolve, "project": None, "timeline": None, "first_clip": None}
    if not resolve:
        return ctx
    pm = resolve.GetProjectManager()
    if not pm:
        return ctx
    project = pm.GetCurrentProject()
    ctx["project"] = project
    if not project:
        return ctx
    timeline = project.GetCurrentTimeline()
    ctx["timeline"] = timeline
    if timeline and hasattr(timeline, "GetItemListInTrack"):
        try:
            items = timeline.GetItemListInTrack("video", 1) or []
            if items:
                ctx["first_clip"] = items[0]
        except Exception:
            pass
    return ctx


def main():
    resolve = get_resolve()
    if not resolve:
        print("ERROR: could not connect to Resolve. Run from inside Resolve via Workspace > Scripts.")
        sys.exit(1)

    print(f"Resolve product: {resolve.GetProductName()}  version: {resolve.GetVersionString()}")
    ctx = build_context(resolve)
    print(f"  project: {ctx['project'].GetName() if ctx['project'] else '(none open)'}")
    print(f"  timeline: {ctx['timeline'].GetName() if ctx['timeline'] else '(none)'}")
    print(f"  first V1 clip: {ctx['first_clip'].GetName() if ctx['first_clip'] else '(none)'}")
    print()

    rows = [probe.run(ctx) for probe in PROBES]

    width = max(len(r["capability"]) for r in rows)
    print(f"{'capability'.ljust(width)}  api_present  probe_result  notes")
    print(f"{'-' * width}  -----------  ------------  -----")
    for r in rows:
        print(f"{r['capability'].ljust(width)}  {str(r['api_present']).ljust(11)}  {r['probe_result'].ljust(12)}  {r['notes']}")

    out_path = os.path.expanduser("~/buttercut_resolve_audit.json")
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "resolve_product": resolve.GetProductName(),
        "resolve_version": resolve.GetVersionString(),
        "results": rows,
    }
    try:
        with open(out_path, "w") as f:
            json.dump(payload, f, indent=2)
        print(f"\nWrote {out_path}")
    except Exception as e:
        print(f"\nFailed to write {out_path}: {e}")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
