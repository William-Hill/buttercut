# quote

Pull quote for emphasis. Use sparingly — works best when the speaker says something quotable that lands and you want the audience to sit with it.

## Variables

| Name        | Type   | Required | Description                                                                                |
|-------------|--------|----------|--------------------------------------------------------------------------------------------|
| quote       | string | yes      | The quote text. Keep under ~16 words for legibility.                                       |
| attribution | string | no       | Person, role, or source. Omit for unattributed pull quotes.                                |
| theme       | object | no       | Resolved theme tokens (font_display, font_mono, color_bg, color_fg, color_accent, motion). |

**Duration:** fixed at 5s.

**Motion:** respects `theme.motion`. The fade is gentler than other templates so the quote feels considered, not popped.

Aspect: 1920x1080. 9:16 variant TBD.
