import { useEffect, useRef } from "react";
import { listLibraries } from "../../../ipc/sidecar";
import { slugify, type SetupState, type SetupAction } from "../state";

export function Name({
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
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => {
    ref.current?.focus();
  }, []);

  useEffect(() => {
    const slug = slugify(state.name);
    if (!slug) {
      dispatch({ type: "set_collision", value: null });
      return;
    }
    let cancelled = false;
    listLibraries()
      .then((libs) => {
        if (cancelled) return;
        const hit = libs.find((l) => l.name === slug);
        dispatch({ type: "set_collision", value: hit ? slug : null });
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [state.name, dispatch]);

  const slug = slugify(state.name);
  const blocked = !slug || state.collisionWith === slug;

  return (
    <section className="np-step">
      <h2>Name</h2>
      <input
        ref={ref}
        value={state.name}
        onChange={(e) => dispatch({ type: "set_name", value: e.target.value })}
        placeholder="My Bike Series"
      />
      {slug ? (
        <p className="np-slug">
          → <code>{slug}</code>
        </p>
      ) : null}
      {state.collisionWith && state.collisionWith === slug ? (
        <p className="np-error">
          A library named <code>{slug}</code> already exists. Choose a different name.
        </p>
      ) : null}
      <footer className="np-footer">
        <button type="button" onClick={onBack}>
          Back
        </button>
        <button type="button" disabled={blocked} onClick={onNext}>
          Continue
        </button>
      </footer>
    </section>
  );
}
