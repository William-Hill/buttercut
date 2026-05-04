import { useEffect, useReducer, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { initialSetup, setupReducer, type StepId } from "./state";
import { PickFootage } from "./steps/pick-footage";
import { Name } from "./steps/name";
import { Language } from "./steps/language";
import { Refinement } from "./steps/refinement";
import { Confirm } from "./steps/confirm";
import { ApiKeyModal } from "./api-key-modal";
import { ProgressView } from "./progress/progress-view";
import { createLibrary, hasApiKey, startAnalysis } from "../../ipc/sidecar";
import "./new-project.css";

const STEPS: StepId[] = ["footage", "name", "language", "refinement", "confirm"];

function errMsg(e: unknown): string {
  if (e instanceof Error) return e.message;
  return String(e);
}

export default function NewProject() {
  const [state, dispatch] = useReducer(setupReducer, initialSetup);
  const [phase, setPhase] = useState<"setup" | "progress">("setup");
  const [job, setJob] = useState<{ id: string; library: string } | null>(null);
  const [keyConfigured, setKeyConfigured] = useState(false);
  const [showKeyModal, setShowKeyModal] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    hasApiKey()
      .then((r) => setKeyConfigured(r.configured))
      .catch(() => setKeyConfigured(false));
  }, []);

  const idx = STEPS.indexOf(state.step);
  const goNext = () => dispatch({ type: "go_step", step: STEPS[Math.min(STEPS.length - 1, idx + 1)] });
  const goBack = () => dispatch({ type: "go_step", step: STEPS[Math.max(0, idx - 1)] });

  async function start() {
    setError(null);
    try {
      const { name } = await createLibrary({
        name: state.name,
        language: state.language.name,
        language_code: state.language.code,
        refinement: state.refinement,
        videos: state.accepted,
      });
      const { job_id } = await startAnalysis(name);
      setJob({ id: job_id, library: name });
      setPhase("progress");
    } catch (e) {
      setError(errMsg(e));
    }
  }

  if (phase === "progress" && job) {
    return (
      <ProgressView
        key={job.id}
        jobId={job.id}
        library={job.library}
        onComplete={() => void getCurrentWindow().close()}
        onRestartJob={(newId) => setJob({ id: newId, library: job.library })}
      />
    );
  }

  return (
    <main className="np">
      <nav className="np-breadcrumb" aria-label="Setup steps">
        {STEPS.map((s, i) => (
          <span key={s} className={"np-breadcrumb__item" + (i === idx ? " np-breadcrumb__item--active" : "")}>
            {i + 1}. {s}
          </span>
        ))}
      </nav>

      {state.step === "footage" ? <PickFootage state={state} dispatch={dispatch} onNext={goNext} /> : null}
      {state.step === "name" ? <Name state={state} dispatch={dispatch} onBack={goBack} onNext={goNext} /> : null}
      {state.step === "language" ? (
        <Language state={state} dispatch={dispatch} onBack={goBack} onNext={goNext} />
      ) : null}
      {state.step === "refinement" ? (
        <Refinement state={state} dispatch={dispatch} onBack={goBack} onNext={goNext} />
      ) : null}
      {state.step === "confirm" ? (
        <Confirm
          state={state}
          apiKeyConfigured={keyConfigured}
          onBack={goBack}
          onStart={start}
          onSetupKey={() => setShowKeyModal(true)}
        />
      ) : null}

      {error ? <p className="np-error np-error--global">{error}</p> : null}

      {showKeyModal ? (
        <ApiKeyModal
          onClose={() => setShowKeyModal(false)}
          onSaved={() => {
            setShowKeyModal(false);
            setKeyConfigured(true);
          }}
        />
      ) : null}
    </main>
  );
}
