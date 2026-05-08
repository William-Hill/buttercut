import { useEffect, useRef, useState } from "react";
import type { UnlistenFn } from "@tauri-apps/api/event";
import { startBrollDirector } from "../../ipc/sidecar";
import { listenBrollDirectorJobEvents, type BrollDirectorJobEvent } from "../../ipc/events";

type Props = {
  library: string;
  roughcutStem: string;
  hasManifest: boolean;
  manifestEntryCount?: number;
};

type Phase = "idle" | "gather" | "model" | "write" | "done" | "error";

export function AddBrollButton({
  library,
  roughcutStem,
  hasManifest,
  manifestEntryCount,
}: Props) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [message, setMessage] = useState<string>("");
  const unlistenRef = useRef<UnlistenFn | null>(null);

  const disposeListener = () => {
    unlistenRef.current?.();
    unlistenRef.current = null;
  };

  useEffect(() => disposeListener, []);

  const running = phase !== "idle" && phase !== "done" && phase !== "error";

  const handleClick = async () => {
    if (running) return;
    setPhase("gather");
    setMessage("Starting…");

    try {
      const jobId = await startBrollDirector({ library, roughcutStem });

      const unlisten = await listenBrollDirectorJobEvents(jobId, (ev: BrollDirectorJobEvent) => {
        switch (ev.method) {
          case "broll_job_started":
            break;
          case "broll_phase":
            setPhase((ev.params.phase as Phase) ?? "gather");
            setMessage(ev.params.message ?? ev.params.phase);
            break;
          case "broll_job_done":
            setPhase("done");
            setMessage(`${ev.params.entries_written} graphics ready to render`);
            disposeListener();
            break;
          case "broll_job_failed":
            setPhase("error");
            setMessage(ev.params.message ?? "Director failed");
            disposeListener();
            break;
        }
      });
      unlistenRef.current = unlisten;
    } catch (err) {
      setPhase("error");
      setMessage(err instanceof Error ? err.message : String(err));
      disposeListener();
    }
  };

  function buttonLabel(): string {
    if (running) return message || "Working…";
    if (phase === "done") return message || "B-Roll ready";
    if (phase === "error") return "Failed — retry";
    if (hasManifest) return `Re-run B-Roll Director (${manifestEntryCount ?? "?"} entries)`;
    return "Add B-Roll";
  }

  return (
    <button
      type="button"
      className="add-broll-button"
      disabled={running}
      onClick={handleClick}
      aria-busy={running}
      title={
        hasManifest
          ? "Replaces existing manifest"
          : "Generate b-roll manifest from this rough cut"
      }
    >
      {buttonLabel()}
    </button>
  );
}
