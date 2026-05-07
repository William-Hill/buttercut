# code-callout

Monospace command + caption, designed to overlay on a terminal/IDE shot.

## Variables

| Name     | Type    | Required | Description                                  |
|----------|---------|----------|----------------------------------------------|
| command  | string  | yes      | Code or shell command to display (one line). |
| caption  | string  | no       | Short caption shown below the command.       |
| theme    | object  | no       | Resolved theme tokens (font_display, font_mono, color_bg, color_accent). Defaults to the tutorial-dark palette when absent. |

**Duration:** fixed at 5s for now. Hyperframes resolves `data-duration` at compile time, so a runtime variable cannot change the encoded length. Variable durations require a pre-render templating step — tracked as a follow-up.

**Theme:** tokens applied at runtime via CSS custom properties (`--bg`, `--accent`, `--font-display`, `--font-mono`). Built-in defaults match the `tutorial-dark` preset so renders without a theme block still look right.

Aspect: 1920x1080. 9:16 variant in a later PR.
