#!/bin/sh
# macOS: install multipass via Homebrew Cask if absent, then run CI in VM.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_vm.sh
. "$SCRIPT_DIR/_vm.sh"

if ! command -v multipass >/dev/null 2>&1; then
    log "multipass not found — installing via Homebrew..."
    if ! command -v brew >/dev/null 2>&1; then
        die "Homebrew is required but not installed. Install it from https://brew.sh/ and re-run."
    fi
    brew install --cask multipass
fi

ci_run
