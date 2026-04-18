#!/usr/bin/env bash
# Build the fhir-ig-ci container image. Portable across CI and local hosts.
#
# Usage:
#   scripts/build.sh                       # single-arch load into local docker for testing
#   scripts/build.sh --multi-arch          # build for linux/amd64,linux/arm64
#   scripts/build.sh --multi-arch --push   # build multi-arch and push to $REGISTRY
#
# Env:
#   REGISTRY     e.g. ghcr.io/acme  (empty => local only)
#   IMAGE_NAME   default: fhir-ig-ci
#   IMAGE_TAG    default: dev
#   PLATFORMS    default: linux/amd64,linux/arm64
#   CACHE_FROM   buildx --cache-from ref (optional)
#   CACHE_TO     buildx --cache-to ref (optional)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MULTI_ARCH=0
PUSH=0
LOAD=1
EXTRA_TAGS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --multi-arch) MULTI_ARCH=1; LOAD=0; shift ;;
        --push)       PUSH=1; LOAD=0; shift ;;
        --load)       LOAD=1; PUSH=0; shift ;;
        --tag)        EXTRA_TAGS+=("$2"); shift 2 ;;
        -h|--help)    sed -n '3,18p' "$0"; exit 0 ;;
        *)            fail "Unknown argument: $1" ;;
    esac
done

ensure_buildx

host_arch="linux/$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
platforms="$host_arch"
if [ "$MULTI_ARCH" = "1" ]; then
    platforms="$PLATFORMS"
fi

primary_tag="${FULL_IMAGE}:${IMAGE_TAG}"
all_tags=("$primary_tag")
for t in "${EXTRA_TAGS[@]:-}"; do
    [ -n "$t" ] && all_tags+=("$t")
done

mode="cache"
if [ "$PUSH" = "1" ]; then
    [ -n "$REGISTRY" ] || fail "--push requires REGISTRY to be set"
    mode="push"
elif [ "$LOAD" = "1" ]; then
    if [ "$MULTI_ARCH" = "1" ]; then
        fail "--multi-arch cannot --load into local engine; use --push or drop --multi-arch"
    fi
    mode="load"
fi

log "Building image"
log "  engine:    $ENGINE"
log "  tags:      ${all_tags[*]}"
log "  platforms: $platforms"
log "  mode:      $mode"

case "$ENGINE" in
    docker)
        tag_args=()
        for t in "${all_tags[@]}"; do tag_args+=(--tag "$t"); done
        out_args=()
        case "$mode" in
            push)  out_args+=(--push) ;;
            load)  out_args+=(--load) ;;
            cache) out_args+=(--output=type=cacheonly) ;;
        esac
        cache_args=()
        [ -n "${CACHE_FROM:-}" ] && cache_args+=("--cache-from=$CACHE_FROM")
        [ -n "${CACHE_TO:-}" ]   && cache_args+=("--cache-to=$CACHE_TO")

        docker buildx build \
            --platform "$platforms" \
            --file "$REPO_ROOT/Dockerfile" \
            "${tag_args[@]}" \
            "${cache_args[@]}" \
            "${out_args[@]}" \
            "$REPO_ROOT"
        ;;
    podman)
        case "$mode" in
            load)
                tag_args=()
                for t in "${all_tags[@]}"; do tag_args+=(--tag "$t"); done
                podman build \
                    --platform "$platforms" \
                    --file "$REPO_ROOT/Dockerfile" \
                    "${tag_args[@]}" \
                    "$REPO_ROOT"
                ;;
            push|cache)
                manifest="${primary_tag}-manifest"
                podman manifest rm "$manifest" >/dev/null 2>&1 || true
                podman manifest create "$manifest"
                IFS=',' read -ra plats <<<"$platforms"
                for p in "${plats[@]}"; do
                    log "  building $p into manifest"
                    podman build \
                        --platform "$p" \
                        --file "$REPO_ROOT/Dockerfile" \
                        --manifest "$manifest" \
                        "$REPO_ROOT"
                done
                for t in "${all_tags[@]}"; do
                    podman tag "$manifest" "$t"
                done
                if [ "$mode" = "push" ]; then
                    for t in "${all_tags[@]}"; do
                        podman manifest push --all "$t" "docker://$t"
                    done
                fi
                ;;
        esac
        ;;
esac

log "Build complete: $primary_tag"
