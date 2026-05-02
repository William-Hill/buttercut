#!/usr/bin/env python3
"""Phase 4 verification probe — checks if FCPXML 1.10 timeMap survived import.

Drop into:
  macOS:   ~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/
  Windows: %APPDATA%\\Blackmagic Design\\DaVinci Resolve\\Support\\Fusion\\Scripts\\Edit\\
  Linux:   ~/.local/share/DaVinciResolve/Fusion/Scripts/Edit/

Run from inside Resolve via:
  Workspace > Scripts > Edit > verify_phase_4_resolve

Prereq:
  1. Open the FCPXML produced by scripts/verify_phase_4.sh in a fresh Resolve
     project (File > Import > Timeline…).
  2. Make sure the imported timeline is the Current Timeline.
  3. Open Workspace > Console so the report is visible.

The probe is read-only. For each clip on V1 it reports:
  - clip name
  - MediaPoolItem 'Speed' property (constant-speed indicator)
  - whether the underlying MediaPoolItem appears retimed (Speed != 1.0)

A clip whose recipe carried speed_ramps but reports Speed == 1.0 in Resolve
indicates the timeMap did NOT survive import — Phase 4 acceptance not met for
that clip and the apply script remains the fallback path.
"""

import json
import os

OUT_PATH = os.path.expanduser("~/buttercut_phase4_verify.json")


def get_resolve():
    """Resolve injects `resolve` into the script's globals when run from
    Workspace > Scripts. Fall back to the external bootstrap for off-menu use."""
    if "resolve" in globals():
        return globals()["resolve"]
    try:
        import DaVinciResolveScript as dvr_script  # type: ignore
        return dvr_script.scriptapp("Resolve")
    except Exception:
        return None


def main():
    resolve = get_resolve()
    if resolve is None:
        print("ERROR: could not connect to Resolve. Run from Workspace > Scripts > Edit.")
        return

    pm = resolve.GetProjectManager()
    project = pm.GetCurrentProject()
    if not project:
        print("ERROR: no current project. Open a project with the imported timeline.")
        return

    timeline = project.GetCurrentTimeline()
    if not timeline:
        print("ERROR: no current timeline. Open the imported timeline.")
        return

    print(f"Project : {project.GetName()}")
    print(f"Timeline: {timeline.GetName()}")
    print()

    track_count = timeline.GetTrackCount("video")
    rows = []
    for track_idx in range(1, track_count + 1):
        items = timeline.GetItemListInTrack("video", track_idx) or []
        for ti in items:
            mpi = ti.GetMediaPoolItem()
            speed = None
            if mpi:
                try:
                    speed = mpi.GetClipProperty("Speed")
                except Exception as e:  # noqa: BLE001
                    speed = f"<error: {e}>"
            rows.append({
                "track": f"V{track_idx}",
                "name": ti.GetName(),
                "media_pool_speed": speed,
                "appears_retimed": (speed not in (None, "1.0", 1.0, "")),
            })

    if not rows:
        print("No clips found on any video track.")
        return

    name_w = max(len(r["name"]) for r in rows)
    print(f"{'TRACK':<6} {'CLIP'.ljust(name_w)}  {'SPEED':<10}  RETIMED?")
    print("-" * (6 + name_w + 24))
    for r in rows:
        print(
            f"{r['track']:<6} {r['name'].ljust(name_w)}  "
            f"{str(r['media_pool_speed']):<10}  {r['appears_retimed']}"
        )

    with open(OUT_PATH, "w") as f:
        json.dump({
            "project": project.GetName(),
            "timeline": timeline.GetName(),
            "clips": rows,
        }, f, indent=2)
    print()
    print(f"Wrote: {OUT_PATH}")
    print()
    print("Cross-check: open the source rough-cut YAML and find clips with a")
    print("'speed_ramps' entry. Those should appear above with appears_retimed=True.")
    print("If a ramped clip shows Speed=1.0, the FCPXML timeMap did not survive.")


main()
