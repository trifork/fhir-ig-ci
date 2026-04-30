#!/bin/sh
# CachyOS / Arch Linux: install multipass from the AUR via paru or yay,
# then run CI in VM.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_vm.sh
. "$SCRIPT_DIR/_vm.sh"

if ! command -v multipass >/dev/null 2>&1; then
    log "multipass not found — installing from AUR..."
    if command -v paru >/dev/null 2>&1; then
        paru -S --noconfirm multipass
    elif command -v yay >/dev/null 2>&1; then
        yay -S --noconfirm multipass
    else
        die "No AUR helper found (tried: paru, yay). Install one and re-run, or install multipass manually."
    fi
fi

ci_run
