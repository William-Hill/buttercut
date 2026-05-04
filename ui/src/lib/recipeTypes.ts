/** Subset of `lib/buttercut/recipe.rb` JSON schema for desktop glyphs. */

export type RecipeSpeedRamp = { at: number; speed: number; ease: string };

export type RecipeMarker = { at: number; name: string; color: string };

export type RecipeClip = {
  index: number;
  source_file: string;
  speed_ramps?: RecipeSpeedRamp[];
  color_tag?: string;
  markers?: RecipeMarker[];
};

export type RecipeTransition = {
  between: [number, number];
  type: string;
  color?: string;
  duration_frames: number;
};

export type RecipeTitleCard = {
  at_clip: number;
  text: string;
  fade_in_at: number;
  fade_in_frames: number;
};

export type RecipePowergrade = {
  name: string;
  apply_to: "all" | number[];
};

export type RecipeJson = {
  version: number;
  library: string;
  timeline: string;
  clips: RecipeClip[];
  transitions?: RecipeTransition[];
  title_card?: RecipeTitleCard;
  powergrade?: RecipePowergrade;
};

export function parseRoughcutRecipeJson(text: string): RecipeJson | null {
  try {
    const o = JSON.parse(text) as RecipeJson;
    if (!o || o.version !== 1 || !Array.isArray(o.clips) || o.clips.length === 0) return null;
    return o;
  } catch {
    return null;
  }
}

/** Recipe clip index is 1..N in YAML order; UI `clips` array is the same order. */
export function recipeClipForUiIndex(recipe: RecipeJson | null, uiIndex: number): RecipeClip | null {
  if (!recipe) return null;
  return recipe.clips.find((c) => c.index === uiIndex + 1) ?? null;
}

export function transitionAfterUiIndex(trs: RecipeTransition[] | undefined, uiIndex: number): RecipeTransition | null {
  if (!trs?.length) return null;
  const a = uiIndex + 1;
  const b = uiIndex + 2;
  return trs.find((t) => t.between?.[0] === a && t.between?.[1] === b) ?? null;
}

export function powergradeTouchesClip(pg: RecipePowergrade | undefined, recipeIndex1Based: number): boolean {
  if (!pg) return false;
  if (pg.apply_to === "all") return true;
  return Array.isArray(pg.apply_to) && pg.apply_to.includes(recipeIndex1Based);
}
