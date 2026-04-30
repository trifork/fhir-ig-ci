#!/bin/sh
# Run the fhir-ig-ci build and test suite inside a multipass VM.
# Detects the current OS/distro and delegates to the appropriate
# scripts/ci/<distro>.sh, which installs multipass if needed.
#
# Usage:
#   scripts/ci-multipass.sh
#
# Configuration (environment variables):
#   VM_NAME    Multipass VM name        (default: ig-ci)
#   VM_CPUS    vCPUs to allocate        (default: 4)
#   VM_MEMORY  RAM to allocate          (default: 8G)
#   VM_DISK    Disk size to allocate    (default: 20G)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CI_DIR="$SCRIPT_DIR/ci"

OS="$(uname -s)"

if [ "$OS" = "Darwin" ]; then
    exec "$CI_DIR/mac.sh" "$@"
fi

if [ "$OS" = "Linux" ]; then
    if [ -f /etc/os-release ]; then
        DISTRO="$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
    else
        DISTRO="unknown"
    fi

    case "$DISTRO" in
        ubuntu)    exec "$CI_DIR/ubuntu.sh"  "$@" ;;
        debian)    exec "$CI_DIR/debian.sh"  "$@" ;;
        linuxmint) exec "$CI_DIR/mint.sh"    "$@" ;;
        fedora)    exec "$CI_DIR/fedora.sh"  "$@" ;;
        cachyos|arch) exec "$CI_DIR/cachyos.sh" "$@" ;;
        *)
            printf 'ci-multipass: unsupported Linux distro "%s"\n' "$DISTRO" >&2
            printf 'Supported: ubuntu, debian, linuxmint, fedora, cachyos, arch\n' >&2
            exit 1
            ;;
    esac
fi

printf 'ci-multipass: unsupported OS "%s"\n' "$OS" >&2
exit 1
