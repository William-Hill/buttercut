# M3 — Transcript Editing: Design

**Sprint 2 milestone M3.** Umbrella issue: William-Hill/buttercut#14.
Depends on M1 (read-only transcript browser, shipped in #17). Independent of M2.

## Goal

Let users fix audio transcripts directly inside the ButterCut desktop UI, without re-running WhisperX and without hand-editing the JSON. Three edit scopes:

1. **This clip only** — the most common case (a one-off mishearing).
2. **This library** — same misheard token recurs across multiple clips.
3. **Trust globally** — like (2), but also append the corrected term to `library.yaml` `user_context` so future analyses pick it up automatically.

Visual transcript and summary stay read-only in M3 — separate milestones.

## Non-goals

- No re-running of the Claude refinement pass on existing clips. Adding a term to `user_context` only affects *future* analyses. (Decision: option B from brainstorming. Re-refinement is deferred until/unless needed.)
- No insertions or deletions of words. The WhisperX `words[]` array is positionally tied to timing; M3 preserves count. Phrase fixes that change word count remain a CLI/manual task.
- No editing of the visual transcript.
- No multi-level undo history persistence — one in-memory level per open clip.
- No N→N phrase edits via the inline popover. Multi-word changes go through find/replace, which makes the matched-count contract explicit.

## Background

The existing `refine_instructions.md` (companion to `transcribe-audio` SKILL.md) already encodes the rules M3 must enforce. Quoting the load-bearing constraints:

- WhisperX produces word-level timing. `segments[].words[]` is 1:1 with the space-separated tokens in `segments[].text`. **Splitting or merging tokens breaks this alignment and corrupts downstream timing used by roughcut.**
- Allowed: 1→1 spelling fixes; N→N phrase fixes (same count across the phrase).
- Disallowed: 1→2 splits, 2→1 merges. When the correct form needs splitting, *squash* it (`Sanjose` → `SanJose`).
- Every edit must update three places consistently: `segments[].text`, `segments[].words[].word`, `word_segments[].word`.
- Edits must anchor on adjacent context — never bare-word substring replacement (the "carrot" trap: replacing `"car"` with `"far"` would also rewrite `"carrot"` → `"farrot"`).
- Case must be preserved character-for-character (the goal is downstream recognition, not proper-noun normalization). Squashing may introduce internal capitals; the leading character's case still follows the source.

M3 lifts these rules from agent prose into deterministic Ruby + TypeScript code. The `TranscriptEditor` class is the canonical implementation; the agent-facing `refine_instructions.md` keeps its rules but in the long run can defer to the same class.

## Architecture

### Frontend — `ui/src/routes/library/`

New components:

- **`WordToken.tsx`** — replaces the inline `<button class="row__word">` currently rendered in `TranscriptZone.tsx`. Single click still scrubs the player (preserving M1 behavior). On hover, a small pencil affordance appears; clicking it (or pressing `e` while focused) opens the edit popover anchored to the token.
- **`EditPopover.tsx`** — anchored popover with: a single-line text input pre-filled with the current word; a scope picker radio (`This clip` / `This library` / `Trust globally`); a live match count for library scopes (`Found 7 matches across 4 clips`); a Replace button; Cancel. Esc / click-outside dismisses. Token-count validation runs on every keystroke.
- **`FindReplacePanel.tsx`** — floating panel triggered by ⌘F. Search input + replacement input + scope picker (`This clip` / `Whole library`) + match list with click-to-scroll-into-view. Same token-count validation as the popover.
- **`useTranscriptEditor.ts`** — hook owning: edit state, undo stack (one level), scroll-anchor capture/restore, IPC dispatch wrappers.
- **`editorTypes.ts`** — shared TypeScript types for edit operations and IPC payloads.

Modified:

- **`TranscriptZone.tsx`** — rendering of `AudioRow` words switches from inline `<button>` to `<WordToken>`. Subscribes to the `transcript_edited` sidecar event for the current clip and refetches the transcript when fired, capturing/restoring the scroll anchor across the refetch.
- **`library.css`** — styles for the pencil affordance, popover, find/replace panel, validation error states.

### Sidecar — `ui/sidecar/lib/buttercut_ui_sidecar/`

New classes (one class per file, single high-level entry point, per the project's Programming Style):

- **`TranscriptEditor`** (`transcript_editor.rb`) — `TranscriptEditor.apply(library:, clip:, edit:)`. Loads the transcript JSON, applies the edit to all three arrays atomically under the existing library yaml mutex, writes back, returns a summary including which array indices changed. Strict word-count rule enforcement; raises `TokenCountViolation` if the new value would split/merge.
- **`TranscriptFinder`** (`transcript_finder.rb`) — `TranscriptFinder.find(library:, token:, scope:)`. Returns `[{clip:, segment_index:, word_indices:[...], context_snippet:}]`. Word-boundary matching (not substring), case-insensitive search, case-preserving in the returned snippets.
- **`LibraryReplacer`** (`library_replacer.rb`) — `LibraryReplacer.apply(library:, old_token:, new_token:, trust:)`. Drives `TranscriptFinder` + `TranscriptEditor` across all clips in a library under one mutex acquisition; if `trust: true`, also appends `new_token` to `library.yaml` `user_context` idempotently. Emits one `transcript_edited` notification per affected clip via the existing `Notifier`.

New IPC commands (registered in `buttercut_ui_sidecar.rb` and proxied through `ui/src-tauri/src/lib.rs`):

- `apply_transcript_edit(library, clip, edit)` — single-clip edit. `edit = { old_token, new_token, segment_index, word_index }`.
- `find_transcript_matches(library, token, scope)` — `scope = "clip" | "library"`. Used by the popover's live count and the find/replace panel's match list.
- `apply_library_replace(library, old_token, new_token, trust)` — library-wide replacement. `trust: true` also touches `library.yaml`.

New sidecar event:

- `transcript_edited { library, clip, edit_count }` — fired per affected clip after a successful edit. Frontend filters by `(library, clip)` to decide whether to refetch.

TS bindings added to `ui/src/ipc/sidecar.ts`.

### Library YAML

No schema change. The "trust globally" path appends to the existing `user_context` field (present in `templates/library_template.yaml`). Append is idempotent: if the term (case-insensitive) is already in `user_context`, no change.

No new migration needed — libraries that lack `user_context` are already covered by the migration list in `CLAUDE.md`.

## UX flow

### Single-word fix

1. User clicks the pencil affordance on the misheard word `Tenderlohn` in clip C0076.
2. Popover opens, anchored to the word, with input pre-filled `Tenderlohn`.
3. User types `Tenderloin`. Validation passes (1 token in, 1 token out). Scope defaults to `This clip`.
4. User clicks Replace. Frontend calls `apply_transcript_edit`. Sidecar updates JSON, emits `transcript_edited`. Frontend refetches; scroll anchor restored. Popover closes.

### Library-wide replace

1. User clicks pencil on `Tenderlohn`, picks scope `This library` in the popover.
2. Popover shows live count: `Found 7 matches across 4 clips` (pulled via `find_transcript_matches`).
3. User clicks Replace. Frontend calls `apply_library_replace(trust: false)`. Sidecar walks all clips under one mutex, applies edits, emits `transcript_edited` per clip. Frontend refetches the active clip and restores scroll.

### Trust globally

1. Same as library-wide, but user picks scope `Trust globally`.
2. Frontend calls `apply_library_replace(trust: true)`. Sidecar additionally appends `Tenderloin` to `user_context`.
3. Toast confirms: `Replaced 7 occurrences across 4 clips. Added "Tenderloin" to library context.`

### Find/Replace

1. User presses ⌘F in the library window. Floating panel opens, scope defaults to `This clip`.
2. User types search and replacement. Match list updates live. Token-count check enforced.
3. Replace All applies via either `apply_transcript_edit` (per match for clip scope) or `apply_library_replace` (for library scope, no trust).

### Undo

- One in-memory level per open clip. Cmd-Z (or an Undo button in the toolbar) issues the reverse operation through the same IPC paths.
- Switching clips clears the undo stack (the operation is no longer guaranteed to be safe to invert if the underlying file has changed in between).
- Trust-globally undo reverts text *and* removes the term from `user_context` (only if the term wasn't already there before the edit — captured at edit time).

## Word-count rule enforcement

Both client- and server-side. Belt and suspenders because the rule is load-bearing for downstream timing.

**Client (popover + find/replace input).**
```
const tokens = value.trim().split(/\s+/);
if (tokens.length !== 1) showError("Use a single token. To represent a multi-word term without splitting timing, squash it (e.g. SanJose).");
```

**Server (`TranscriptEditor`).**
After applying the edit, assert that the new `segments[N].words[].length` equals the old length AND that `word_segments[].length` is unchanged. If not, raise `TokenCountViolation` and roll back (no partial writes — the editor stages the modified JSON in memory, validates, then writes once).

## Scroll stability

The currently-displayed clip can mutate underneath the user during a library-wide replace. The mechanism:

1. **Before mutation:** `useTranscriptEditor` walks the scroll container, finds the topmost word element whose `getBoundingClientRect().top >= containerTop`, captures `(segment_index, word_index)` from its data attributes, and records `viewportOffset = wordRect.top - containerTop`.
2. **After refetch + re-render:** look up the element with the same `(segment_index, word_index)`. Set `container.scrollTop += newWordRect.top - containerTop - viewportOffset`.
3. **Edge case — anchor word was the edit target:** the word still exists at the same `(segment_index, word_index)` (we don't change array length), so the same lookup works. Its rendered text changed, but its position is stable.
4. **Edge case — viewport empty (no transcript words visible):** skip restoration; let the natural scrollTop persist.

The data attributes (`data-segment`, `data-word-index`) get added to `WordToken` for this purpose.

## Error handling

Sidecar returns specific, actionable error codes:

| Code | Meaning | Frontend treatment |
|---|---|---|
| `token_count_violation` | New value would split/merge tokens | Inline popover error; Replace stays disabled |
| `not_found` | Clip or transcript file missing | Toast: "Clip transcript not found: <path>" |
| `concurrent_modification` | Yaml/transcript changed under us | Toast: "Transcript changed externally — please re-open the clip"; refetch automatically |
| `io_error` | Disk read/write failed | Toast with `errno` detail |
| `match_count_drift` | `find_transcript_matches` count disagreed with what the apply phase saw | Toast: "Replacement count changed; applied N edits, expected M" |

Pattern matches M2's specific-error-surfacing approach. No generic toasts.

## Testing

### RSpec

`spec/buttercut_ui_sidecar/transcript_editor_spec.rb`:

- 1→1 spelling fix in mid-segment: text + words + word_segments all updated, timing untouched.
- Squashed fix (`Sanjose` → `SanJose`): single-token slot preserved.
- Case preservation: lowercase `tundraloin` → lowercase `tenderloin`; capitalized `Tundraloin` → `Tenderloin`.
- N→N phrase fix (find/replace path): two tokens stay two tokens.
- Token-count violation: multi-word `new_token` raises `TokenCountViolation`, JSON unchanged on disk.
- Concurrent edit: file modified between read and write raises `ConcurrentModification`.

`spec/buttercut_ui_sidecar/transcript_finder_spec.rb`:

- Word-boundary matching: searching `car` does NOT match `carrot` or `scared`.
- Case-insensitive: searching `tenderloin` matches `Tenderloin`, `tenderloin`, `TENDERLOIN`.
- Cross-clip aggregation: finds matches in multiple transcripts, returns clip + indices + context snippet.

`spec/buttercut_ui_sidecar/library_replacer_spec.rb`:

- Single mutex acquisition for the whole walk.
- `transcript_edited` notification fires per affected clip, with correct `edit_count`.
- `trust: true` appends to `user_context`; idempotent on second invocation.
- Failure mid-walk: clips processed before failure are kept; failure surfaces with the offending clip; `user_context` is NOT appended if any clip failed (transactional at the library level).

### React component tests

`ui/src/routes/library/__tests__/EditPopover.test.tsx`:

- Token-count validation: typing a space disables Replace, shows the squashing tip.
- Scope switching updates the visible match-count line via mocked IPC.
- Esc + click-outside dismiss; Enter submits.

### Manual

- Library-wide replace on a multi-clip library; verify the active-clip scroll position is preserved across the mutation.
- Trust-globally edit; verify `library.yaml` gets the term and a subsequent `transcribe-audio` run uses it.

## Files to add or modify

**Add (frontend):**
- `ui/src/routes/library/WordToken.tsx`
- `ui/src/routes/library/EditPopover.tsx`
- `ui/src/routes/library/FindReplacePanel.tsx`
- `ui/src/routes/library/useTranscriptEditor.ts`
- `ui/src/routes/library/editorTypes.ts`
- `ui/src/routes/library/__tests__/EditPopover.test.tsx`

**Modify (frontend):**
- `ui/src/routes/library/TranscriptZone.tsx` — integrate `WordToken`, scroll-anchor wiring, `transcript_edited` subscription
- `ui/src/routes/library/library.css` — popover, panel, hover affordance, error states
- `ui/src/ipc/sidecar.ts` — three new TS bindings

**Add (sidecar):**
- `ui/sidecar/lib/buttercut_ui_sidecar/transcript_editor.rb`
- `ui/sidecar/lib/buttercut_ui_sidecar/transcript_finder.rb`
- `ui/sidecar/lib/buttercut_ui_sidecar/library_replacer.rb`
- `ui/sidecar/spec/buttercut_ui_sidecar/transcript_editor_spec.rb`
- `ui/sidecar/spec/buttercut_ui_sidecar/transcript_finder_spec.rb`
- `ui/sidecar/spec/buttercut_ui_sidecar/library_replacer_spec.rb`

**Modify (sidecar / Rust):**
- `ui/sidecar/buttercut_ui_sidecar.rb` — register three new RPC commands
- `ui/src-tauri/src/lib.rs` — proxy commands and event passthrough

## Cross-cutting risks

1. **Refinement rules drifting between agent prose and code.** `refine_instructions.md` and `TranscriptEditor` will encode the same rules. Mitigation: the spec for `TranscriptEditor` cites the same canonical examples (Tenderloin / Walnut Creek / SanJose) as the agent doc, and a future cleanup can have the agent skill shell out to the Ruby class.
2. **Trust-globally without re-refinement misses new mishearings.** A user fixes `Tenderloin` in clip A, but clip B has `Tendarlon` (a different mishearing) of the same word. M3 won't auto-catch it. Mitigated by: the user can run find/replace with the new misheard variant, and any future re-analysis picks up the term from `user_context`.
3. **Concurrent edits.** The yaml mutex covers transcript writes (sharing the lock). Two simultaneous library-wide replaces serialize. The frontend disables Replace controls while a library-wide operation is in flight.
