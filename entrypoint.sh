#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
OUTPUT="${OUTPUT:-/output}"
SERVER_PORT="${SERVER_PORT:-8080}"

log() { printf '[fhir-ig-ci] %s\n' "$*" >&2; }

# When started as root, remap the 'ig' user to match the host-mount owner
# (or $PUID/$PGID) and re-exec unprivileged. This avoids EACCES on bind
# mounts owned by an arbitrary host uid. Passing --user to docker/podman
# bypasses this block because $(id -u) is no longer 0.
if [ "$(id -u)" = "0" ]; then
    target_uid="${PUID:-}"
    target_gid="${PGID:-}"
    if [ -z "$target_uid" ] && [ -d "$WORKSPACE" ]; then
        target_uid="$(stat -c '%u' "$WORKSPACE" 2>/dev/null || echo 1000)"
        target_gid="$(stat -c '%g' "$WORKSPACE" 2>/dev/null || echo 1000)"
    fi
    target_uid="${target_uid:-1000}"
    target_gid="${target_gid:-1000}"

    if [ "$target_uid" != "0" ]; then
        current_uid="$(id -u ig 2>/dev/null || echo -1)"
        current_gid="$(id -g ig 2>/dev/null || echo -1)"
        if [ "$target_uid" != "$current_uid" ] || [ "$target_gid" != "$current_gid" ]; then
            log "Remapping ig -> uid=$target_uid gid=$target_gid to match mount owner"
            groupmod -o -g "$target_gid" ig 2>/dev/null || true
            usermod  -o -u "$target_uid" -g "$target_gid" ig 2>/dev/null || true
        fi
        mkdir -p /home/ig/.fhir /home/ig/.cache
        chown -R "$target_uid:$target_gid" /home/ig
        # Only touch /output if we actually own it; don't disturb an arbitrary host dir.
        if [ -d "$OUTPUT" ] && [ -w "$OUTPUT" ]; then
            chown "$target_uid:$target_gid" "$OUTPUT" 2>/dev/null || true
        fi
        exec su-exec "$target_uid:$target_gid" "$0" "$@"
    fi
fi

run_sushi() {
    if [ -f "$WORKSPACE/sushi-config.yaml" ] || [ -d "$WORKSPACE/input/fsh" ]; then
        log "Running sushi in $WORKSPACE"
        (cd "$WORKSPACE" && sushi .)
    else
        log "No sushi-config.yaml or input/fsh — skipping sushi"
    fi
}

sync_output() {
    if [ ! -d "$WORKSPACE/output" ]; then
        log "No $WORKSPACE/output to sync"
        return 0
    fi
    if [ "$(readlink -f "$WORKSPACE/output")" = "$(readlink -f "$OUTPUT")" ]; then
        log "$WORKSPACE/output and $OUTPUT are the same path — nothing to sync"
        return 0
    fi
    log "Syncing $WORKSPACE/output -> $OUTPUT"
    mkdir -p "$OUTPUT"
    cp -a "$WORKSPACE/output/." "$OUTPUT/"
}

run_publisher() {
    log "Running FHIR IG Publisher"
    # The publisher writes a SQLite DB via DBBuilder into ./output. Some host
    # bind-mount layers (Docker Desktop osxfs/virtiofs, podman-machine, NFS, 9p)
    # break SQLite locking and surface as SQLITE_IOERR_READ. Stage the run on
    # the container's local FS so SQLite I/O stays off the bind mount, then
    # mirror the result back.
    local stage
    stage="$(mktemp -d /tmp/ig-publisher.XXXXXX)"
    cp -a "$WORKSPACE/." "$stage/"
    rm -rf "$stage/output"
    local rc=0
    (cd "$stage" && java -Xmx4g -jar "$IG_PUBLISHER_JAR" -ig . "$@") || rc=$?
    if [ -d "$stage/output" ]; then
        rm -rf "$WORKSPACE/output"
        mkdir -p "$WORKSPACE/output"
        cp -a "$stage/output/." "$WORKSPACE/output/"
    fi
    rm -rf "$stage"
    [ "$rc" = "0" ] || return "$rc"
    sync_output
}

serve_output() {
    local dir="$OUTPUT"
    if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null || true)" ]; then
        if [ -d "$WORKSPACE/output" ]; then
            dir="$WORKSPACE/output"
        fi
    fi
    if [ ! -d "$dir" ]; then
        log "No built IG to serve at $OUTPUT or $WORKSPACE/output"
        exit 1
    fi
    log "Serving $dir on 0.0.0.0:$SERVER_PORT"
    cd "$dir"
    exec python3 -m http.server "$SERVER_PORT" --bind 0.0.0.0
}

print_versions() {
    echo "alpine:    $(cat /etc/alpine-release)"
    echo "java:      $(java -version 2>&1 | head -n1)"
    echo "node:      $(node --version)"
    echo "npm:       $(npm --version)"
    echo "sushi:     $(sushi --version 2>&1 | tail -n1)"
    echo "ruby:      $(ruby --version)"
    echo "jekyll:    $(jekyll --version 2>&1)"
    echo "python:    $(python3 --version)"
    echo "graphviz:  $(dot -V 2>&1)"
    printf 'publisher: '
    java -jar "$IG_PUBLISHER_JAR" -v 2>&1 | head -n1 || true
}

cmd="${1:-publish}"
if [ "$#" -gt 0 ]; then shift; fi

case "$cmd" in
    publish|build)
        run_sushi
        run_publisher "$@"
        ;;
    publish-and-serve)
        run_sushi
        run_publisher "$@"
        serve_output
        ;;
    sushi)
        cd "$WORKSPACE"
        exec sushi "$@"
        ;;
    jekyll)
        cd "$WORKSPACE"
        exec jekyll "$@"
        ;;
    serve)
        serve_output
        ;;
    sync-output)
        sync_output
        ;;
    versions|version)
        print_versions
        ;;
    shell|bash)
        exec bash "$@"
        ;;
    help|-h|--help)
        cat <<EOF
Usage: docker run --rm \\
         -v \$PWD:/workspace -v \$PWD/out:/output \\
         -p 8080:8080 \\
         <image> [command]

Commands:
  publish              Run sushi (if applicable) then the FHIR IG Publisher. Default.
  publish-and-serve    Publish, then serve /output over HTTP on \$SERVER_PORT.
  serve                Serve an already-built /output over HTTP on \$SERVER_PORT.
  sync-output          Copy \$WORKSPACE/output to \$OUTPUT (run by 'publish' automatically).
  sushi [args...]      Invoke fsh-sushi directly.
  jekyll [args...]     Invoke jekyll directly.
  versions             Print versions of every bundled tool.
  shell | bash         Drop into an interactive shell.
  <anything else>      Executed verbatim inside the container.

Environment:
  WORKSPACE   Source mount (default /workspace)
  OUTPUT      Output mount (default /output)
  SERVER_PORT HTTP port for serve/publish-and-serve (default 8080)
EOF
        ;;
    *)
        exec "$cmd" "$@"
        ;;
esac
