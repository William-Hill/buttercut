import { useEffect, useRef, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import { getOrGenerateThumbnail } from "../../ipc/sidecar";

type ThumbState =
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "ready"; src: string }
  | { kind: "error" };

// Lazily resolves a clip thumbnail. Uses IntersectionObserver so cards out
// of view don't trigger ffmpeg shell-outs.
export function useThumbnail(library: string, video: string) {
  const [state, setState] = useState<ThumbState>({ kind: "idle" });
  const ref = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let cancelled = false;

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          observer.disconnect();
          setState({ kind: "loading" });
          getOrGenerateThumbnail(library, video)
            .then(({ path }) => {
              if (!cancelled) setState({ kind: "ready", src: convertFileSrc(path) });
            })
            .catch(() => {
              if (!cancelled) setState({ kind: "error" });
            });
        }
      },
      { rootMargin: "200px" }
    );
    observer.observe(el);
    return () => {
      cancelled = true;
      observer.disconnect();
    };
  }, [library, video]);

  return { ref, state };
}
