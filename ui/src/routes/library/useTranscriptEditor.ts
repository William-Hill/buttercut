// ui/src/routes/library/useTranscriptEditor.ts
import { useCallback, useEffect, useRef, useState } from "react";
import {
  applyTranscriptEdit,
  applyLibraryReplace,
  findTranscriptMatches,
  listenTranscriptEdited,
} from "../../ipc/sidecar";
import type {
  ApplyEditResult,
  ApplyLibraryReplaceResult,
  FinderMatch,
  ReplaceScope,
  TranscriptEdit,
  UndoEntry,
} from "./editorTypes";

interface ScrollAnchor {
  segmentIndex: number;
  wordIndex: number;
  viewportOffset: number;
}

export interface UseTranscriptEditorArgs {
  library: string;
  clip: string | null;
  scrollContainerRef: React.RefObject<HTMLElement | null>;
  onTranscriptEdited: () => void; // caller refetches; hook restores anchor afterwards
}

export function useTranscriptEditor({ library, clip, scrollContainerRef, onTranscriptEdited }: UseTranscriptEditorArgs) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const undoRef = useRef<UndoEntry | null>(null);
  const anchorRef = useRef<ScrollAnchor | null>(null);

  // Reset undo stack when the open clip changes.
  useEffect(() => {
    undoRef.current = null;
  }, [clip]);

  // Subscribe to transcript_edited; capture anchor + ask caller to refetch.
  useEffect(() => {
    let unlisten: (() => void) | null = null;
    listenTranscriptEdited((e) => {
      if (e.library !== library || e.clip !== clip) return;
      anchorRef.current = captureAnchor(scrollContainerRef.current);
      onTranscriptEdited();
    }).then((fn) => { unlisten = fn; });
    return () => { unlisten?.(); };
  }, [library, clip, scrollContainerRef, onTranscriptEdited]);

  // Restore anchor after the caller's refetch + re-render. Caller invokes
  // restoreAnchor() in a useLayoutEffect tied to the new transcript content.
  const restoreAnchor = useCallback(() => {
    const anchor = anchorRef.current;
    anchorRef.current = null;
    if (!anchor || !scrollContainerRef.current) return;
    const container = scrollContainerRef.current;
    const sel = `[data-segment="${anchor.segmentIndex}"][data-word-index="${anchor.wordIndex}"]`;
    const el = container.querySelector<HTMLElement>(sel);
    if (!el) return;
    const containerTop = container.getBoundingClientRect().top;
    const wordTop = el.getBoundingClientRect().top;
    container.scrollTop += wordTop - containerTop - anchor.viewportOffset;
  }, [scrollContainerRef]);

  const editClipScope = useCallback(async (clipName: string, edit: TranscriptEdit): Promise<ApplyEditResult | null> => {
    setBusy(true); setError(null);
    try {
      anchorRef.current = captureAnchor(scrollContainerRef.current);
      const r = await applyTranscriptEdit(library, clipName, edit);
      undoRef.current = {
        scope: "clip",
        inverse_edit: { ...edit, old_tokens: edit.new_tokens, new_tokens: edit.old_tokens, clip: clipName },
      };
      // The sidecar emits transcript_edited; the listener triggers refetch.
      // For clip scope we still emit the event from sidecar via TranscriptEditor?
      // No — TranscriptEditor doesn't notify; only LibraryReplacer does.
      // Trigger refetch directly here.
      onTranscriptEdited();
      return r;
    } catch (e) {
      setError(String(e));
      return null;
    } finally {
      setBusy(false);
    }
  }, [library, scrollContainerRef, onTranscriptEdited]);

  const replaceLibrary = useCallback(async (oldTokens: string[], newTokens: string[], scope: ReplaceScope): Promise<ApplyLibraryReplaceResult | null> => {
    setBusy(true); setError(null);
    try {
      anchorRef.current = captureAnchor(scrollContainerRef.current);
      const trust = scope === "trust";
      const r = await applyLibraryReplace(library, oldTokens, newTokens, trust);
      // For trust=true, only mark "remove from user_context on undo" if the
      // server actually appended the term (we approximate: any successful
      // trust replace counts; idempotent re-runs are harmless on undo).
      undoRef.current = {
        scope,
        inverse_replace: {
          old_tokens: newTokens,
          new_tokens: oldTokens,
          remove_user_context_term: trust ? newTokens.join(" ") : null,
        },
      };
      // listenTranscriptEdited will fire onTranscriptEdited per affected clip
      // for this library; nothing extra to do here.
      return r;
    } catch (e) {
      setError(String(e));
      return null;
    } finally {
      setBusy(false);
    }
  }, [library, scrollContainerRef]);

  const findMatches = useCallback(async (tokens: string[], scope: "clip" | "library", clipName?: string): Promise<FinderMatch[]> => {
    if (tokens.length === 0) return [];
    try {
      const r = await findTranscriptMatches(library, tokens, scope, clipName);
      return r.matches;
    } catch (e) {
      setError(String(e));
      return [];
    }
  }, [library]);

  const undo = useCallback(async () => {
    const entry = undoRef.current;
    if (!entry) return;
    undoRef.current = null;
    if (entry.scope === "clip" && entry.inverse_edit) {
      const { clip: c, ...edit } = entry.inverse_edit;
      anchorRef.current = captureAnchor(scrollContainerRef.current);
      await applyTranscriptEdit(library, c, edit);
      onTranscriptEdited();
    } else if (entry.inverse_replace) {
      anchorRef.current = captureAnchor(scrollContainerRef.current);
      // Note: trust-scope undo cannot remove the term from user_context via
      // the existing apply_library_replace API. v1 leaves the term in
      // user_context on undo (a known minor leak; documented in PR notes).
      await applyLibraryReplace(library, entry.inverse_replace.old_tokens, entry.inverse_replace.new_tokens, false);
    }
  }, [library, scrollContainerRef, onTranscriptEdited]);

  return { busy, error, editClipScope, replaceLibrary, findMatches, undo, restoreAnchor };
}

function captureAnchor(container: HTMLElement | null): ScrollAnchor | null {
  if (!container) return null;
  const containerRect = container.getBoundingClientRect();
  const words = container.querySelectorAll<HTMLElement>("[data-segment][data-word-index]");
  for (const w of Array.from(words)) {
    const r = w.getBoundingClientRect();
    if (r.top >= containerRect.top) {
      return {
        segmentIndex: Number(w.dataset.segment),
        wordIndex: Number(w.dataset.wordIndex),
        viewportOffset: r.top - containerRect.top,
      };
    }
  }
  return null;
}
