// ui/src/routes/library/EditPopover.tsx
import { useEffect, useMemo, useRef, useState } from "react";
import { validateSingleToken } from "./tokenValidation";
import type { ReplaceScope } from "./editorTypes";

export interface EditPopoverProps {
  library: string;
  clip: string;
  segmentIndex: number;
  wordIndex: number;
  currentToken: string;
  anchor: HTMLElement;
  busy: boolean;
  onCancel: () => void;
  onSubmit: (args: { newToken: string; scope: ReplaceScope }) => void;
  // Async match counter for library/trust scopes. Returns the number of
  // matches and clip count.
  fetchMatchCount: (token: string) => Promise<{ matches: number; clips: number }>;
}

export default function EditPopover(props: EditPopoverProps) {
  const { currentToken, anchor, busy, onCancel, onSubmit, fetchMatchCount } = props;
  const [value, setValue] = useState(currentToken);
  const [scope, setScope] = useState<ReplaceScope>("clip");
  const [matchInfo, setMatchInfo] = useState<{ matches: number; clips: number } | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);

  const validation = useMemo(() => validateSingleToken(value), [value]);
  const position = anchorPosition(anchor);

  useEffect(() => { inputRef.current?.focus(); inputRef.current?.select(); }, []);
  useEffect(() => {
    if (scope === "clip") { setMatchInfo(null); return; }
    let cancelled = false;
    fetchMatchCount(value)
      .then((r) => { if (!cancelled) setMatchInfo(r); })
      .catch(() => { if (!cancelled) setMatchInfo(null); });
    return () => { cancelled = true; };
  }, [scope, value, fetchMatchCount]);

  const canSubmit = validation.valid && !busy && value !== currentToken;

  return (
    <div
      className="edit-popover"
      style={{ top: position.top, left: position.left }}
      onKeyDown={(e) => {
        if (e.key === "Escape") { e.preventDefault(); onCancel(); }
        if (e.key === "Enter" && canSubmit) {
          e.preventDefault();
          onSubmit({ newToken: validation.tokens[0], scope });
        }
      }}
    >
      <input
        ref={inputRef}
        className="edit-popover__input"
        value={value}
        onChange={(e) => setValue(e.target.value)}
      />
      {!validation.valid && <p className="edit-popover__error">{validation.error}</p>}

      <fieldset className="edit-popover__scope">
        <label><input type="radio" name="scope" checked={scope === "clip"} onChange={() => setScope("clip")} /> This clip</label>
        <label><input type="radio" name="scope" checked={scope === "library"} onChange={() => setScope("library")} /> This library</label>
        <label><input type="radio" name="scope" checked={scope === "trust"} onChange={() => setScope("trust")} /> Trust globally</label>
      </fieldset>

      {scope !== "clip" && matchInfo && (
        <p className="edit-popover__count">
          Found {matchInfo.matches} match{matchInfo.matches === 1 ? "" : "es"} across {matchInfo.clips} clip{matchInfo.clips === 1 ? "" : "s"}.
        </p>
      )}

      <div className="edit-popover__actions">
        <button onClick={onCancel} disabled={busy}>Cancel</button>
        <button
          className="edit-popover__submit"
          disabled={!canSubmit}
          onClick={() => onSubmit({ newToken: validation.tokens[0], scope })}
        >
          {busy ? "Replacing…" : "Replace"}
        </button>
      </div>
    </div>
  );
}

function anchorPosition(anchor: HTMLElement) {
  const r = anchor.getBoundingClientRect();
  return { top: r.bottom + 4, left: r.left };
}
