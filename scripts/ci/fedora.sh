#!/bin/sh
# Fedora: install multipass via snap (after installing snapd) if absent,
# then run CI in VM.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_vm.sh
. "$SCRIPT_DIR/_vm.sh"

if ! command -v multipass >/dev/null 2>&1; then
    log "multipass not found — installing via snap..."
    if ! command -v snap >/dev/null 2>&1; then
        log "snap not found — installing snapd via dnf..."
        sudo dnf install -y snapd
        sudo systemctl enable --now snapd.socket
        # Create the classic snap symlink required on Fedora.
        sudo ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true
        # snapd needs a moment after first install before snaps can be installed.
        sleep 10
    fi
    sudo snap install multipass
fi

ci_run
