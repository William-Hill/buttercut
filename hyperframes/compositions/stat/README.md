# stat

Large number + label, with optional caption. Use when a specific figure is the point of the moment.

## Variables

| Name    | Type   | Required | Description                                                                                |
|---------|--------|----------|--------------------------------------------------------------------------------------------|
| value   | string | yes      | The headline value as a string (so units like `%`, `x`, `ms`, `$` survive). Keep ≤ ~6 chars. |
| label   | string | yes      | Short description of what the value measures. Keep under ~5 words.                         |
| caption | string | no       | Optional smaller mono caption underneath (e.g. source, sample size).                       |
| theme   | object | no       | Resolved theme tokens (font_display, font_mono, color_bg, color_fg, color_accent, motion). |

**Duration:** fixed at 5s.

**Motion:** respects `theme.motion`. `snappy` uses a slight `back.out` overshoot on the value for emphasis; `smooth` and `minimal` scale in calmly.

Aspect: 1920x1080. 9:16 variant TBD.
