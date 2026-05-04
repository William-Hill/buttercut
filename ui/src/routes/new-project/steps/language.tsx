import { useState } from "react";
import type { SetupState, SetupAction } from "../state";

const PRESETS = [
  { name: "English", code: "en" },
  { name: "Spanish", code: "es" },
];

export function Language({
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
  const [other, setOther] = useState(state.language.code);
  const isPreset = PRESETS.some((p) => p.code === state.language.code);

  return (
    <section className="np-step">
      <h2>Language</h2>
      <div className="np-cards">
        {PRESETS.map((p) => (
          <button
            key={p.code}
            type="button"
            className={"np-card" + (state.language.code === p.code ? " np-card--active" : "")}
            onClick={() => dispatch({ type: "set_language", name: p.name, code: p.code })}
          >
            {p.name}
          </button>
        ))}
        <button
          type="button"
          className={"np-card" + (!isPreset ? " np-card--active" : "")}
          onClick={() => {
            if (isPreset) setOther("");
            dispatch({ type: "set_language", name: "Other", code: isPreset ? "" : other });
          }}
        >
          Other…
        </button>
      </div>
      {!isPreset ? (
        <label className="np-other">
          ISO 639-1 code
          <input
            value={other}
            onChange={(e) => {
              const v = e.target.value;
              setOther(v);
              dispatch({ type: "set_language", name: "Other", code: v });
            }}
          />
        </label>
      ) : null}
      <footer className="np-footer">
        <button type="button" onClick={onBack}>
          Back
        </button>
        <button type="button" disabled={!state.language.code} onClick={onNext}>
          Continue
        </button>
      </footer>
    </section>
  );
}
