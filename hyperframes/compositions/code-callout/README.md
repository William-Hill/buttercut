# code-callout

Monospace command + caption, designed to overlay on a terminal/IDE shot.

## Variables

| Name     | Type    | Required | Description                                  |
|----------|---------|----------|----------------------------------------------|
| command  | string  | yes      | Code or shell command to display (one line). |
| caption  | string  | no       | Short caption shown below the command.       |

**Duration:** fixed at 5s for now. Hyperframes resolves `data-duration` at compile time, so a runtime variable cannot change the encoded length. Variable durations require a pre-render templating step — tracked as a follow-up.

Theme: hardcoded `tutorial-dark` palette (Inter / JetBrains Mono, #0d0d0d bg, #ff6b35 accent). Will be parameterized by the theme block in a later PR.

Aspect: 1920x1080. 9:16 variant in a later PR.
