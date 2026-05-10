# comparison

Two-column compare/contrast. The right column is highlighted in the accent color — use it for the "after," "good," or "preferred" side.

## Variables

| Name        | Type   | Required | Description                                                                                |
|-------------|--------|----------|--------------------------------------------------------------------------------------------|
| left_label  | string | yes      | Short header for the left column (e.g. `Before`, `Old way`).                               |
| left_text   | string | yes      | One-sentence description of the left side. Keep under ~10 words.                           |
| right_label | string | yes      | Short header for the right column (e.g. `After`, `New way`).                               |
| right_text  | string | yes      | One-sentence description of the right side. Keep under ~10 words.                          |
| theme       | object | no       | Resolved theme tokens (font_display, font_mono, color_bg, color_fg, color_accent, motion). |

**Duration:** fixed at 5s.

**Motion:** respects `theme.motion`. The two columns slide in from opposite sides with a small stagger; the `vs` divider pops in with a back-out overshoot.

Aspect: 1920x1080. 9:16 variant TBD.
