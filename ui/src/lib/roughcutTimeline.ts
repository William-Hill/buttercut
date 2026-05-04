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

/** m:ss for timeline / preview chrome (sub-minute projects only need seconds). */
export function formatRoughcutClock(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) return "0:00";
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
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
