import type { SetupState } from "../state";
import { slugify } from "../state";

export function Confirm({
  state,
  apiKeyConfigured,
  onBack,
  onStart,
  onSetupKey,
}: {
  state: SetupState;
  apiKeyConfigured: boolean;
  onBack: () => void;
  onStart: () => void;
  onSetupKey: () => void;
}) {
  const totalDuration = state.accepted.reduce((s, v) => s + v.duration_seconds, 0);
  const minutes = Math.round(totalDuration / 60);

  return (
    <section className="np-step">
      <h2>Confirm</h2>
      <ul className="np-summary">
        <li>
          <strong>Project:</strong> <code>{slugify(state.name)}</code>
        </li>
        <li>
          <strong>Videos:</strong> {state.accepted.length} ({minutes}m total)
        </li>
        <li>
          <strong>Language:</strong> {state.language.name} ({state.language.code})
        </li>
        <li>
          <strong>Refinement:</strong> {state.refinement ? "Yes" : "No"}
        </li>
      </ul>

      {!apiKeyConfigured ? (
        <div className="np-banner">
          <p>ButterCut needs your Anthropic API key to analyze footage.</p>
          <button type="button" onClick={onSetupKey}>
            Set up
          </button>
        </div>
      ) : null}

      <footer className="np-footer">
        <button type="button" onClick={onBack}>
          Back
        </button>
        <button type="button" onClick={onStart} disabled={!apiKeyConfigured}>
          Start analysis
        </button>
      </footer>
    </section>
  );
}
