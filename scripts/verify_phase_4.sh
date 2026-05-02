#!/usr/bin/env bash
# Phase 4 verification helper: regenerate the march-30-workout rough cut on
# the current branch, structurally check the FCPXML for version 1.10 and
# <timeMap> elements, and print next-step instructions for the manual
# Resolve import check.
#
# Usage:
#   scripts/verify_phase_4.sh                        # picks the most recent .yaml
#   scripts/verify_phase_4.sh path/to/roughcut.yaml  # use a specific rough cut

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

LIBRARY="march-30-workout"
ROUGHCUTS_DIR="libraries/$LIBRARY/roughcuts"

if [[ $# -ge 1 ]]; then
  YAML_PATH="$1"
else
  YAML_PATH="$(ls -t "$ROUGHCUTS_DIR"/*.yaml 2>/dev/null | head -n1 || true)"
fi

if [[ -z "${YAML_PATH:-}" || ! -f "$YAML_PATH" ]]; then
  echo "ERROR: no rough cut YAML found. Pass one explicitly:" >&2
  echo "  $0 $ROUGHCUTS_DIR/<name>.yaml" >&2
  exit 1
fi

BASENAME="$(basename "$YAML_PATH" .yaml)"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_XML="$ROUGHCUTS_DIR/${BASENAME}_phase4_${TS}.xml"

echo "→ Source YAML : $YAML_PATH"
echo "→ Output XML  : $OUT_XML"
echo

bundle exec ruby .claude/skills/roughcut/export_to_fcpxml.rb "$YAML_PATH" "$OUT_XML" fcpx

echo
echo "── Structural checks ─────────────────────────────"

VERSION_LINE="$(grep -m1 '<fcpxml ' "$OUT_XML" || true)"
TIMEMAP_COUNT="$(grep -c '<timeMap>' "$OUT_XML" || true)"
TIMEPT_COUNT="$(grep -c '<timept ' "$OUT_XML" || true)"

echo "  fcpxml header : $VERSION_LINE"
echo "  <timeMap>     : $TIMEMAP_COUNT"
echo "  <timept>      : $TIMEPT_COUNT"
echo

PASS=1
if [[ "$VERSION_LINE" != *'version="1.10"'* ]]; then
  echo "  ✗ FCPXML version is not 1.10"
  PASS=0
fi
if [[ "$TIMEMAP_COUNT" -eq 0 ]]; then
  echo "  ⚠ no <timeMap> elements found — does this rough cut have any speed_ramps?"
  echo "    (not a hard fail; verify by inspecting the YAML)"
fi
if [[ "$PASS" -eq 1 ]]; then
  echo "  ✓ Structural checks passed."
fi

echo
echo "── Next steps (manual, in Resolve) ────────────────"
cat <<EOF
  1. Open DaVinci Resolve, create a new empty project.
  2. File > Import > Timeline… and pick:
       $OUT_XML
     Relink media when prompted.
  3. Open the imported timeline. Right-click a clip that had speed_ramps
     in the YAML (e.g. medicine-ball-slams) → Retime Controls (⌘R).
     If you see non-100% speed segments / retime control points matching
     the recipe ramps, Phase 4 acceptance is met.

  Optional automated check inside Resolve:
    Drop scripts/verify_phase_4_resolve.py into
      ~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/
    Open the imported timeline, then run:
      Workspace > Scripts > Edit > verify_phase_4_resolve
    It prints per-clip Speed values from the MediaPoolItem API.
EOF
