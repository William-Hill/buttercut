# step-counter

"Step N of M" + a short title. Use to mark structural moments in a tutorial.

## Variables

| Name     | Type   | Required | Description                                                                                |
|----------|--------|----------|--------------------------------------------------------------------------------------------|
| step     | number | yes      | Current step number (1-based).                                                             |
| total    | number | yes      | Total number of steps.                                                                     |
| title    | string | yes      | Short title for the step. Keep under ~6 words.                                             |
| theme    | object | no       | Resolved theme tokens (font_display, font_mono, color_bg, color_fg, color_accent, motion). |

**Duration:** fixed at 5s.

**Motion:** respects `theme.motion`. Slides in from the left rather than up — feels more "advancing through steps."

Aspect: 1920x1080. 9:16 variant TBD.
