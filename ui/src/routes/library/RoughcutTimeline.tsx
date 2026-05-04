import { useCallback, useRef, useState } from "react";
import type { RoughcutClip } from "../../ipc/events";
import type { RecipeJson } from "../../lib/recipeTypes";
import { transitionAfterUiIndex } from "../../lib/recipeTypes";
import { buildTimelineSegments, type TimelineSegment } from "../../lib/roughcutTimeline";
import { ClipRecipeGlyphs, GapTransitionGlyph } from "./RecipeGlyphs";

function formatClock(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) return "0:00";
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export type RoughcutTimelineProps = {
  clips: RoughcutClip[];
  recipe: RecipeJson | null;
  playheadSec: number;
  onPlayheadSecChange: (t: number) => void;
  onScrubStart?: () => void;
};

export default function RoughcutTimeline({
  clips,
  recipe,
  playheadSec,
  onPlayheadSecChange,
  onScrubStart,
}: RoughcutTimelineProps) {
  const trackRef = useRef<HTMLDivElement | null>(null);
  const scrubbingRef = useRef(false);
  const [scrubTick, setScrubTick] = useState(false);
  const segments: TimelineSegment[] = buildTimelineSegments(clips);
  const total = segments.length ? segments[segments.length - 1].endGlobal : 0;
  const playPct = total > 0 ? (playheadSec / total) * 100 : 0;

  const scrubToClientX = useCallback(
    (clientX: number) => {
      const el = trackRef.current;
      if (!el || total <= 0) return;
      const r = el.getBoundingClientRect();
      const ratio = Math.max(0, Math.min(1, (clientX - r.left) / Math.max(r.width, 1)));
      onPlayheadSecChange(ratio * total);
    },
    [onPlayheadSecChange, total],
  );

  const onPointerDown = (e: React.PointerEvent) => {
    e.preventDefault();
    onScrubStart?.();
    scrubbingRef.current = true;
    setScrubTick(true);
    trackRef.current?.setPointerCapture(e.pointerId);
    scrubToClientX(e.clientX);
  };

  const onPointerMove = (e: React.PointerEvent) => {
    if (!scrubbingRef.current) return;
    scrubToClientX(e.clientX);
  };

  const onPointerUp = (e: React.PointerEvent) => {
    if (!scrubbingRef.current) return;
    scrubbingRef.current = false;
    setScrubTick(false);
    try {
      trackRef.current?.releasePointerCapture(e.pointerId);
    } catch {
      /* ignore */
    }
  };

  if (clips.length === 0) return null;

  return (
    <div className="roughcut-timeline">
      <p className="roughcut-timeline__label">Story timeline</p>
      <div
        ref={trackRef}
        className="roughcut-timeline__track"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
        role="slider"
        tabIndex={0}
        aria-valuemin={0}
        aria-valuemax={Math.floor(total)}
        aria-valuenow={Math.floor(playheadSec)}
        aria-label="Rough cut timeline scrub"
      >
        <div className="roughcut-timeline__segments">
          {segments.map((s, idx) => {
            const tr = idx < segments.length - 1 ? transitionAfterUiIndex(recipe?.transitions, idx) : null;
            return (
              <div
                key={s.uiIndex}
                className="roughcut-timeline__cell-wrap"
                style={{ flex: `${s.durationSec} 1 0` }}
              >
                <div className="roughcut-timeline__cell">
                  <span className="roughcut-timeline__cell-title" title={s.sourceFile}>
                    {s.sourceFile.replace(/\.[^.]+$/, "")}
                  </span>
                  {tr ? (
                    <span className="roughcut-timeline__junction">
                      <GapTransitionGlyph tr={tr} />
                    </span>
                  ) : null}
                </div>
              </div>
            );
          })}
        </div>
        <div className="roughcut-timeline__playhead" style={{ left: `${playPct}%` }} />
      </div>

      <div className="roughcut-timeline__glyph-strip">
        {segments.map((s) => (
          <div
            key={`g-${s.uiIndex}`}
            className="roughcut-timeline__glyph-cell"
            style={{ flex: `${s.durationSec} 1 0` }}
          >
            <ClipRecipeGlyphs clipIndex={s.uiIndex} recipe={recipe} />
          </div>
        ))}
      </div>

      <p className="roughcut-timeline__hint">
        {scrubTick ? "Scrubbing…" : `Drag the timeline to seek · ${formatClock(playheadSec)} / ${formatClock(total)}`}
      </p>
    </div>
  );
}
