#!/bin/sh
# Ubuntu: install multipass via snap if absent, then run CI in VM.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_vm.sh
. "$SCRIPT_DIR/_vm.sh"

if ! command -v multipass >/dev/null 2>&1; then
    log "multipass not found — installing via snap..."
    if ! command -v snap >/dev/null 2>&1; then
        log "snap not found — installing snapd..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq snapd
        sudo systemctl enable --now snapd.socket
    fi
    sudo snap install multipass
fi

ci_run
