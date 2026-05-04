import { convertFileSrc } from "@tauri-apps/api/core";
import { useEffect, useRef } from "react";
import type { RoughcutClip } from "../../ipc/events";
import {
  buildTimelineSegments,
  segmentIndexForGlobalTime,
  timecodeToSeconds,
} from "../../lib/roughcutTimeline";
import type { VideoEntry } from "./types";

function basename(p: string): string {
  const i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"));
  return i >= 0 ? p.slice(i + 1) : p;
}

function formatClock(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) return "0:00";
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
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
  const pathByFile = new Map(videos.map((v) => [v.filename, v.path]));

  const i = segmentIndexForGlobalTime(segments, playheadSec);
  const clip = clips[i];
  const seg = segments[i];
  const resolved = pathByFile.get(basename(clip.source_file)) ?? pathByFile.get(clip.source_file);
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
    const clamped = Math.min(Math.max(localT, inSec + 0.02), outSec - 0.02);
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
          {formatClock(playheadSec)} / {formatClock(total)}
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
            const t = Math.min(Math.max(localT, inSec + 0.02), outSec - 0.02);
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
