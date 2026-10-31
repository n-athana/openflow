#!/usr/bin/env bash
# From a fresh clone to a running OpenFlow: Python environment, both models, signing identity, app.
# Safe to run again (each step skips what's already done). Usage: scripts/install.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

step() { printf '\n\033[1;38;2;255;92;56m▍\033[0m \033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$1"; exit 1; }

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail "OpenFlow needs a Mac with Apple Silicon."
command -v swift >/dev/null || fail "Swift is missing. Install the Command Line Tools: xcode-select --install"
command -v uv >/dev/null || fail "uv is missing. Install it with: brew install uv  (or see https://docs.astral.sh/uv/)"

step "1/4  Python environment"
(cd asr && uv sync)

step "2/4  Speech model and cleanup model (about 5.5 GB, downloaded once)"
(cd asr && uv run bench.py ../samples/*.wav >/dev/null && echo "Speech model ready")
(cd asr && uv run polish.py >/dev/null && echo "Cleanup model ready")

step "3/4  Code signature (keeps macOS permissions across updates)"
scripts/make-cert.sh

step "4/4  Building OpenFlow.app"
scripts/build-app.sh

step "Done. Opening OpenFlow; the setup guide takes it from here."
open build/OpenFlow.app
