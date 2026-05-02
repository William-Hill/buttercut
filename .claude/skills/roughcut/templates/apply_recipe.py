#!/usr/bin/env python3
"""Apply a ButterCut recipe.json to the current Resolve timeline.

This file is generated per-cut by .claude/skills/roughcut/generate_apply_script.rb.
The RECIPE_PATH constant below is stamped at generation time.

Run from inside Resolve:
  Workspace > Scripts > Edit > <name>_apply
or from the Console (Workspace > Console, switch to Py3):
  exec(open("<this file path>", encoding="utf-8").read())

Scope (locked by Sprint 1, Phase 3 audit on Resolve 20.2.3):
  applied:    color_tag, markers, render_preset, constant speed_ramps, powergrade (best-effort)
  logged:     multi-point speed_ramps, transitions, title_card
"""

from __future__ import annotations
import json
import os
import sys
import traceback


RECIPE_PATH = {{RECIPE_PATH}}


def get_resolve():
    if "resolve" in globals():
        return globals()["resolve"]
    try:
        import DaVinciResolveScript as dvr_script  # type: ignore
        return dvr_script.scriptapp("Resolve")
    except Exception:
        return None


class Applier:
    def __init__(self, recipe, project, timeline):
        self.recipe = recipe
        self.project = project
        self.timeline = timeline
        self.timeline_items = timeline.GetItemListInTrack("video", 1) or []
        self.frame_rate = self._get_frame_rate()
        self.counts = {
            "color_tags": [0, 0],
            "markers": [0, 0],
            "constant_speed_ramps": [0, 0],
            "render_preset": [0, 0],
            "powergrade": [0, 0],
        }
        self.manual = {"transitions": 0, "multi_point_ramps": 0, "constant_speed_ramps": 0, "title_card": 0}
        self.warnings = []

    def apply(self):
        self._apply_per_clip()
        self._apply_render_preset()
        self._apply_powergrade()
        self._log_manual_transitions()
        self._log_manual_title_card()
        self._report()

    def _get_frame_rate(self):
        try:
            rate = self.timeline.GetSetting("timelineFrameRate")
            return float(rate) if rate else 24.0
        except Exception:
            return 24.0

    def _clip_for(self, index):
        # Recipe indices are 1-based and align with YAML order. Timeline order
        # matches that order because export_to_fcpxml.rb writes clips in YAML
        # order with no skips (skipping raises).
        pos = index - 1
        if pos < 0 or pos >= len(self.timeline_items):
            self.warnings.append(f"clip {index}: not present on V1 (have {len(self.timeline_items)} items)")
            return None
        return self.timeline_items[pos]

    def _apply_per_clip(self):
        for clip in self.recipe.get("clips", []):
            idx = clip["index"]
            item = self._clip_for(idx)
            if not item:
                continue
            self._apply_color_tag(item, clip, idx)
            self._apply_markers(item, clip, idx)
            self._apply_speed_ramps(item, clip, idx)

    def _apply_color_tag(self, item, clip, idx):
        if "color_tag" not in clip:
            return
        self.counts["color_tags"][1] += 1
        try:
            ok = bool(item.SetClipColor(clip["color_tag"]))
            if ok:
                self.counts["color_tags"][0] += 1
            else:
                self.warnings.append(f"clip {idx}: SetClipColor({clip['color_tag']!r}) returned False")
        except Exception as e:
            self.warnings.append(f"clip {idx}: SetClipColor raised {type(e).__name__}: {e}")

    def _apply_markers(self, item, clip, idx):
        for marker in clip.get("markers", []):
            self.counts["markers"][1] += 1
            frame = int(round(marker["at"] * self.frame_rate))
            custom_data = f"buttercut:{marker['name']}"
            # Make idempotent: a previous apply may have placed a buttercut
            # marker at this same frame. Clear it before re-adding so the
            # script can be run repeatedly.
            try:
                if hasattr(item, "DeleteMarkerByCustomData"):
                    item.DeleteMarkerByCustomData(custom_data)
            except Exception:
                pass
            # Belt-and-braces: if a buttercut marker exists at the target
            # frame but its customData doesn't match (e.g. an old run used a
            # different name), remove it too — but ONLY when the marker's
            # customData is recognizably ours. Don't touch user markers that
            # happen to share the same frame.
            try:
                if hasattr(item, "GetMarkers") and hasattr(item, "DeleteMarkerAtFrame"):
                    markers = item.GetMarkers() or {}
                    existing = markers.get(frame) or markers.get(float(frame)) or markers.get(str(frame))
                    if existing and str(existing.get("customData", "")).startswith("buttercut:"):
                        item.DeleteMarkerAtFrame(frame)
            except Exception as e:
                self.warnings.append(
                    f"clip {idx}: marker cleanup at frame {frame} raised {type(e).__name__}: {e}"
                )
            try:
                ok = bool(item.AddMarker(frame, marker["color"], marker["name"], marker.get("note", ""), 1, custom_data))
                if ok:
                    self.counts["markers"][0] += 1
                else:
                    self.warnings.append(f"clip {idx}: AddMarker at frame {frame} returned False")
            except Exception as e:
                self.warnings.append(f"clip {idx}: AddMarker raised {type(e).__name__}: {e}")

    def _apply_speed_ramps(self, item, clip, idx):
        ramps = clip.get("speed_ramps", [])
        if not ramps:
            return
        if len(ramps) > 1:
            self.manual["multi_point_ramps"] += 1
            print(f"[apply_recipe] manual: multi-point ramp on clip {idx} — apply via Resolve retime curve")
            return
        self.counts["constant_speed_ramps"][1] += 1
        speed = ramps[0]["speed"]
        mpi = item.GetMediaPoolItem() if hasattr(item, "GetMediaPoolItem") else None
        # Resolve's speed API is flaky across versions; try the documented
        # paths in order, accept the first one that returns truthy.
        attempts = []
        if mpi:
            attempts += [
                ("MediaPoolItem.SetClipProperty('Speed', str)", lambda: mpi.SetClipProperty("Speed", str(speed))),
                ("MediaPoolItem.SetClipProperty('Speed', float)", lambda: mpi.SetClipProperty("Speed", float(speed) / 100.0)),
                ("MediaPoolItem.SetClipProperty('Speed Change', %)", lambda: mpi.SetClipProperty("Speed Change", f"{speed}%")),
            ]
        attempts += [
            ("TimelineItem.SetProperty('Speed', float)", lambda: item.SetProperty("Speed", float(speed) / 100.0) if hasattr(item, "SetProperty") else False),
        ]
        for label, fn in attempts:
            try:
                if bool(fn()):
                    self.counts["constant_speed_ramps"][0] += 1
                    return
            except Exception as e:
                self.warnings.append(f"clip {idx}: {label} raised {type(e).__name__}: {e}")
        # All attempts returned False or raised. Fall back to manual log,
        # not warning — speed scripting is unreliable enough that "apply
        # manually" is the right user instruction.
        self.manual["constant_speed_ramps"] += 1
        print(
            f"[apply_recipe] manual: constant ramp on clip {idx} → {speed}% — "
            f"set in Resolve (Inspector > Speed) since scripted set returned False"
        )

    def _apply_render_preset(self):
        preset = self.recipe.get("render_preset")
        if not preset:
            return
        self.counts["render_preset"][1] += 1
        candidates = self._render_preset_candidates(preset)
        try:
            available = self.project.GetRenderPresetList() or []
        except Exception:
            available = []
        match = next((name for name in candidates if name in available), None)
        if not match:
            self.warnings.append(
                f"render_preset: no available preset matched {candidates!r}; "
                f"available={available!r} — load matching preset manually"
            )
            return
        try:
            if bool(self.project.LoadRenderPreset(match)):
                self.project.SetCurrentRenderMode(0)
                self.counts["render_preset"][0] += 1
                print(f"[apply_recipe] loaded render preset: {match}")
            else:
                self.warnings.append(f"render_preset: LoadRenderPreset({match!r}) returned False")
        except Exception as e:
            self.warnings.append(f"render_preset: raised {type(e).__name__}: {e}")

    def _render_preset_candidates(self, preset):
        # Recipe encodes format/codec/resolution/bitrate_kbps; Resolve presets
        # are by name. Generate candidates that match Resolve's actual naming
        # conventions (dots in codec names, ' - ' separator in platform presets).
        codec = preset.get("codec", "")
        resolution = preset.get("resolution", "")
        codec_pretty = self._pretty_codec(codec)
        return [
            preset.get("name", ""),               # explicit name wins if set
            f"{codec_pretty} Master",             # "H.264 Master", "H.265 Master", "ProRes 422 HQ"
            f"YouTube - {resolution}",            # "YouTube - 1080p"
            f"Vimeo - {resolution}",
            f"TikTok - {resolution}",
            f"Dropbox - {resolution}",
            # Loose fallbacks
            f"YouTube {resolution}",
            f"{resolution} {codec_pretty}",
        ]

    def _pretty_codec(self, codec):
        # h264 -> H.264, h265 -> H.265, prores422hq -> ProRes 422 HQ (best-effort)
        c = codec.lower().strip()
        if c in ("h264", "avc"):
            return "H.264"
        if c in ("h265", "hevc"):
            return "H.265"
        return codec.upper() if codec else ""

    def _apply_powergrade(self):
        grade = self.recipe.get("powergrade")
        if not grade:
            return
        self.counts["powergrade"][1] += 1
        name = grade.get("name", "")
        try:
            gallery = self.project.GetGallery()
            if not gallery:
                self.warnings.append(f"powergrade: no gallery — apply '{name}' manually")
                return
            albums = gallery.GetGalleryStillAlbums() or []
            still = self._find_still_by_label(albums, name)
            if not still:
                self.warnings.append(
                    f"powergrade: still '{name}' not found in any album — "
                    f"apply manually (right-click hero clip → Apply Grade > {name})"
                )
                return
            # Best-effort apply: select the still album, then apply the still
            # to every clip in apply_to. The exact API path varies across
            # Resolve versions; if any step fails, log and continue.
            print(f"[apply_recipe] powergrade: found still '{name}'; manual apply still recommended on first run")
            self.warnings.append(
                f"powergrade: still '{name}' located but auto-apply path is brittle in 20.2.x — "
                f"apply manually for now (Phase 3 ships best-effort detection only)"
            )
        except Exception as e:
            self.warnings.append(f"powergrade: raised {type(e).__name__}: {e}")

    def _find_still_by_label(self, albums, name):
        for album in albums:
            try:
                stills = album.GetStills() if hasattr(album, "GetStills") else []
            except Exception:
                stills = []
            for still in stills:
                try:
                    label = still.GetLabel() if hasattr(still, "GetLabel") else None
                except Exception:
                    label = None
                if label == name:
                    return still
        return None

    def _log_manual_transitions(self):
        for t in self.recipe.get("transitions", []):
            self.manual["transitions"] += 1
            a, b = t["between"]
            print(f"[apply_recipe] manual: {t['type']} between clip {a} and {b} — Phase 4 (FCPXML 1.10) or apply manually")

    def _log_manual_title_card(self):
        if self.recipe.get("title_card"):
            self.manual["title_card"] += 1
            tc = self.recipe["title_card"]
            print(f"[apply_recipe] manual: title card on clip {tc['at_clip']} — add manually")

    def _report(self):
        print()
        print("[apply_recipe] applied:")
        for cap, (ok, total) in self.counts.items():
            if total:
                print(f"  {cap}: {ok}/{total}")
        if any(self.manual.values()):
            print("[apply_recipe] manual:")
            for cap, count in self.manual.items():
                if count:
                    print(f"  {cap}: {count}")
        if self.warnings:
            print("[apply_recipe] warnings:")
            for w in self.warnings:
                print(f"  - {w}")


