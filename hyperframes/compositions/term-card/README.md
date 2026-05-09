# term-card

Term + short definition. Use as a cutaway when a new vocabulary word appears, or as an overlay during a definitional beat.

## Variables

| Name       | Type   | Required | Description                                                                                  |
|------------|--------|----------|----------------------------------------------------------------------------------------------|
| term       | string | yes      | The word or phrase being defined. Keep to ~1–3 words.                                        |
| definition | string | yes      | One-sentence definition. Keep under ~12 words for legibility.                                |
| theme      | object | no       | Resolved theme tokens (font_display, font_mono, color_bg, color_fg, color_accent, motion).   |

**Duration:** fixed at 5s. See note in `code-callout/README.md`.

**Motion:** respects `theme.motion` (`snappy` default, `smooth`, `minimal`).

Aspect: 1920x1080. 9:16 variant TBD.
