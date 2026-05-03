import type { AudioSegment, VisualSegment } from "./types";

export interface InterleavedRow {
  visual: VisualSegment;
  audio: AudioSegment[];
}

// Groups every audio segment whose start falls inside a visual segment's
// [start, end) interval underneath that visual row. Audio segments that fall
// outside any visual segment are dropped (rare in practice; if it happens
// we'd rather show nothing than orphaned dialogue with no scene context).
export function interleave(visual: VisualSegment[], audio: AudioSegment[]): InterleavedRow[] {
  return visual.map((v) => ({
    visual: v,
    audio: audio.filter((a) => a.start >= v.start && a.start < v.end)
  }));
}

export function formatTimestamp(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60).toString().padStart(2, "0");
  return `${m}:${s}`;
}
