import { useEffect, useState } from "react";
import { getClipTranscripts } from "../../../ipc/sidecar";
import type { ClipTranscripts } from "../../library/types";
import type { ClipState } from "../jobReducer";

export function ArtifactPreview({ clip, library }: { clip: ClipState; library: string }) {
  const [data, setData] = useState<{ audio: string | null; visual: string | null; summary: string | null }>({
    audio: null,
    visual: null,
    summary: null,
  });

  useEffect(() => {
    let cancelled = false;
    getClipTranscripts(library, clip.video)
      .then((t: ClipTranscripts) => {
        if (cancelled) return;
        setData({
          audio: previewAudio(t.audio),
          visual: previewVisual(t.visual),
          summary: t.summary ?? null,
        });
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [clip.artifacts.transcribe, clip.artifacts.analyze, clip.artifacts.summarize, library, clip.video]);

  return (
    <div className="np-preview">
      {data.summary ? (
        <section>
          <h4>Summary</h4>
          <pre className="np-md">{data.summary}</pre>
        </section>
      ) : null}
      {data.visual ? (
        <section>
          <h4>Visual transcript</h4>
          <pre>{data.visual}</pre>
        </section>
      ) : null}
      {data.audio ? (
        <section>
          <h4>Transcript</h4>
          <pre>{data.audio}</pre>
        </section>
      ) : null}
    </div>
  );
}

function previewAudio(t: ClipTranscripts["audio"]): string | null {
  if (!t?.segments?.length) return null;
  return t.segments
    .slice(0, 6)
    .map((s) => s.text)
    .join(" ")
    .trim() || null;
}

function previewVisual(t: ClipTranscripts["visual"]): string | null {
  if (!t?.segments?.length) return null;
  return t.segments
    .slice(0, 6)
    .map((s) => s.visual || s.text || "")
    .filter(Boolean)
    .join("\n");
}
