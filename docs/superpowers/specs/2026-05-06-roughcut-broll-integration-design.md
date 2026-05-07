# Roughcut Integration: Consume B-Roll Manifest — Design

**Issue:** [#33](https://github.com/William-Hill/buttercut/issues/33) — Hyperframes: roughcut integration (consume broll manifest)
**Epic:** [#26](https://github.com/William-Hill/buttercut/issues/26) — Hyperframes integration
**Depends on (merged):** PR #25 (manifest schema), PR #35 (`render-broll` skill + `BrollRenderer`)
**Date:** 2026-05-06

## Goal

Teach the rough-cut export pipeline to ingest a sibling `<roughcut>.broll.yaml`, load each entry's rendered MP4, and place it on the timeline at the manifest-specified timing. This closes the foundational vertical slice of the Hyperframes epic: with #27 (theme), #28 (render), and this issue all landed, a populated manifest end-to-end produces an XML where AI-generated graphics ride on top of the editorial spine.

## Non-Goals

- Editorial decisions about *what* graphics to generate (that's the b-roll director, #30).
- Live in-NLE editing of rendered MP4s. Edits round-trip through the composition source and a re-render (#34).
- True V1 splice for cutaways (see Section 1).

## Design Decisions

### 1. Cutaway model: V2 with audio bed preserved

Cutaways are emitted on V2 alongside overlays — the V1 spine stays intact. Visually identical to a V1 splice in the editor; audio under the cutaway remains the speaker's voice (which is what cutaway flows almost always want).

This collapses overlay/cutaway/pip into one mechanism — "connected/lane-1 clips on top of the spine" — differing only in audio-mute and transform metadata. It also keeps recipe clip indices (`1..N` by YAML order) and all references to them (transitions, `title_card.at_clip`, `powergrade.apply_to`) untouched. A literal V1 splice would force renumbering and rippling rewrites.

If a future editorial flow needs a true V1 splice, it gets a follow-up issue.

### 2. PiP scope: hardcoded corner presets

Manifest entries with `placement: pip` may carry two optional fields:

| Field | Type | Default |
|---|---|---|
| `pip_corner` | `top_right` \| `top_left` \| `bottom_right` \| `bottom_left` | `top_right` |
| `pip_scale` | float in `0.05..0.95` | `0.33` |

Both fields are **only valid when `placement: pip`**; the validator rejects them on overlay/cutaway entries. This covers the realistic PiP shapes (corner inset at one of four positions, scaled to a fraction of the frame) without inviting bikeshedding over coordinate systems and per-editor units. A full transform schema is a future issue if it's ever needed.

### 3. Audio behavior is derived, not declared

| Placement | Audio of b-roll clip |
|---|---|
| `overlay` | muted |
| `pip` | muted |
| `cutaway` | muted (V1 audio bed continues; b-roll audio would double up) |

In short: b-roll audio is always muted in this PR. No schema field — it follows from `placement`. If a future template needs unmuted b-roll, that becomes a manifest field then.

## Architecture

### Component map

```
roughcut.yaml ─┐
               ├─→ export_to_fcpxml.rb
broll.yaml ────┘                │
                                ├─ load via ButterCut::BrollManifest
                                ├─ filter to entries with `rendered` populated
                                └─→ ButterCut.new(clips, overlays:, editor:)
                                        │
                                        ├─→ FCPX#to_xml   → emits lane="1" clips
                                        └─→ FCP7#to_xml   → emits second <track>
                                            │
                                            └─→ recipe.json gets a `broll` array
                                                (informational; XML is authoritative)
```

### Discovery rule

If `<roughcut-stem>.broll.yaml` exists next to the rough-cut YAML, load it. If absent, behavior is identical to today. Entries with `rendered: null` are skipped with a warning — a half-rendered manifest must not break export.

### Generator changes

**FCPX (FCPXML 1.10):** Each overlay attaches to the spine clip it overlaps, with `lane="1"`, `offset` = timeline-absolute position, `duration` = `end - start`. PiP gets `<adjust-transform scale="…" position="x y"/>`. Audio muted via `<adjust-volume amount="-96dB"/>`. B-roll MP4s become new `<asset>` resources keyed by absolute path.

**FCP7 / Resolve (xmeml v5):** Today one `<track>` lives inside `<media><video>`. Change: emit a second `<track>` for V2 (and V3 only if the manifest needs it for stacked simultaneous overlays). Each overlay is one `<clipitem>` on V2 with `<start>`/`<end>` in timeline frames. PiP scale/position via the standard Motion `<filter>` (Basic Motion → Scale, Center).

**Resolve apply script:** No placement work — the XML carries placement. The script just logs the count of b-roll clips it sees, for debugging.

### Public API

`ButterCut.new` gains an optional keyword:

```ruby
ButterCut.new(
  clips,                    # existing
  editor: :fcpx,            # existing
  overlays: [
    {
      source: "/abs/path/to/broll/br-0001.mp4",
      source_id: "br-0001",
      start: 42.10,         # timeline-absolute seconds
      duration: 5.70,
      placement: "overlay", # overlay | cutaway | pip
      pip_corner: nil,      # only when placement == pip
      pip_scale: nil        # only when placement == pip
    }
  ]
)
```

This is the contract `export_to_fcpxml.rb` populates after consulting the manifest. It keeps the `BrollManifest` schema decoupled from the generator's input shape; the manifest is the editorial-layer contract, `overlays:` is the renderer-layer contract.

## Schema Changes

### `BrollManifest` (lib/buttercut/broll_manifest.rb)

- `SCHEMA_VERSION` 1 → 2.
- Accept v1 manifests with a deprecation warning (treated as `pip_corner: top_right`, `pip_scale: 0.33` if any pip entry exists).
- Validate `pip_corner` ∈ `%w[top_right top_left bottom_right bottom_left]` only when `placement == "pip"`.
- Validate `pip_scale` is `0.05..0.95` only when `placement == "pip"`.
- Reject `pip_corner` / `pip_scale` on non-pip entries.

### `Recipe` (lib/buttercut/recipe.rb)

- `SCHEMA_VERSION` 2 → 3; `SUPPORTED_VERSIONS` becomes `[1, 2, 3]`.
- New optional top-level `broll` array. Each element:

```json
{
  "id": "br-0001",
  "start": 42.10,
  "end": 47.80,
  "placement": "overlay",
  "source": "broll/br-0001.mp4",
  "source_video": "tutorial_01.mov"
}
```

- `recipe.json` is informational for b-roll. Apply script does not need to act on it.

### `roughcut.yaml`

**No changes.** The b-roll manifest stays a sibling file. Editorial YAML and generated-graphic YAML remain decoupled, matching PR #25's pattern.

## File Touch List

**New:**
- `lib/buttercut/overlay_emitter.rb` — shared helpers for resolving lane/offset/duration in fraction-of-second form. Keeps DOM emission logic per-editor but math in one place.
- `spec/buttercut/fcpx_overlay_spec.rb`
- `spec/buttercut/fcp7_overlay_spec.rb`
- `spec/fixtures/broll_integration/` — fixture rough cut + matching broll.yaml + a tiny stub MP4 for `rendered`.

**Modified:**
- `lib/buttercut.rb` — accept `overlays:` keyword, plumb through.
- `lib/buttercut/editor_base.rb` — `attr_reader :overlays` plus a normalization helper.
- `lib/buttercut/fcpx.rb` — emit lane-1 connected clips, mute filter, optional adjust-transform.
- `lib/buttercut/fcp7.rb` — emit V2 (and V3 if needed) tracks, motion filter for pip.
- `lib/buttercut/broll_manifest.rb` — schema v2, pip field validation.
- `lib/buttercut/recipe.rb` — schema v3, optional `broll` array.
- `.claude/skills/roughcut/export_to_fcpxml.rb` — discover sibling broll.yaml, build `overlays:` argument, pass into `ButterCut.new`.
- `.claude/skills/roughcut/recipe_from_roughcut.rb` — emit `broll` array when manifest present.
- `.claude/skills/roughcut/generate_apply_script.rb` — log b-roll count.
- `templates/broll_template.yaml` — document `pip_corner`, `pip_scale`, bump version comment.
- `CLAUDE.md` — one-liner in the rough-cut artifacts paragraph.

## Testing Strategy

| Test | Asserts |
|---|---|
| `broll_manifest_spec` extension | pip field validation; v1 acceptance with warning; rejection of pip fields on non-pip entries |
| `fcpx_overlay_spec` (new) | `lane="1"` clips at correct offsets; `<adjust-transform>` shape for pip; `<adjust-volume amount="-96dB"/>` on every overlay |
| `fcp7_overlay_spec` (new) | second `<track>` emitted; `<clipitem>` start/end in timeline frames; Motion filter shape for pip |
| `export_to_fcpxml_spec` extension | end-to-end with fixture rough cut + sibling broll.yaml: output XML contains expected b-roll clip on V2; recipe.json contains `broll` array |
| Empty/absent broll.yaml golden | byte-identical output to today's pipeline (no-regression acceptance criterion) |

## Acceptance Criteria Mapping

| Issue acceptance | Where addressed |
|---|---|
| Empty/absent broll.yaml = no regression | Discovery rule (Architecture §); golden test (Testing) |
| Populated broll.yaml round-trips into Resolve with overlays on V2 | FCP7 generator change; `fcp7_overlay_spec` + e2e test |
| Cutaway entries replace footage and adjust V1 timeline | Section 1: cutaway = V2-with-muted-b-roll-audio (visually equivalent; V1 spine preserved on purpose) |

## Out of Scope (deferred to follow-ups)

- True V1 splice cutaways.
- Full transform schema for PiP.
- Director skill (#30) — this PR consumes manifests; it doesn't author them.
- Late-render workflow / non-destructive swap-in-place (#34).
