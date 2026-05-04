import type { SetupState, SetupAction } from "../state";

export function Refinement({
  state,
  dispatch,
  onBack,
  onNext,
}: {
  state: SetupState;
  dispatch: React.Dispatch<SetupAction>;
  onBack: () => void;
  onNext: () => void;
}) {
  return (
    <section className="np-step">
      <h2>Can I proofread the transcripts after they&apos;re generated?</h2>
      <p>I&apos;ll use the video&apos;s context to fix mistakes.</p>
      <div className="np-cards np-cards--stack">
        <button
          type="button"
          className={"np-card" + (state.refinement ? " np-card--active" : "")}
          onClick={() => dispatch({ type: "set_refinement", value: true })}
        >
          <strong>Yes — Recommended</strong>
          <span className="np-card__sub">Use Claude to refine video understanding.</span>
        </button>
        <button
          type="button"
          className={"np-card" + (!state.refinement ? " np-card--active" : "")}
          onClick={() => dispatch({ type: "set_refinement", value: false })}
        >
          <strong>No</strong>
        </button>
      </div>
      <footer className="np-footer">
        <button type="button" onClick={onBack}>
          Back
        </button>
        <button type="button" onClick={onNext}>
          Continue
        </button>
      </footer>
    </section>
  );
}
