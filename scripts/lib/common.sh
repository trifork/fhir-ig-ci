# Shared helpers for build/test scripts. Source, don't execute.
# shellcheck shell=bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

IMAGE_NAME_DEFAULT="fhir-ig-ci"
REGISTRY_DEFAULT=""
PLATFORMS_DEFAULT="linux/amd64,linux/arm64"

: "${IMAGE_NAME:=$IMAGE_NAME_DEFAULT}"
: "${REGISTRY:=$REGISTRY_DEFAULT}"
: "${IMAGE_TAG:=dev}"
: "${PLATFORMS:=$PLATFORMS_DEFAULT}"

if [ -n "$REGISTRY" ]; then
    FULL_IMAGE="${REGISTRY%/}/${IMAGE_NAME}"
else
    FULL_IMAGE="${IMAGE_NAME}"
fi
export IMAGE_NAME REGISTRY IMAGE_TAG PLATFORMS FULL_IMAGE

log()  { printf '\033[1;36m[ig-ci]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[ig-ci]\033[0m %s\n' "$*" >&2; exit 1; }

require() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

# Engine autodetect: honour $ENGINE if set, else prefer docker, fall back to podman.
# We keep the "docker-ish" CLI surface (build, run, image inspect, rm) which both speak.
if [ -z "${ENGINE:-}" ]; then
    if command -v docker >/dev/null 2>&1; then
        ENGINE=docker
    elif command -v podman >/dev/null 2>&1; then
        ENGINE=podman
    else
        fail "Neither docker nor podman found in PATH; set ENGINE=<cmd> to override"
    fi
fi
export ENGINE

engine() { "$ENGINE" "$@"; }

ensure_buildx() {
    case "$ENGINE" in
        docker)
            docker buildx version >/dev/null 2>&1 || fail "docker buildx is not available"
            if ! docker buildx inspect fhir-ig-ci-builder >/dev/null 2>&1; then
                log "Creating buildx builder 'fhir-ig-ci-builder'"
                docker buildx create --name fhir-ig-ci-builder --driver docker-container --use >/dev/null
                docker buildx inspect --bootstrap >/dev/null
            else
                docker buildx use fhir-ig-ci-builder >/dev/null
            fi
            ;;
        podman)
            # podman build natively supports --platform. For multi-arch push we use
            # `podman manifest`. No builder instance to create.
            :
            ;;
        *)
            fail "Unsupported ENGINE: $ENGINE"
            ;;
    esac
}
