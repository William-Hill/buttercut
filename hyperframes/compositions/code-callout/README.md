# code-callout

Monospace command + caption, designed to overlay on a terminal/IDE shot.

## Variables

| Name     | Type    | Required | Description                                  |
|----------|---------|----------|----------------------------------------------|
| command  | string  | yes      | Code or shell command to display (one line). |
| caption  | string  | no       | Short caption shown below the command.       |
| duration | number  | yes      | Total clip duration in seconds.              |

Theme: hardcoded `tutorial-dark` palette (Inter / JetBrains Mono, #0d0d0d bg, #ff6b35 accent). Will be parameterized by the theme block once issue #27 lands.

Aspect: 1920x1080. 9:16 variant follows in a later PR (rest of #29).
