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
from collections import Counter
import json
import hashlib
import os
import shutil
import sys
import traceback


RECIPE_PATH = {{RECIPE_PATH}}
FUSES_SOURCE_DIR = {{FUSES_SOURCE_DIR}}
RESOLVE_FUSES_DIR = {{RESOLVE_FUSES_DIR}}


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
            "fusion_effects": [0, 0],
        }
        self.manual = {"transitions": 0, "multi_point_ramps": 0, "constant_speed_ramps": 0, "title_card": 0}
        self.warnings = []
        self.newly_installed = []
        self.needs_restart = []

    def apply(self):
        self._install_fuses()
        self._apply_per_clip()
        self._apply_render_preset()
        self._apply_powergrade()
        self._log_manual_transitions()
        self._log_manual_title_card()
        self._report()

    def _fuses_referenced(self):
        names = set()
        for clip in self.recipe.get("clips", []):
            for effect in clip.get("fusion_effects", []) or []:
                names.add(effect["fuse"])
        return sorted(names)

    def _install_fuses(self):
        names = self._fuses_referenced()
        if not names:
            return

        os.makedirs(RESOLVE_FUSES_DIR, exist_ok=True)
        for name in names:
            src = os.path.join(FUSES_SOURCE_DIR, name, f"{name}.fuse")
            if not os.path.isfile(src):
                self.warnings.append(f"fuse {name}: source not found at {src}")
                continue
            dst = os.path.join(RESOLVE_FUSES_DIR, f"{name}.fuse")
            if self._files_match(src, dst):
                continue
            try:
                shutil.copy2(src, dst)
                self.newly_installed.append(name)
                print(f"[apply_recipe] installed fuse: {name} -> {dst}")
            except Exception as e:
                self.warnings.append(f"fuse {name}: copy failed: {type(e).__name__}: {e}")

    @staticmethod
    def _files_match(src, dst):
        if not os.path.isfile(dst):
            return False
        return Applier._sha256(src) == Applier._sha256(dst)

    @staticmethod
    def _sha256(path):
        hasher = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                hasher.update(chunk)
        return hasher.hexdigest()

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
            self._apply_fusion_effects(item, clip, idx)

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
        for marker_pos, marker in enumerate(clip.get("markers", []), start=1):
            self.counts["markers"][1] += 1
            frame = int(round(marker["at"] * self.frame_rate))
            # Disambiguate by clip index + marker position so duplicate names
            # within the same clip don't overwrite each other on cleanup.
            custom_data = f"buttercut:{idx}:{marker_pos}:{marker['name']}"
            # Make idempotent: a previous apply may have placed a buttercut
            # marker at this same frame. Clear it before re-adding so the
            # script can be run repeatedly.
            try:
                if hasattr(item, "DeleteMarkerByCustomData"):
                    item.DeleteMarkerByCustomData(custom_data)
            except Exception as e:
                self.warnings.append(
                    f"clip {idx}: DeleteMarkerByCustomData({custom_data!r}) raised {type(e).__name__}: {e}"
                )
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
        mpi = None
        if hasattr(item, "GetMediaPoolItem"):
            try:
                mpi = item.GetMediaPoolItem()
            except Exception as e:
                self.warnings.append(f"clip {idx}: GetMediaPoolItem raised {type(e).__name__}: {e}")
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

    def _apply_fusion_effects(self, item, clip, idx):
        effects = clip.get("fusion_effects") or []
        if not effects:
            return

        self.counts["fusion_effects"][1] += len(effects)
        comp = self._resolve_fusion_comp(item, idx)
        if not comp:
            return

        if self._fusion_effect_tools_present(comp, effects):
            self.counts["fusion_effects"][0] += len(effects)
            return

        media_in = self._find_tool(comp, "MediaIn1") or self._find_first_by_id(comp, "MediaIn")
        media_out = self._find_tool(comp, "MediaOut1") or self._find_first_by_id(comp, "MediaOut")
        if not media_in or not media_out:
            self.warnings.append(f"clip {idx}: comp missing MediaIn/MediaOut")
            return

        prev_output = media_in.Output if hasattr(media_in, "Output") else media_in.FindMainOutput(1)
        for effect in effects:
            fuse_name = effect["fuse"]
            try:
                tool = comp.AddTool(fuse_name)
            except Exception as e:
                self.warnings.append(f"clip {idx}: AddTool({fuse_name!r}) raised {type(e).__name__}: {e}")
                tool = None
            if not tool:
                self.needs_restart.append((idx, fuse_name))
                return

            try:
                input_link = tool.FindMainInput(1) if hasattr(tool, "FindMainInput") else tool.Input
                input_link.ConnectTo(prev_output)
            except Exception as e:
                self.warnings.append(f"clip {idx}: connect {fuse_name} input raised {type(e).__name__}: {e}")
                return

            for pname, pval in (effect.get("params") or {}).items():
                try:
                    result = tool.SetInput(pname, pval)
                except Exception as e:
                    self.warnings.append(
                        f"clip {idx}: SetInput({pname!r}, {pval!r}) on {fuse_name} raised {type(e).__name__}: {e}"
                    )
                else:
                    if result is False:
                        self.warnings.append(
                            f"clip {idx}: SetInput({pname!r}, {pval!r}) on {fuse_name} returned False"
                        )

            prev_output = tool.Output if hasattr(tool, "Output") else tool.FindMainOutput(1)
            self.counts["fusion_effects"][0] += 1

        try:
            media_out_input = media_out.FindMainInput(1) if hasattr(media_out, "FindMainInput") else media_out.Input
            media_out_input.ConnectTo(prev_output)
        except Exception as e:
            self.warnings.append(f"clip {idx}: connect MediaOut raised {type(e).__name__}: {e}")

    def _list_fusion_comps(self, item):
        out = []
        if not hasattr(item, "GetFusionCompCount") or not hasattr(item, "GetFusionComp"):
            return out
        try:
            raw = item.GetFusionCompCount()
            count = int(raw) if raw is not None else 0
        except (TypeError, ValueError):
            return out
        # Resolve's Fusion comp index is 1-based (1 .. count inclusive).
        for i in range(1, max(count, 0) + 1):
            try:
                c = item.GetFusionComp(i)
            except (AttributeError, OSError, TypeError, ValueError):
                continue
            if c:
                out.append(c)
        return out

    def _comp_display_name(self, comp):
        for attr in ("GetName", "Name"):
            if hasattr(comp, attr):
                try:
                    v = getattr(comp, attr)
                    name = v() if callable(v) else v
                    if name:
                        return str(name)
                except Exception:
                    pass
        try:
            if hasattr(comp, "GetAttrs"):
                attrs = comp.GetAttrs() or {}
                if isinstance(attrs, dict):
                    for key in ("TOOLS_Name", "COMP_NAME", "Name"):
                        val = attrs.get(key)
                        if val:
                            return str(val)
        except Exception:
            pass
        return ""

    def _comp_is_buttercut(self, comp):
        return self._comp_display_name(comp).startswith("ButterCut_")

    def _try_tag_buttercut_comp(self, comp, idx):
        try:
            if hasattr(comp, "SetAttrs"):
                comp.SetAttrs({"TOOLS_Name": f"ButterCut_clip{idx}"})
        except Exception:
            pass

    def _resolve_fusion_comp(self, item, idx):
        comps = self._list_fusion_comps(item)
        for c in comps:
            if self._comp_is_buttercut(c):
                return c
        if not hasattr(item, "AddFusionComp"):
            self.warnings.append(f"clip {idx}: timeline item has no AddFusionComp")
            return None
        try:
            comp = item.AddFusionComp()
        except Exception as e:
            self.warnings.append(f"clip {idx}: AddFusionComp raised {type(e).__name__}: {e}")
            return None
        if not comp:
            self.warnings.append(f"clip {idx}: AddFusionComp returned None")
            return None
        self._try_tag_buttercut_comp(comp, idx)
        return comp

    def _count_tools_with_id(self, comp, tool_id):
        try:
            tools = comp.GetToolList(False, tool_id) or {}
        except Exception:
            return 0
        if isinstance(tools, dict):
            return len(tools)
        if isinstance(tools, (list, tuple)):
            return len(tools)
        return 1 if tools else 0

    def _fusion_effect_tools_present(self, comp, effects):
        expected = Counter(e["fuse"] for e in effects)
        for fuse, need in expected.items():
            if self._count_tools_with_id(comp, fuse) != need:
                return False
        return True

    def _find_tool(self, comp, name):
        try:
            return comp.FindTool(name)
        except Exception:
            return None

    def _find_first_by_id(self, comp, tool_id):
        try:
            tools = comp.GetToolList(False, tool_id) or {}
        except Exception:
            return None
        if isinstance(tools, dict):
            return next(iter(tools.values()), None)
        return tools[0] if tools else None

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
            if not bool(self.project.LoadRenderPreset(match)):
                self.warnings.append(f"render_preset: LoadRenderPreset({match!r}) returned False")
                return
            if not bool(self.project.SetCurrentRenderMode(0)):
                self.warnings.append(f"render_preset: SetCurrentRenderMode(0) returned False after LoadRenderPreset({match!r})")
                return
            self.counts["render_preset"][0] += 1
            print(f"[apply_recipe] loaded render preset: {match}")
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
        if self.newly_installed:
            print(f"[apply_recipe] installed fuses: {', '.join(self.newly_installed)}")
        if self.needs_restart:
            print("[apply_recipe] ACTION REQUIRED: restart Resolve once, then re-run this script.")
            for clip_idx, fuse_name in self.needs_restart:
                print(f"  clip {clip_idx}: fuse {fuse_name!r} not yet registered")
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

    supported_versions = {1, 2}
    if recipe.get("version") not in supported_versions:
        print(
            f"[apply_recipe] ERROR: recipe version {recipe.get('version')!r} unsupported "
            f"(expected one of {sorted(supported_versions)})"
        )
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

    broll_clips = recipe.get('broll', [])
    if broll_clips:
        print(f"  • {len(broll_clips)} b-roll clip(s) present (placement is carried in the XML; nothing to apply here)")

    Applier(recipe, project, timeline).apply()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
