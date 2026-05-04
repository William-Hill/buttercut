import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { findTranscriptMatches, getClipTranscripts } from "../../ipc/sidecar";
import type { ClipTranscripts } from "./types";
import { formatTimestamp, interleave, InterleavedRow } from "./interleave";
import EditPopover from "./EditPopover";
import FindReplacePanel from "./FindReplacePanel";
import WordToken from "./WordToken";
import { useTranscriptEditor } from "./useTranscriptEditor";
import type { FinderMatch, TranscriptEdit } from "./editorTypes";

interface Props {
  library: string;
  video: string | null;
  onSeek: (seconds: number) => void;
  /** Switch active clip (e.g. when jumping to a find/replace match in another clip). */
  onClipChange?: (filename: string) => void;
}

type LoadState =
  | { kind: "idle" }
  | { kind: "loading"; library: string; video: string }
  | { kind: "ready"; library: string; video: string; transcripts: ClipTranscripts; revision: number }
  | { kind: "error"; library: string; video: string; message: string };

interface PopoverState {
  anchor: HTMLElement;
  segmentIndex: number;
  wordIndex: number;
  currentToken: string;
}

function matchesActive(state: LoadState, library: string, video: string | null): boolean {
  if (state.kind === "idle") return false;
  return state.library === library && state.video === video;
}

export default function TranscriptZone({ library, video, onSeek, onClipChange }: Props) {
  const [state, setState] = useState<LoadState>({ kind: "idle" });
  const [popover, setPopover] = useState<PopoverState | null>(null);
  const [findOpen, setFindOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const refetchTokenRef = useRef(0);
  const scrollPendingRef = useRef<FinderMatch | null>(null);

  const refetch = useCallback(() => {
    if (!video) return;
    const token = ++refetchTokenRef.current;
    getClipTranscripts(library, video).then((transcripts) => {
      if (refetchTokenRef.current !== token) return;
      setState((prev) => ({
        kind: "ready",
        library, video, transcripts,
        revision: prev.kind === "ready" ? prev.revision + 1 : 1,
      }));
    });
  }, [library, video]);

  const editor = useTranscriptEditor({
    library, clip: video,
    scrollContainerRef: containerRef,
    onTranscriptEdited: refetch,
  });

  // Restore scroll anchor after each refetch's re-render.
  useLayoutEffect(() => {
    if (state.kind !== "ready") return;
    const pending = scrollPendingRef.current;
    if (pending && video && pending.clip === video) {
      const sel = `[data-segment="${pending.segment_index}"][data-word-index="${pending.word_index}"]`;
      const el = containerRef.current?.querySelector<HTMLElement>(sel);
      el?.scrollIntoView({ block: "center", behavior: "smooth" });
      scrollPendingRef.current = null;
      return;
    }
    editor.restoreAnchor();
  }, [state.kind === "ready" ? state.revision : 0, video, editor, state.kind]);

  // ⌘F opens find/replace.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "f") {
        e.preventDefault();
        setFindOpen((v) => !v);
      }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") {
        e.preventDefault();
        editor.undo();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [editor]);

  useEffect(() => {
    if (!video) {
      setState({ kind: "idle" });
      return;
    }
    let cancelled = false;
    setState({ kind: "loading", library, video });
    getClipTranscripts(library, video)
      .then((transcripts) => { if (!cancelled) setState({ kind: "ready", library, video, transcripts, revision: 1 }); })
      .catch((err) => { if (!cancelled) setState({ kind: "error", library, video, message: String(err) }); });
    return () => { cancelled = true; };
  }, [library, video]);

  if (!matchesActive(state, library, video)) {
    return <div ref={containerRef} className="transcript-zone transcript-zone--empty">{video ? "Loading transcripts…" : "No clip selected."}</div>;
  }
  if (state.kind === "idle" || !video) {
    return <div ref={containerRef} className="transcript-zone transcript-zone--empty">No clip selected.</div>;
  }
  if (state.kind === "loading") {
    return <div ref={containerRef} className="transcript-zone transcript-zone--empty">Loading transcripts…</div>;
  }
  if (state.kind === "error") {
    return (
      <div ref={containerRef} className="transcript-zone transcript-zone--empty">
        <p>Couldn't load transcripts.</p>
        <pre>{state.message}</pre>
      </div>
    );
  }

  const visualSegments = state.transcripts.visual?.segments ?? [];
  const audioSegments = state.transcripts.audio?.segments ?? [];

  const onEditRequest = (anchor: HTMLElement, segmentIndex: number, wordIndex: number, currentToken: string) => {
    setPopover({ anchor, segmentIndex, wordIndex, currentToken });
  };

  const submitPopover = async ({ newToken, scope }: { newToken: string; scope: "clip" | "library" | "trust" }) => {
    if (!popover) return;
    if (scope === "clip") {
      const edit: TranscriptEdit = {
        segment_index: popover.segmentIndex,
        word_index: popover.wordIndex,
        old_tokens: [popover.currentToken],
        new_tokens: [newToken],
      };
      await editor.editClipScope(video, edit);
    } else {
      await editor.replaceLibrary([popover.currentToken], [newToken], scope);
    }
    setPopover(null);
  };

  const fetchMatchCount = useCallback(async (token: string) => {
    const r = await findTranscriptMatches(library, [token], "library");
    const matches = r.matches.length;
    const clips = new Set(r.matches.map((m) => m.clip)).size;
    return { matches, clips };
  }, [library]);

  const applyClipReplaceFromPanel = async (clipName: string, m: FinderMatch, newTokens: string[]) => {
    await editor.editClipScope(clipName, {
      segment_index: m.segment_index,
      word_index: m.word_index,
      old_tokens: m.matched_tokens,
      new_tokens: newTokens,
    });
  };

  const applyLibraryReplaceFromPanel = async (oldTokens: string[], newTokens: string[]) => {
    await editor.replaceLibrary(oldTokens, newTokens, "library");
  };

  const onSelectMatch = (m: FinderMatch) => {
    if (video && m.clip !== video) {
      scrollPendingRef.current = m;
      onClipChange?.(m.clip);
      return;
    }
    const sel = `[data-segment="${m.segment_index}"][data-word-index="${m.word_index}"]`;
    const el = containerRef.current?.querySelector<HTMLElement>(sel);
    el?.scrollIntoView({ block: "center", behavior: "smooth" });
  };

  const renderRows = () => {
    if (visualSegments.length === 0 && audioSegments.length === 0) {
      return <div className="transcript-zone--empty">This clip hasn't been analyzed yet.</div>;
    }
    if (visualSegments.length === 0) {
      return audioSegments.map((seg, i) => (
        <AudioRow key={i} segment={seg} segmentIndex={i} onSeek={onSeek} onEditRequest={onEditRequest} />
      ));
    }
    const rows = interleave(visualSegments, audioSegments);
    return rows.map((row, i) => <Row key={i} row={row} onSeek={onSeek} onEditRequest={onEditRequest} segments={audioSegments} />);
  };

  return (
    <div ref={containerRef} className="transcript-zone">
      {renderRows()}

      {popover && (
        <EditPopover
          library={library}
          clip={video}
          segmentIndex={popover.segmentIndex}
          wordIndex={popover.wordIndex}
          currentToken={popover.currentToken}
          anchor={popover.anchor}
          busy={editor.busy}
          onCancel={() => setPopover(null)}
          onSubmit={submitPopover}
          fetchMatchCount={fetchMatchCount}
        />
      )}

      {findOpen && (
        <FindReplacePanel
          library={library}
          clip={video}
          busy={editor.busy}
          onClose={() => setFindOpen(false)}
          findMatches={editor.findMatches}
          applyClipReplace={applyClipReplaceFromPanel}
          applyLibraryReplace={applyLibraryReplaceFromPanel}
          onSelectMatch={onSelectMatch}
        />
      )}

      {editor.error && <div className="transcript-zone__toast">{editor.error}</div>}
    </div>
  );
}

