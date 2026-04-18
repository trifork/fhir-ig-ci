#!/usr/bin/env bash
# Unit-test the built fhir-ig-ci image. Safe to run locally or in CI.
#
# Usage: scripts/test.sh
#
# Requires the image ${FULL_IMAGE}:${IMAGE_TAG} to be loadable in local docker.
# If the image isn't present, this script builds it with scripts/build.sh --load.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

IMAGE="${FULL_IMAGE}:${IMAGE_TAG}"
SAMPLE_IG="$REPO_ROOT/tests/sample-ig"

log "Using engine: $ENGINE"
if ! engine image inspect "$IMAGE" >/dev/null 2>&1; then
    log "Image $IMAGE not present locally — building single-arch"
    "$SCRIPT_DIR/build.sh" --load
fi

PASS=0
FAIL=0
run_case() {
    local name="$1"; shift
    printf '\n\033[1;33m▶ %s\033[0m\n' "$name"
    if "$@"; then
        printf '\033[1;32m  ✓ %s\033[0m\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '\033[1;31m  ✗ %s\033[0m\n' "$name"
        FAIL=$((FAIL + 1))
    fi
}

runc() {
    engine run --rm "$@"
}

# --- Test cases ------------------------------------------------------------

tc_versions() {
    runc "$IMAGE" versions
}

tc_java_17_plus() {
    local out
    out="$(runc "$IMAGE" bash -c 'java -version 2>&1 | head -n1')"
    echo "$out"
    echo "$out" | grep -Eq '"(1[7-9]|2[0-9])\.' || return 1
}

tc_sushi_runs() {
    runc "$IMAGE" sushi --help >/dev/null
}

tc_jekyll_runs() {
    runc "$IMAGE" jekyll --version >/dev/null
}

tc_python_runs() {
    runc "$IMAGE" bash -lc 'python3 -c "import http.server, sys; sys.exit(0)"'
}

tc_publisher_jar_present() {
    runc "$IMAGE" bash -lc 'test -s "$IG_PUBLISHER_JAR"'
}

tc_graphviz_runs() {
    runc "$IMAGE" bash -lc 'dot -V'
}

tc_sushi_compiles_sample() {
    [ -d "$SAMPLE_IG" ] || { echo "missing $SAMPLE_IG"; return 1; }
    local workdir
    workdir="$(mktemp -d)"
    cp -a "$SAMPLE_IG/." "$workdir/"
    runc -v "$workdir:/workspace" "$IMAGE" sushi . >"$workdir/sushi.log" 2>&1 || {
        tail -n 40 "$workdir/sushi.log"
        rm -rf "$workdir"
        return 1
    }
    test -d "$workdir/fsh-generated/resources" || {
        echo "sushi did not produce fsh-generated/resources"
        rm -rf "$workdir"
        return 1
    }
    rm -rf "$workdir"
}

tc_serve_exposes_port() {
    local workdir="" cid="" port=18080 ok=0 rc=0
    workdir="$(mktemp -d)"
    mkdir -p "$workdir/output"
    printf '<html><body>fhir-ig-ci OK</body></html>' > "$workdir/output/index.html"
    cid="$(engine run -d --rm \
        -v "$workdir:/workspace" \
        -p "$port:8080" \
        "$IMAGE" serve)" || { rm -rf "$workdir"; return 1; }
    for _ in $(seq 1 30); do
        if curl -fsS "http://127.0.0.1:$port/" 2>/dev/null | grep -q "fhir-ig-ci OK"; then
            ok=1; break
        fi
        sleep 1
    done
    [ "$ok" = "1" ] || rc=1
    engine rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$workdir"
    return "$rc"
}

tc_arch_matches_host() {
    local host_arch img_arch
    host_arch="$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
    img_arch="$(engine image inspect "$IMAGE" --format '{{.Architecture}}')"
    echo "host=$host_arch image=$img_arch"
    [ "$host_arch" = "$img_arch" ]
}

# --- Run -------------------------------------------------------------------

run_case "versions print"                     tc_versions
run_case "java >= 17"                         tc_java_17_plus
run_case "sushi --help"                       tc_sushi_runs
run_case "jekyll --version"                   tc_jekyll_runs
run_case "python3 http.server importable"     tc_python_runs
run_case "publisher.jar present"              tc_publisher_jar_present
run_case "graphviz dot -V"                    tc_graphviz_runs
run_case "sushi compiles sample IG"           tc_sushi_compiles_sample
run_case "serve exposes HTTP on 8080"         tc_serve_exposes_port
run_case "image arch matches host"            tc_arch_matches_host

echo
printf '\033[1;36m[ig-ci]\033[0m %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
