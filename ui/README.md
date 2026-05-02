# ButterCut Desktop (M0)

A Tauri-based desktop shell over the existing ButterCut Ruby gem. M0 is read-only: it lists libraries from `libraries/*/library.yaml` and lets you open an empty Library window.

## Architecture

```
┌─────────────────────────┐    invoke()     ┌─────────────────────┐    JSON-RPC over stdio    ┌────────────────────────┐
│  React + Vite frontend  │ ───────────────▶│  Rust (Tauri core)  │ ─────────────────────────▶│  Ruby sidecar process  │
│  (src/)                 │◀─────────────── │  (src-tauri/)       │ ◀───────────────────────── │  (sidecar/*.rb)        │
└─────────────────────────┘                 └─────────────────────┘                            └────────────────────────┘
```

- The Rust process spawns one long-lived Ruby sidecar at startup and kills it when the app exits (`kill_on_drop`).
- IPC is line-delimited JSON-RPC 2.0 over the sidecar's stdin/stdout. Per-call response routing lives in `src-tauri/src/sidecar.rs`.
- The Ruby sidecar (`sidecar/buttercut_ui_sidecar.rb`) is a single class wrapping read access to the libraries directory.

For M0 the sidecar exposes:

- `ping` → `"pong"`
- `list_libraries` → `[{name, video_count, last_touched_at}]`

## Requirements

- Node 22+ and pnpm 10+
- Rust stable (`rustup`)
- System Ruby ≥ 3.0 on `PATH` (the gem itself isn't required for M0; the sidecar is pure stdlib)

Bundling a Ruby runtime into a release binary is deliberately deferred — M0 development assumes system Ruby. Release packaging will be addressed in a later milestone.

## Develop

```sh
cd ui
pnpm install
pnpm tauri dev
```

The Projects window opens against `../libraries` from the repo root. Click a card to open an empty Library window placeholder (filled in M1).

### Pointing at a different libraries directory

```sh
BUTTERCUT_LIBRARIES_ROOT=/path/to/libs pnpm tauri dev
```

### Pointing at a specific Ruby

```sh
BUTTERCUT_RUBY=/path/to/ruby pnpm tauri dev
```

## Build

```sh
pnpm tauri build
```

Outputs a `.app` bundle under `src-tauri/target/release/bundle/macos/`.

## Test

- **Frontend / typecheck:** `pnpm build` (runs `tsc` then Vite build)
- **Rust:** `cd src-tauri && cargo check`
- **Sidecar smoke test:**

  ```sh
  echo '{"jsonrpc":"2.0","id":1,"method":"list_libraries"}' \
    | ruby sidecar/buttercut_ui_sidecar.rb ../libraries
  ```

  Expect a single JSON line back with the libraries array.

## Layout

```
ui/
├── src/                         React + TS frontend
│   ├── routes/projects.tsx      Projects screen (library cards)
│   ├── routes/library.tsx       Library window placeholder
│   ├── ipc/sidecar.ts           Typed wrappers over Tauri commands
│   ├── styles/theme.css         Color / type tokens
│   └── main.tsx                 Hash-based route picker
├── src-tauri/
│   ├── src/lib.rs               Tauri commands + window management
│   ├── src/sidecar.rs           Ruby sidecar process owner + JSON-RPC
│   └── tauri.conf.json
└── sidecar/
    └── buttercut_ui_sidecar.rb  JSON-RPC server over stdio
```

## Visual direction

- Stage `#14141a`, surface `#1c1c24`, hairline `#2a2a35`
- Tungsten amber accent `#e0a55a` (warm `#d97a3a`)
- Display: EB Garamond Italic (project titles, eyebrows)
- Mono: JetBrains Mono (counts, timestamps, technical labels)

Fonts are self-hosted via `@fontsource` packages — no CDN, no runtime network requirement.
