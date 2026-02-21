#!/bin/bash
#
# Shared VM test harness for docker-vm-runner based tests.
# Provides: logging, SSH key management, port allocation, watchdog, bundle generation.
#
# Usage: source "$SCRIPT_DIR/lib/vm_harness.sh"
#

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# Guard for options requiring a value argument (prevents unbound variable under set -u)
_require_arg() {
    if [ "$1" -lt 2 ]; then
        log_error "$2 requires a value"
        exit 1
    fi
}

# Generate a temporary SSH keypair for this test session
setup_ssh_key() {
    SSH_KEY_DIR=$(mktemp -d)
    ssh-keygen -t ed25519 -f "$SSH_KEY_DIR/id_test" -N "" -q
    SSH_OPTS+=(-i "$SSH_KEY_DIR/id_test")
}

cleanup_ssh_key() {
    if [ -n "$SSH_KEY_DIR" ] && [ -d "$SSH_KEY_DIR" ]; then
        rm -rf "$SSH_KEY_DIR"
        SSH_KEY_DIR=""
    fi
    # Reset SSH_OPTS to base (remove stale -i options from previous runs)
    SSH_OPTS=("${SSH_BASE_OPTS[@]}")
}

# Find a free port for SSH forwarding (with retry to mitigate race conditions)
find_free_port() {
    local port
    for _ in 1 2 3 4 5; do
        port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
        # Verify port is still free
        if ! ss -tln | grep -q ":${port}\b"; then
            echo "$port"
            return 0
        fi
        sleep 0.1
    done
    log_error "Failed to find a free port after 5 attempts"
    return 1
}

# Start a watchdog process that stops the container when the parent exits.
# Returns the watchdog PID via stdout.
# Usage: _WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$container_name")
_start_vm_container_watchdog() {
    local parent_pid=$1 container_name=$2
    setsid bash <<WATCHDOG_EOF </dev/null >/dev/null 2>&1 &
while kill -0 "$parent_pid" >/dev/null 2>&1; do sleep 2; done
docker stop "$container_name" >/dev/null 2>&1 || true
WATCHDOG_EOF
    echo "$!"
}

# Stop a single VM container and its watchdog.
# Usage: _cleanup_vm_container "$watchdog_pid" "$container_name"
#   Both arguments are values (PID and container name).
_cleanup_vm_container() {
    local _wpid="$1" _cname="$2"
    if [ -n "$_wpid" ]; then
        kill "$_wpid" >/dev/null 2>&1 || true
    fi
    if [ -n "$_cname" ]; then
        log_info "Stopping container $_cname..."
        docker stop "$_cname" >/dev/null 2>&1 || true
    fi
}

# Stop orphaned containers by label (shared across test runners)
# Usage: cleanup_orphaned_containers <label>
cleanup_orphaned_containers() {
    local label=$1
    docker ps -q --filter "label=managed-by=$label" 2>/dev/null | while read -r cid; do
        log_warn "Stopping orphaned container: $(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')"
        docker stop "$cid" >/dev/null 2>&1 || true
    done
}

# Generate a self-contained bundle script for bundled test execution.
# Usage: _generate_bundle <entry_script> <bundle_path> [include_mode]
#   entry_script:  path to the entry script (setup-k8s.sh or cleanup-k8s.sh)
#   bundle_path:   output file path
#   include_mode:  "true"/"all" to include all distro modules, "cleanup" for cleanup-only
_generate_bundle() {
    local entry_script="$1" bundle_path="$2" include_mode="${3:-all}"
    local project_root
    project_root="$(cd "$(dirname "$entry_script")" && pwd)"

    # Source bootstrap (provides _COMMON_MODULES, _generate_bundle_core) and
    # variables (provides BUNDLE_COMMON_MODULES derived from _COMMON_MODULES)
    if ! type -t _generate_bundle_core &>/dev/null; then
        # Save caller's EXIT trap (bootstrap.sh unconditionally sets its own)
        local _saved_exit_trap
        _saved_exit_trap=$(trap -p EXIT)
        source "${project_root}/common/bootstrap.sh"
        source "${project_root}/common/variables.sh"
        # Restore caller's EXIT trap (or clear bootstrap's if caller had none)
        if [ -n "$_saved_exit_trap" ]; then
            eval "$_saved_exit_trap"
        else
            trap - EXIT
        fi
    fi

    _generate_bundle_core "$bundle_path" "$entry_script" "$include_mode" "$project_root"
}