def main():
    if not os.path.isfile(RECIPE_PATH):
        print(f"[apply_recipe] ERROR: recipe not found at {RECIPE_PATH}")
        sys.exit(1)

    with open(RECIPE_PATH, encoding="utf-8") as f:
        recipe = json.load(f)

    expected_version = 1
    if recipe.get("version") != expected_version:
        print(f"[apply_recipe] ERROR: recipe version {recipe.get('version')!r} unsupported (expected {expected_version})")
        sys.exit(1)

    resolve = get_resolve()
    if not resolve:
        print("[apply_recipe] ERROR: could not connect to Resolve. Run from inside Resolve via Workspace > Scripts or Console.")
        sys.exit(1)

    project = resolve.GetProjectManager().GetCurrentProject()
    if not project:
        print("[apply_recipe] ERROR: no project open.")
        sys.exit(1)
    timeline = project.GetCurrentTimeline()
    if not timeline:
        print("[apply_recipe] ERROR: no timeline open. Import the rough-cut XML first.")
        sys.exit(1)

    print(f"[apply_recipe] recipe: {RECIPE_PATH}")
    print(f"[apply_recipe] library: {recipe.get('library')!r}  timeline: {recipe.get('timeline')!r}")
    print(f"[apply_recipe] active timeline: {timeline.GetName()!r}  ({len(timeline.GetItemListInTrack('video', 1) or [])} items on V1)")

    Applier(recipe, project, timeline).apply()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
