# Hyperframes compositions

Each subdirectory is a self-contained Hyperframes composition: HTML + GSAP + a `hyperframes.json` config. The b-roll director auto-discovers templates by walking this directory and reading each composition's `README.md` (see `lib/buttercut/broll_director_inputs.rb#load_templates`), so any new template added here becomes available to the director without further wiring.

## Catalog

| Template       | Purpose                                              | Key `content` fields                          |
|----------------|------------------------------------------------------|-----------------------------------------------|
| code-callout   | Monospace command + caption over a terminal/IDE shot | `command`, `caption`                          |
| term-card      | Vocabulary term + definition                         | `term`, `definition`                          |
| step-counter   | "Step N of M" structural marker                      | `step`, `total`, `title`                      |
| quote          | Pull quote with optional attribution                 | `quote`, `attribution`                        |
| stat           | Big number + label + optional caption                | `value`, `label`, `caption`                   |
| comparison     | Two-column compare/contrast                          | `left_label`, `left_text`, `right_label`, `right_text` |

See each composition's own `README.md` for full variable shape, required vs. optional, and length guidance.

## Common conventions

All templates in this directory follow the same conventions so the render pipeline can treat them uniformly.

**Theme tokens.** Each composition takes a `theme` object alongside its content variables. Recognized keys:

- `color_bg`, `color_fg`, `color_accent` — applied to `--bg`, `--fg`, `--accent` CSS custom properties.
- `font_display`, `font_mono` — applied to `--font-display`, `--font-mono`.
- `motion` — one of `snappy` (default), `smooth`, or `minimal`. Controls in/out durations and the amount of translation/scale on entrance.

Unset tokens fall back to the built-in `tutorial-dark` defaults so renders without a theme block still look right. See `themes/*.yaml` at the repo root for preset values.

**Duration.** Fixed at 5s per composition. Hyperframes resolves `data-duration` at compile time, so a runtime `duration` variable cannot change the encoded length. Variable durations need a pre-render templating step — tracked as a follow-up.

**Aspect.** 1920x1080 only at the moment. 9:16 variants are a follow-up.

**Animation library.** GSAP, loaded from CDN. Each composition exposes its timeline at `window.__timelines["<id>"]` for the Hyperframes runtime.
