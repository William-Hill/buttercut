#!/usr/bin/env bash
# ButterCut desktop (Tauri + Ruby sidecar) prerequisite check.
# Usage: from repo root — ./scripts/check_desktop_prereqs.sh
# Exit 0 = all required tools OK; 1 = something required is missing.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUBY_VERSION_FILE="$ROOT/.ruby-version"
REQUIRED_FAIL=0

warn() { printf '%s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

ok() { printf '  OK     %s\n' "$1"; }
bad() { printf '  MISS   %s\n' "$1"; REQUIRED_FAIL=1; }
info() { printf '  INFO   %s\n' "$1"; }

printf '\nButterCut desktop dev — prerequisite check\n'
printf '%s\n\n' '────────────────────────────────────────────'

# --- Ruby (3.3.x per .ruby-version) ---
if [[ ! -f "$RUBY_VERSION_FILE" ]]; then
  bad "Missing .ruby-version at repo root"
else
  WANT_RUBY="$(tr -d ' \t\r\n' <"$RUBY_VERSION_FILE")"
  WANT_MM="${WANT_RUBY%.*}"
  if ! have ruby; then
    bad "ruby (need ${WANT_MM}.x per .ruby-version — brew/ruby-install/rbenv/mise)"
  else
    GOT_FULL="$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)"
    GOT_MM="$(ruby -e 'print RUBY_VERSION.split(%q(.))[0,2].join(%q(.))' 2>/dev/null || true)"
    if [[ -z "$GOT_MM" ]]; then
      bad "ruby present but version unreadable ($(ruby --version 2>/dev/null | head -1))"
    elif [[ "$GOT_MM" != "$WANT_MM" ]]; then
      bad "Ruby ${GOT_FULL} on PATH (need ${WANT_MM}.x per .ruby-version ${WANT_RUBY})"
    else
      ok "Ruby ${GOT_FULL} (matches ${WANT_MM}.x)"
    fi
  fi
fi

if ! have bundle; then
  bad "bundler (gem install bundler)"
else
  ok "bundler $(bundle -v 2>/dev/null | head -1)"
fi

# --- Sidecar gems ---
if [[ -d "$ROOT/ui/sidecar" ]]; then
  if (cd "$ROOT/ui/sidecar" && bundle check >/dev/null 2>&1); then
    ok "ui/sidecar bundle (satisfied)"
  else
    bad "ui/sidecar gems — run: cd ui/sidecar && bundle install"
  fi
else
  bad "ui/sidecar directory missing"
fi

# --- Node / pnpm ---
if ! have node; then
  bad "node (install LTS — brew install node)"
else
  ok "node $(node -v 2>/dev/null)"
fi

if ! have pnpm; then
  bad "pnpm (corepack enable && corepack prepare pnpm@latest --activate — or brew install pnpm)"
else
  ok "pnpm $(pnpm -v 2>/dev/null)"
fi

if [[ -f "$ROOT/ui/package.json" ]]; then
  if [[ -d "$ROOT/ui/node_modules" ]]; then
    ok "ui/node_modules present"
  else
    bad "ui deps — run: cd ui && pnpm install"
  fi
else
  bad "ui/package.json missing"
fi

# --- Rust (Tauri) ---
if ! have cargo || ! have rustc; then
  bad "Rust toolchain (https://rustup.rs/)"
else
  ok "cargo $(cargo -V 2>/dev/null | head -1)"
fi

# --- FFmpeg (inspect + analyze frames) ---
if ! have ffmpeg; then
  bad "ffmpeg (brew install ffmpeg)"
else
  ok "ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | cut -c1-60)"
fi

if ! have ffprobe; then
  bad "ffprobe (usually with ffmpeg)"
else
  ok "ffprobe $(ffprobe -version 2>/dev/null | head -1 | cut -c1-60)"
fi

# --- WhisperX (transcribe stage — optional for UI shell, required for real analysis) ---
WHISPERX_OK=0
if have whisperx; then
  ok "whisperx on PATH"
  WHISPERX_OK=1
elif [[ -x "$HOME/.buttercut/whisperx" ]]; then
  ok "whisperx at ~/.buttercut/whisperx"
  WHISPERX_OK=1
elif [[ -x "$HOME/.buttercut/venv/bin/whisperx" ]]; then
  ok "whisperx at ~/.buttercut/venv/bin/whisperx"
  WHISPERX_OK=1
else
  info "WhisperX not found — Projects/New Project UI works; transcribe will fail until installed (see .claude/skills/setup/)"
fi

# --- API key (optional at check time) ---
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  ok "ANTHROPIC_API_KEY is set"
else
  info "ANTHROPIC_API_KEY unset — set in shell or use in-app key modal for analyze/summarize"
fi

# --- libraries root ---
if [[ -d "$ROOT/libraries" ]]; then
  ok "libraries/ directory exists"
else
  info "libraries/ missing — creating empty libraries/"
  mkdir -p "$ROOT/libraries"
  ok "libraries/ created"
fi

printf '\n%s\n' '────────────────────────────────────────────'
if [[ "$REQUIRED_FAIL" -ne 0 ]]; then
  warn "Some required items are missing. Fix the MISS lines above, then:"
  warn "  make setup    # install Ruby gems + pnpm deps"
  warn "  make check    # re-run this script"
  exit 1
fi

printf 'All required desktop prerequisites look good.\n'
if [[ "$WHISPERX_OK" -eq 0 ]]; then
  printf '%s\n' '(Install WhisperX when you need real transcription.)'
fi
printf '\nRun: cd ui && pnpm tauri dev\n\n'
exit 0
