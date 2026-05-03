import type { ClipState } from "../jobReducer";
import type { StageName } from "../../../ipc/events";
import { ArtifactPreview } from "./artifact-preview";

type StageGlyphState = ClipState["stages"][StageName];

const GLYPH: Record<StageGlyphState, string> = {
  idle: "○",
  queued: "⏳",
  in_progress: "◐",
  done: "✓",
  failed: "✗",
};

export function ClipRow({
  clip,
  library,
  onRetry,
  expanded,
  onToggle,
}: {
  clip: ClipState;
  library: string;
  onRetry: (stage: StageName) => void;
  expanded: boolean;
  onToggle: () => void;
}) {
  const stages: StageName[] = ["transcribe", "analyze", "summarize"];

  return (
    <div
      className={
        "np-row" + (clip.failure ? " np-row--failed" : "") + (expanded ? " np-row--expanded" : "")
      }
    >
      <button type="button" className="np-row__head" onClick={onToggle}>
        <span className="np-row__name">{clip.video}</span>
        {stages.map((s) => (
          <span key={s} className={`np-chip np-chip--${clip.stages[s]}`}>
            {GLYPH[clip.stages[s]]} {s}
          </span>
        ))}
      </button>

      {expanded ? (
        <div className="np-row__body">
          {clip.failure ? (
            <div className="np-failure">
              <strong>
                ✗ {clip.failure.stage} stage failed
              </strong>
              <pre>{clip.failure.message}</pre>
              <div className="np-failure-buttons">
                <button type="button" onClick={() => onRetry(clip.failure!.stage)}>
                  Retry {clip.failure.stage}
                </button>
              </div>
            </div>
          ) : (
            <ArtifactPreview clip={clip} library={library} />
          )}
        </div>
      ) : null}
    </div>
  );
}
