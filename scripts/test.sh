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

tc_output_mount_writes_through() {
    local ws out
    ws="$(mktemp -d)"
    out="$(mktemp -d)"
    if ! runc -v "$ws:/workspace" -v "$out:/output" "$IMAGE" \
            bash -c 'echo "uid=$(id -u) gid=$(id -g)" > /output/probe.txt'; then
        rm -rf "$ws" "$out"
        return 1
    fi
    if [ ! -s "$out/probe.txt" ] || ! grep -q '^uid=' "$out/probe.txt"; then
        echo "expected $out/probe.txt with uid=... line"
        ls -la "$out" || true
        rm -rf "$ws" "$out"
        return 1
    fi
    rm -rf "$ws" "$out"
}

tc_sync_output_copies_workspace_output() {
    local ws out
    ws="$(mktemp -d)"
    out="$(mktemp -d)"
    mkdir -p "$ws/output/sub"
    printf '<html>fhir-ig-ci built</html>' > "$ws/output/index.html"
    printf 'body{}'                       > "$ws/output/sub/style.css"
    if ! runc -v "$ws:/workspace" -v "$out:/output" "$IMAGE" sync-output; then
        rm -rf "$ws" "$out"
        return 1
    fi
    if [ ! -f "$out/index.html" ] || ! grep -q 'fhir-ig-ci built' "$out/index.html"; then
        echo "expected $out/index.html with synced content"
        ls -laR "$out" || true
        rm -rf "$ws" "$out"
        return 1
    fi
    if [ ! -f "$out/sub/style.css" ]; then
        echo "expected $out/sub/style.css to be synced"
        ls -laR "$out" || true
        rm -rf "$ws" "$out"
        return 1
    fi
    rm -rf "$ws" "$out"
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

tc_logs_written_to_mount() {
    # Mount a *subdirectory* as /logs, not the mktemp dir itself.
    # The entrypoint chowns /logs to the container's ig user; if we mount
    # the mktemp dir directly, /tmp's sticky bit prevents the runner (a
    # different uid) from removing it afterwards.  With a subdirectory the
    # parent tmpdir stays owned by the runner and rm -rf works cleanly.
    local parent logs logfile
    parent="$(mktemp -d)"
    logs="$parent/logs"
    mkdir "$logs"
    chmod 777 "$logs"

    echo "  before: $(ls -ld "$logs")"
    runc -v "$logs:/logs" "$IMAGE" versions >/dev/null || {
        echo "  container exited non-zero; logs dir: $(ls -la "$logs" 2>&1 || true)"
        rm -rf "$parent"
        return 1
    }
    echo "  after:  $(ls -ld "$logs")"
    ls -la "$logs"

    logfile="$(ls "$logs"/fhir-ig-ci-*.log 2>/dev/null | head -n1)"
    if [ -z "$logfile" ]; then
        echo "no fhir-ig-ci-*.log found in $logs"
        rm -rf "$parent"
        return 1
    fi
    echo "  logfile: $logfile"
    if ! grep -qi 'java\|sushi\|publisher\|logging' "$logfile"; then
        echo "log file appears empty or missing expected content:"
        cat "$logfile"
        rm -rf "$parent"
        return 1
    fi
    rm -rf "$parent"
}

tc_plantuml_fontmanager() {
    # PlantUML uses AWT font rendering which requires libfontmanager.so.
    # Alpine's openjdk*-jre-headless omits it; openjdk*-jre adds it back.
    # Verify the library is present AND that AWT font rendering actually works
    # by running a single-file Java program (no javac needed, Java 11+ feature).
    local out
    out="$(runc "$IMAGE" bash -lc '
        cat > /tmp/FontTest.java << '"'"'EOF'"'"'
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
public class FontTest {
    public static void main(String[] args) {
        System.setProperty("java.awt.headless", "true");
        BufferedImage img = new BufferedImage(100, 50, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = img.createGraphics();
        g.setFont(new Font("SansSerif", Font.PLAIN, 12));
        g.getFontMetrics().stringWidth("plantuml-test");
        g.dispose();
        System.out.println("OK");
    }
}
EOF
        java /tmp/FontTest.java 2>&1
    ')"
    echo "$out"
    printf '%s\n' "$out" | grep -q '^OK$'
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
run_case "/output bind mount is writable"     tc_output_mount_writes_through
run_case "sync-output copies to /output"      tc_sync_output_copies_workspace_output
run_case "serve exposes HTTP on 8080"         tc_serve_exposes_port
run_case "logs written to /logs mount"        tc_logs_written_to_mount
run_case "PlantUML AWT font rendering"        tc_plantuml_fontmanager
run_case "image arch matches host"            tc_arch_matches_host

echo
printf '\033[1;36m[ig-ci]\033[0m %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