function Row({
  row, onSeek, onEditRequest, segments,
}: {
  row: InterleavedRow;
  onSeek: (s: number) => void;
  onEditRequest: (anchor: HTMLElement, segmentIndex: number, wordIndex: number, currentToken: string) => void;
  segments: import("./types").AudioSegment[];
}) {
  return (
    <div className="row">
      <button className="row__visual" onClick={() => onSeek(row.visual.start)}>
        <span className="row__time">[{formatTimestamp(row.visual.start)}]</span>
        <span className="row__visual-text">{row.visual.visual}</span>
        {row.visual.b_roll && <span className="row__chip">b-roll</span>}
      </button>
      {row.audio.map((seg) => {
        const segmentIndex = segments.indexOf(seg);
        return <AudioRow key={segmentIndex} segment={seg} segmentIndex={segmentIndex} onSeek={onSeek} onEditRequest={onEditRequest} />;
      })}
    </div>
  );
}

function AudioRow({
  segment, segmentIndex, onSeek, onEditRequest,
}: {
  segment: import("./types").AudioSegment;
  segmentIndex: number;
  onSeek: (s: number) => void;
  onEditRequest: (anchor: HTMLElement, segmentIndex: number, wordIndex: number, currentToken: string) => void;
}) {
  if (segment.words && segment.words.length > 0) {
    return (
      <p className="row__audio">
        <span className="row__time">[{formatTimestamp(segment.start)}]</span>
        {segment.words.map((w, i) => (
          <WordToken
            key={i}
            word={w}
            segmentIndex={segmentIndex}
            wordIndex={i}
            onSeek={onSeek}
            onEditRequest={onEditRequest}
          />
        ))}
      </p>
    );
  }
  return (
    <p className="row__audio">
      <button className="row__audio-text" onClick={() => onSeek(segment.start)}>
        <span className="row__time">[{formatTimestamp(segment.start)}]</span>
        {segment.text}
      </button>
    </p>
  );
}
