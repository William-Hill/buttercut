import { convertFileSrc } from "@tauri-apps/api/core";
import { useEffect, useRef } from "react";
import type { RoughcutClip } from "../../ipc/events";
import {
  buildTimelineSegments,
  formatRoughcutClock,
  segmentIndexForGlobalTime,
  timecodeToSeconds,
} from "../../lib/roughcutTimeline";
import type { VideoEntry } from "./types";

function basename(p: string): string {
  const i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"));
  return i >= 0 ? p.slice(i + 1) : p;
}

function clampToClipWindow(t: number, inSec: number, outSec: number): number {
  const min = inSec + 0.02;
  const max = outSec - 0.02;
  if (!Number.isFinite(t)) return Math.max(0, inSec);
  if (max <= min) {
    return Math.max(0, Math.min(Math.max(t, inSec), outSec));
  }
  return Math.min(Math.max(t, min), max);
}

export type RoughcutStagePreviewProps = {
  clips: RoughcutClip[];
  videos: VideoEntry[];
  playheadSec: number;
  onPlayheadSecChange: (t: number) => void;
  playing: boolean;
  onPlayingChange: (v: boolean) => void;
};

export default function RoughcutStagePreview({
  clips,
  videos,
  playheadSec,
  onPlayheadSecChange,
  playing,
  onPlayingChange,
}: RoughcutStagePreviewProps) {
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const segments = buildTimelineSegments(clips);
  const pathByAbsolute = new Map(videos.map((v) => [v.path, v.path]));
  const pathsByFilename = new Map<string, string[]>();
  for (const v of videos) {
    const arr = pathsByFilename.get(v.filename) ?? [];
    arr.push(v.path);
    pathsByFilename.set(v.filename, arr);
  }

  const i = segmentIndexForGlobalTime(segments, playheadSec);
  const clip = clips[i];
  const seg = segments[i];
  const direct = pathByAbsolute.get(clip.source_file);
  const nameMatches = pathsByFilename.get(basename(clip.source_file)) ?? [];
  const resolved = direct ?? (nameMatches.length === 1 ? nameMatches[0] : "");
  const src = resolved ? convertFileSrc(resolved) : "";
  const inSec = timecodeToSeconds(clip.in_point);
  const outSec = timecodeToSeconds(clip.out_point);
  const localT = playheadSec - seg.startGlobal + inSec;

  useEffect(() => {
    const v = videoRef.current;
    if (!v || !src) return;
    if (playing) {
      void v.play().catch(() => onPlayingChange(false));
    } else {
      v.pause();
    }
  }, [playing, src, onPlayingChange]);

  useEffect(() => {
    if (playing) return;
    const v = videoRef.current;
    if (!v || !src) return;
    const clamped = clampToClipWindow(localT, inSec, outSec);
    if (Number.isFinite(clamped) && Math.abs(v.currentTime - clamped) > 0.08) {
      v.currentTime = clamped;
    }
  }, [playheadSec, i, localT, inSec, outSec, src, playing]);

  const total = segments.length ? segments[segments.length - 1].endGlobal : 0;

  if (!resolved) {
    return (
      <div className="roughcut-preview roughcut-preview--missing">
        <p>No library path for source file</p>
        <code>{clip.source_file}</code>
      </div>
    );
  }

  return (
    <div className="roughcut-preview">
      <div className="roughcut-preview__chrome">
        <button
          type="button"
          className="roughcut-preview__play"
          onClick={() => onPlayingChange(!playing)}
          aria-pressed={playing}
        >
          {playing ? "Pause" : "Play"}
        </button>
        <span className="roughcut-preview__time">
          {formatRoughcutClock(playheadSec)} / {formatRoughcutClock(total)}
        </span>
        <span className="roughcut-preview__clip-label">
          {basename(clip.source_file)}
        </span>
      </div>
      <div className="roughcut-preview__frame">
        <video
          key={`${i}-${src}`}
          ref={videoRef}
          className="roughcut-preview__video"
          src={src}
          playsInline
          onLoadedMetadata={(e) => {
            const v = e.currentTarget;
            const t = clampToClipWindow(localT, inSec, outSec);
            v.currentTime = Number.isFinite(t) ? t : inSec;
          }}
          onTimeUpdate={(e) => {
            if (!playing) return;
            const v = e.currentTarget;
            if (v.currentTime >= outSec - 0.06) {
              v.pause();
              onPlayingChange(false);
              const end = seg.endGlobal;
              if (playheadSec < end - 0.01) onPlayheadSecChange(end);
              return;
            }
            onPlayheadSecChange(seg.startGlobal + (v.currentTime - inSec));
          }}
        />
      </div>
    </div>
  );
}
