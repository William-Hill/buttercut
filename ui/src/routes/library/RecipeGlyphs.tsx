import type { ReactNode } from "react";
import type { RecipeClip, RecipeJson, RecipeTransition } from "../../lib/recipeTypes";
import { powergradeTouchesClip, recipeClipForUiIndex } from "../../lib/recipeTypes";

function IconWrap({ title, children }: { title: string; children: ReactNode }) {
  return (
    <span className="roughcut-glyph" title={title}>
      <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
        {children}
      </svg>
    </span>
  );
}

function GlyphSpeedRamp() {
  return (
    <IconWrap title="Speed ramp">
      <path
        d="M2 10 L4 4 L6 9 L8 3 L10 8 L12 5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </IconWrap>
  );
}

function GlyphColor() {
  return (
    <IconWrap title="Clip color tag">
      <circle cx="7" cy="7" r="4" fill="currentColor" opacity="0.85" />
    </IconWrap>
  );
}

function GlyphMarker() {
  return (
    <IconWrap title="Marker">
      <path d="M7 2 L11 7 L7 12 L3 7 Z" fill="none" stroke="currentColor" strokeWidth="1.2" />
    </IconWrap>
  );
}

function GlyphTransition({ type }: { type: string }) {
  const label = type === "dip_to_color" ? "Dip transition" : "Cross dissolve";
  return (
    <IconWrap title={label}>
      <path d="M3 4 L7 7 L3 10" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
      <path d="M11 4 L7 7 L11 10" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
    </IconWrap>
  );
}

function GlyphTitleCard() {
  return (
    <IconWrap title="Title card">
      <rect x="3" y="4" width="8" height="7" rx="1" fill="none" stroke="currentColor" strokeWidth="1.2" />
      <path d="M5.5 6.5 H8.5 M7 5.5 V9.5" stroke="currentColor" strokeWidth="1" />
    </IconWrap>
  );
}

function GlyphPowerGrade() {
  return (
    <IconWrap title="PowerGrade">
      <circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" strokeWidth="1.1" strokeDasharray="2 1.5" />
      <circle cx="7" cy="7" r="1.6" fill="currentColor" />
    </IconWrap>
  );
}

export function GapTransitionGlyph({ tr }: { tr: RecipeTransition }) {
  return (
    <span className="roughcut-timeline__gap-glyph" title={`${tr.type}${tr.color ? ` (${tr.color})` : ""}`}>
      <GlyphTransition type={tr.type} />
    </span>
  );
}

export function ClipRecipeGlyphs({ clipIndex, recipe }: { clipIndex: number; recipe: RecipeJson | null }) {
  const c: RecipeClip | null = recipeClipForUiIndex(recipe, clipIndex);
  const rc = clipIndex + 1;
  const title = recipe?.title_card?.at_clip === rc;
  const pg = powergradeTouchesClip(recipe?.powergrade, rc);

  const nodes: ReactNode[] = [];
  if (c?.speed_ramps?.length) nodes.push(<GlyphSpeedRamp key="ramp" />);
  if (c?.color_tag) nodes.push(<GlyphColor key="color" />);
  if (c?.markers?.length) nodes.push(<GlyphMarker key="marker" />);
  if (title) nodes.push(<GlyphTitleCard key="title" />);
  if (pg) nodes.push(<GlyphPowerGrade key="pg" />);

  if (nodes.length === 0) return null;
  return <div className="roughcut-timeline__glyph-row">{nodes}</div>;
}
