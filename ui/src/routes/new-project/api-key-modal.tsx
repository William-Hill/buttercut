import { useState } from "react";
import { setApiKey } from "../../ipc/sidecar";

function errMsg(e: unknown): string {
  if (e instanceof Error) return e.message;
  return String(e);
}

export function ApiKeyModal({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const [key, setKey] = useState("");
  const [status, setStatus] = useState<"idle" | "validating" | "error">("idle");
  const [error, setError] = useState<string | null>(null);

  async function save() {
    setStatus("validating");
    setError(null);
    try {
      await setApiKey(key);
      onSaved();
    } catch (e) {
      setStatus("error");
      setError(errMsg(e));
    }
  }

  return (
    <div className="np-modal-backdrop">
      <div className="np-modal">
        <h3>Connect your Anthropic API key</h3>
        <p>
          ButterCut uses Claude to analyze footage.{" "}
          <a href="https://console.anthropic.com" target="_blank" rel="noreferrer">
            Get a key →
          </a>
        </p>
        <label htmlFor="anthropic-api-key">API key</label>
        <input
          id="anthropic-api-key"
          type="password"
          value={key}
          onChange={(e) => setKey(e.target.value)}
          placeholder="sk-ant-…"
          autoFocus
        />
        {error ? <p className="np-error">{error}</p> : null}
        <div className="np-modal-buttons">
          <button type="button" onClick={onClose} disabled={status === "validating"}>
            Cancel
          </button>
          <button type="button" onClick={() => void save()} disabled={!key || status === "validating"}>
            {status === "validating" ? "Validating…" : "Save"}
          </button>
        </div>
      </div>
    </div>
  );
}
