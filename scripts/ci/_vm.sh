# shellcheck shell=sh
# Shared multipass VM helpers. Source this file — do not execute directly.
#
# Provides:
#   ensure_vm            — create/start the VM if needed, wait until reachable
#   ensure_docker_in_vm  — install docker + git in the VM if absent
#   transfer_repo        — copy the local repo into the VM (strips macOS metadata)
#   run_build_and_test   — build the image and run the test suite inside the VM
#   ci_run               — convenience wrapper: calls all four in order
#
# Configuration (set before sourcing or override in the environment):
#   VM_NAME    (default: ig-ci)
#   VM_CPUS    (default: 4)
#   VM_MEMORY  (default: 8G)
#   VM_DISK    (default: 20G)

# Locate the repo root: scripts/ci/ is two levels below it.
_VM_SH_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$_VM_SH_DIR/../.." && pwd)}"

VM_NAME="${VM_NAME:-ig-ci}"
VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY="${VM_MEMORY:-8G}"
VM_DISK="${VM_DISK:-20G}"
VM_IMAGE="${VM_IMAGE:-24.04}"

log() { printf '\033[1;36m[ci-multipass]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ci-multipass] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

ensure_vm() {
    log "Checking VM '$VM_NAME'..."
    _state="$(multipass info "$VM_NAME" 2>/dev/null \
        | awk '/^State:/{print $2}')"
    _state="${_state:-missing}"

    case "$_state" in
        Running)
            log "VM '$VM_NAME' is already running"
            ;;
        Stopped)
            log "Starting VM '$VM_NAME'..."
            multipass start "$VM_NAME"
            ;;
        missing)
            log "Creating VM '$VM_NAME' (${VM_CPUS} CPUs, ${VM_MEMORY} RAM, ${VM_DISK} disk)..."
            multipass launch \
                --name    "$VM_NAME" \
                --cpus    "$VM_CPUS" \
                --memory  "$VM_MEMORY" \
                --disk    "$VM_DISK" \
                "$VM_IMAGE"
            ;;
        *)
            die "VM '$VM_NAME' is in unexpected state: $_state"
            ;;
    esac

    log "Waiting for VM to accept connections..."
    _i=0
    while ! _vm_exec_ready; do
        _i=$((_i + 1))
        if [ "$_i" -ge 30 ]; then
            die "VM '$VM_NAME' did not become reachable after 30 attempts.
  On macOS this can happen when the multipass daemon loses its network
  bridge. Fix it by running (in a separate terminal):
    sudo launchctl stop  com.canonical.multipassd
    sudo launchctl start com.canonical.multipassd
  then re-run this script."
        fi
        sleep 1
    done
    log "VM '$VM_NAME' is ready"
}

# Probe VM reachability with a short per-attempt timeout so a broken SSH
# connection fails in a few seconds rather than hanging for ~30 s.
# IMPORTANT: do NOT redirect stdout to /dev/null — multipass exec hangs
# when its stdout fd is connected to /dev/null (SSH waits for it to close).
_vm_exec_ready() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 multipass exec "$VM_NAME" -- true 2>/dev/null
    else
        multipass exec "$VM_NAME" -- true 2>/dev/null
    fi
}

ensure_docker_in_vm() {
    if multipass exec "$VM_NAME" -- sh -c 'command -v docker >/dev/null 2>&1'; then
        log "Docker is already installed in the VM"
        return 0
    fi
    log "Installing Docker and git in the VM..."
    multipass exec "$VM_NAME" -- sh -c '
        sudo apt-get update -qq &&
        sudo apt-get install -y -qq docker.io docker-buildx git 2>&1 | tail -5 &&
        sudo usermod -aG docker ubuntu &&
        echo "docker install complete"
    '
}

transfer_repo() {
    log "Transferring repo to VM (this may take a moment)..."
    _tmptar="$(mktemp /tmp/fhir-ig-ci-XXXXXX.tar.gz)"
    # COPYFILE_DISABLE suppresses macOS AppleDouble (._*) resource-fork files.
    # On Linux this env var is a no-op so it is safe to set unconditionally.
    COPYFILE_DISABLE=1 tar -czf "$_tmptar" \
        -C "$REPO_ROOT" \
        --exclude='.git' \
        .
    multipass transfer "$_tmptar" "$VM_NAME:/tmp/fhir-ig-ci.tar.gz"
    rm -f "$_tmptar"
    multipass exec "$VM_NAME" -- sh -c '
        rm -rf "$HOME/fhir-ig-ci" &&
        mkdir  "$HOME/fhir-ig-ci" &&
        tar -xzf /tmp/fhir-ig-ci.tar.gz -C "$HOME/fhir-ig-ci" 2>/dev/null &&
        find "$HOME/fhir-ig-ci" -name "._*" -delete &&
        printf "transfer complete\n"
    '
}

run_build_and_test() {
    log "Building Docker image inside VM..."
    multipass exec "$VM_NAME" -- sh -c \
        'cd "$HOME/fhir-ig-ci" && sg docker -c "./scripts/build.sh --load"'
    log "Running test suite inside VM..."
    multipass exec "$VM_NAME" -- sh -c \
        'cd "$HOME/fhir-ig-ci" && sg docker -c "./scripts/test.sh"'
}

ci_run() {
    ensure_vm
    ensure_docker_in_vm
    transfer_repo
    run_build_and_test
    log "CI run complete."
}
