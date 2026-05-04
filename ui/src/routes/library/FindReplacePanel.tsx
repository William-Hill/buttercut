// ui/src/routes/library/FindReplacePanel.tsx
import { useEffect, useMemo, useState } from "react";
import { tokenize, validateMatchedCount } from "./tokenValidation";
import type { FinderMatch } from "./editorTypes";

export interface FindReplacePanelProps {
  library: string;
  clip: string | null;
  busy: boolean;
  onClose: () => void;
  // Returns library- or clip-scoped matches.
  findMatches: (tokens: string[], scope: "clip" | "library", clip?: string) => Promise<FinderMatch[]>;
  // Applies a per-match clip-scope edit (used when scope === "clip").
  applyClipReplace: (clip: string, match: FinderMatch, newTokens: string[]) => Promise<void>;
  // Applies a library-wide replace (used when scope === "library").
  applyLibraryReplace: (oldTokens: string[], newTokens: string[]) => Promise<void>;
  // Caller wires this to TranscriptZone for scroll-into-view of a match.
  onSelectMatch: (match: FinderMatch) => void;
}

export default function FindReplacePanel(props: FindReplacePanelProps) {
  const { clip, busy, onClose, findMatches, applyClipReplace, applyLibraryReplace, onSelectMatch } = props;
  const [search, setSearch] = useState("");
  const [replacement, setReplacement] = useState("");
  const [scope, setScope] = useState<"clip" | "library">("clip");
  const [matches, setMatches] = useState<FinderMatch[]>([]);

  const validation = useMemo(() => validateMatchedCount(search, replacement), [search, replacement]);
  const searchTokens = useMemo(() => tokenize(search), [search]);
  const newTokens = useMemo(() => tokenize(replacement), [replacement]);

  useEffect(() => {
    if (searchTokens.length === 0) { setMatches([]); return; }
    let cancelled = false;
    const target = scope === "clip" ? clip ?? undefined : undefined;
    findMatches(searchTokens, scope, target).then((m) => { if (!cancelled) setMatches(m); });
    return () => { cancelled = true; };
  }, [searchTokens.join("|"), scope, clip, findMatches]);

  const canReplaceAll = validation.valid && !busy && matches.length > 0;

  return (
    <div className="find-replace">
      <header>
        <strong>Find &amp; replace</strong>
        <button onClick={onClose} aria-label="Close">×</button>
      </header>
      <div className="find-replace__row">
        <input
          placeholder="Find"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        <input
          placeholder="Replace with"
          value={replacement}
          onChange={(e) => setReplacement(e.target.value)}
        />
      </div>
      {!validation.valid && replacement.length > 0 && (
        <p className="find-replace__error">{validation.error}</p>
      )}
      <fieldset className="find-replace__scope">
        <label><input type="radio" checked={scope === "clip"} onChange={() => setScope("clip")} /> This clip</label>
        <label><input type="radio" checked={scope === "library"} onChange={() => setScope("library")} /> Whole library</label>
      </fieldset>

      <ul className="find-replace__matches">
        {matches.map((m, i) => (
          <li key={`${m.clip}:${m.segment_index}:${m.word_index}:${i}`}>
            <button type="button" onClick={() => onSelectMatch(m)}>
              <span className="find-replace__clip">{m.clip}</span>
              <span className="find-replace__snippet">{m.context_snippet}</span>
            </button>
          </li>
        ))}
      </ul>

      <div className="find-replace__actions">
        <button
          disabled={!canReplaceAll}
          onClick={async () => {
            if (scope === "library") {
              await applyLibraryReplace(searchTokens, newTokens);
            } else if (clip) {
              // Apply right-to-left within the clip to keep word_indices stable.
              const sorted = [...matches].sort((a, b) => {
                if (a.segment_index !== b.segment_index) return b.segment_index - a.segment_index;
                return b.word_index - a.word_index;
              });
              for (const m of sorted) {
                await applyClipReplace(clip, m, newTokens);
              }
            }
          }}
        >
          Replace all ({matches.length})
        </button>
      </div>
    </div>
  );
}
