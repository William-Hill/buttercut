import type { RoughcutClip } from "../ipc/events";

export type TimelineSegment = {
  uiIndex: number;
  sourceFile: string;
  durationSec: number;
  startGlobal: number;
  endGlobal: number;
};

export function timecodeToSeconds(tc: string): number {
  const parts = tc.trim().split(":");
  if (parts.length < 3) return 0;
  const h = Number(parts[0]);
  const m = Number(parts[1]);
  const s = Number(parts[2]);
  if (![h, m, s].every((x) => Number.isFinite(x))) return 0;
  return h * 3600 + m * 60 + s;
}

export function buildTimelineSegments(clips: RoughcutClip[]): TimelineSegment[] {
  let acc = 0;
  return clips.map((c, uiIndex) => {
    const dur = Math.max(0.001, timecodeToSeconds(c.out_point) - timecodeToSeconds(c.in_point));
    const seg: TimelineSegment = {
      uiIndex,
      sourceFile: c.source_file,
      durationSec: dur,
      startGlobal: acc,
      endGlobal: acc + dur,
    };
    acc += dur;
    return seg;
  });
}

export function segmentIndexForGlobalTime(segments: TimelineSegment[], t: number): number {
  if (segments.length === 0) return 0;
  const total = segments[segments.length - 1].endGlobal;
  const x = Math.max(0, Math.min(t, total));
  for (let i = 0; i < segments.length; i++) {
    if (x < segments[i].endGlobal) return i;
  }
  return segments.length - 1;
}

export function localSourceSeconds(clips: RoughcutClip[], segments: TimelineSegment[], globalSec: number): number {
  const i = segmentIndexForGlobalTime(segments, globalSec);
  const inSec = timecodeToSeconds(clips[i].in_point);
  return globalSec - segments[i].startGlobal + inSec;
}