# Resolve latest stable Kubernetes minor version from dl.k8s.io.
# Sets K8S_VERSION if not already set.
# Usage: resolve_k8s_version
resolve_k8s_version() {
    if [ -n "$K8S_VERSION" ]; then return 0; fi
    log_info "Resolving latest stable Kubernetes version..."
    local stable_txt
    if ! stable_txt=$(curl -fsSL --retry 3 --retry-delay 2 https://dl.k8s.io/release/stable.txt); then
        log_error "Failed to fetch stable Kubernetes version from dl.k8s.io"
        return 1
    fi
    if echo "$stable_txt" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
        K8S_VERSION=$(echo "$stable_txt" | sed -E 's/^v([0-9]+\.[0-9]+)\..*/\1/')
        log_success "Detected: $K8S_VERSION"
    else
        log_error "Unexpected response from dl.k8s.io: $stable_txt"
        return 1
    fi
}

# Poll a VM for command completion via exit code file.
# Usage: poll_vm_command <ssh_func> <container_name> <exit_code_file> <log_file> <timeout> [<interval>]
#   ssh_func:        function to call for SSH commands (receives command as args)
#   container_name:  docker container name (for health checks)
#   exit_code_file:  remote path to the exit code file (e.g., /tmp/setup-exit-code)
#   log_file:        remote path to the log file for progress display (e.g., /tmp/setup-k8s.log)
#   timeout:         max seconds to wait
#   interval:        poll interval in seconds (default: 10)
# Returns: 0 on completion, 1 on timeout/container exit.
# Sets POLL_EXIT_CODE to the contents of the exit code file.
POLL_EXIT_CODE=""
poll_vm_command() {
    local ssh_func=$1 container_name=$2 exit_code_file=$3 log_file=$4 timeout=$5 interval=${6:-10}
    POLL_EXIT_CODE=""

    local start_time elapsed
    start_time=$(date +%s)
    while true; do
        elapsed=$(( $(date +%s) - start_time ))
        if [ $elapsed -gt "$timeout" ]; then
            log_error "Command timeout after ${timeout}s"
            return 1
        fi
        if ! docker inspect "$container_name" >/dev/null 2>&1; then
            log_error "Container exited unexpectedly"
            return 1
        fi
        if $ssh_func "test -f $exit_code_file" >/dev/null 2>&1; then
            break
        fi
        local progress_line
        progress_line=$($ssh_func "tail -1 $log_file" 2>/dev/null || true)
        [ -n "$progress_line" ] && log_info "[${elapsed}s] $progress_line"
        sleep "$interval"
    done

    local _raw_exit
    if ! _raw_exit=$($ssh_func "cat $exit_code_file" 2>/dev/null); then
        log_error "Failed to read exit code file from remote"
        return 1
    fi
    # shellcheck disable=SC2034 # read by callers after poll_vm_command returns
    POLL_EXIT_CODE=$(echo "$_raw_exit" | tr -d '[:space:]')
    if ! [[ "$POLL_EXIT_CODE" =~ ^[0-9]+$ ]]; then
        log_error "Invalid exit code from remote: '$POLL_EXIT_CODE'"
        return 1
    fi
}

# Wait for cloud-init to complete inside a docker-vm-runner container.
# Usage: wait_for_cloud_init <container_name> <timeout> <label>
wait_for_cloud_init() {
    local container_name=$1 timeout=$2 label=$3

    log_info "[$label] Waiting for cloud-init (timeout: ${timeout}s)..."
    local elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        if ! docker inspect "$container_name" >/dev/null 2>&1; then
            log_error "[$label] Container exited before cloud-init completed"
            return 1
        fi
        if docker logs --tail 50 "$container_name" 2>&1 | grep -qE "Cloud-init (complete|finished|disabled|did not finish)|Could not query cloud-init"; then
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        (( elapsed % 30 == 0 )) && log_info "[$label] Still waiting... (${elapsed}s)"
    done
    if [ $elapsed -ge "$timeout" ]; then
        log_error "[$label] Cloud-init timeout after ${timeout}s"
        return 1
    fi
    log_success "[$label] Cloud-init complete"
}

# Wait for SSH to become available.
# Usage: wait_for_ssh <port> <user> <timeout> <label>
wait_for_ssh() {
    local port=$1 user=$2 timeout=$3 label=$4

    log_info "[$label] Waiting for SSH..."
    local elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        if ssh "${SSH_OPTS[@]}" -p "$port" "${user}@localhost" "echo ready" >/dev/null 2>&1; then
            break
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    if [ $elapsed -ge "$timeout" ]; then
        log_error "[$label] SSH not available after ${timeout}s"
        return 1
    fi
    log_success "[$label] SSH is ready"
}

# SSH helper: run command on VM as root (requires SSH_OPTS, SSH_PORT, LOGIN_USER)
vm_ssh() {
    ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$LOGIN_USER@localhost" sudo "$@"
}

# SCP helper: copy file to VM (requires SSH_OPTS, SSH_PORT, LOGIN_USER)
vm_scp() {
    local local_path=$1 remote_path=$2
    scp "${SSH_OPTS[@]}" -P "$SSH_PORT" "$local_path" "${LOGIN_USER}@localhost:${remote_path}"
}
