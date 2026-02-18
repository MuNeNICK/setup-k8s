#!/bin/bash
#
# K8s Multi-Distribution Test Runner
# Usage: ./run-e2e-tests.sh <distro-name>
#

set -euo pipefail

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_K8S_SCRIPT="$SCRIPT_DIR/../setup-k8s.sh"
CLEANUP_K8S_SCRIPT="$SCRIPT_DIR/../cleanup-k8s.sh"
DOCKER_VM_RUNNER_IMAGE="${DOCKER_VM_RUNNER_IMAGE:-ghcr.io/munenick/docker-vm-runner:latest}"
VM_DATA_DIR="${VM_DATA_DIR:-$SCRIPT_DIR/data}"

SUPPORTED_DISTROS=(
    ubuntu-2404
    ubuntu-2204
    ubuntu-2004
    debian-12
    debian-11
    centos-stream-9
    fedora-41
    opensuse-leap-155
    rocky-linux-9
    rocky-linux-8
    almalinux-9
    almalinux-8
    archlinux
)

# VM resource defaults
VM_MEMORY="${VM_MEMORY:-8192}"
VM_CPUS="${VM_CPUS:-4}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"

# K8s version (can be overridden by command line option)
K8S_VERSION=""
# Extra args to pass to setup-k8s.sh
SETUP_EXTRA_ARGS=()
# Test mode (offline or online)
TEST_MODE="offline"
# Login user (fixed: docker-vm-runner vendor cloud-config creates 'user')
LOGIN_USER="user"

# Timeout settings (seconds)
TIMEOUT_TOTAL=1200    # 20 minutes
SSH_READY_TIMEOUT=300 # 5 minutes for SSH to become available

# SSH settings
SSH_KEY_DIR=""
SSH_PORT=""
SSH_BASE_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
SSH_OPTS=("${SSH_BASE_OPTS[@]}")

# Global cleanup state (must be module-level for EXIT trap)
_VM_CONTAINER_NAME=""
_WATCHDOG_PID=""

_start_vm_container_watchdog() {
    local parent_pid=$1
    local container_name=$2

    if [ -n "$_WATCHDOG_PID" ]; then
        kill "$_WATCHDOG_PID" >/dev/null 2>&1 || true
        _WATCHDOG_PID=""
    fi

    setsid bash -c '
parent_pid="$1"
container_name="$2"
while kill -0 "$parent_pid" >/dev/null 2>&1; do
    sleep 2
done
docker stop "$container_name" >/dev/null 2>&1 || true
' _ "$parent_pid" "$container_name" </dev/null >/dev/null 2>&1 &
    _WATCHDOG_PID="$!"
}

_cleanup_vm_container() {
    if [ -n "$_WATCHDOG_PID" ]; then
        kill "$_WATCHDOG_PID" >/dev/null 2>&1 || true
        _WATCHDOG_PID=""
    fi

    if [ -n "$_VM_CONTAINER_NAME" ]; then
        echo -e "${BLUE}[INFO]${NC} Stopping container $_VM_CONTAINER_NAME..."
        docker stop "$_VM_CONTAINER_NAME" >/dev/null 2>&1 || true
        _VM_CONTAINER_NAME=""
    fi
}

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

# Help message
show_help() {
    cat <<EOF
K8s Multi-Distribution Test Runner

Usage: $0 [OPTIONS] <distro-name>

Options:
  --all, -a                 Test all distributions sequentially
  --k8s-version <version>   Kubernetes version to test (e.g., 1.32, 1.31, 1.30)
  --setup-args ARGS         Extra args for setup-k8s.sh (use quotes)
  --online                  Run test in online mode (fetch script from GitHub)
  --offline                 Run test in offline mode with bundled scripts (default)
  --memory <MB>             VM memory in MB (default: $VM_MEMORY)
  --cpus <count>            VM CPU count (default: $VM_CPUS)
  --disk-size <size>        VM disk size (default: $VM_DISK_SIZE)
  --                        Treat the rest as setup-args
  --help, -h                Show this help message

Supported distributions:
EOF
    for distro in "${SUPPORTED_DISTROS[@]}"; do
        echo "  - $distro"
    done
    echo
    echo "Examples:"
    echo "  $0 ubuntu-2404                        # Test single distribution offline (bundled)"
    echo "  $0 --online ubuntu-2404               # Test single distribution online (GitHub)"
    echo "  $0 --k8s-version 1.31 ubuntu-2404     # Test with specific k8s version"
    echo "  $0 --all                              # Test all distributions offline"
    echo "  $0 --all --online                     # Test all distributions online"
    echo "  $0 --all --k8s-version 1.30           # Test all distributions with k8s v1.30"
    echo "  $0 --memory 16384 --cpus 8 ubuntu-2404  # Test with custom VM resources"
    echo "  $0 archlinux"
    echo "  $0 --k8s-version 1.32 rocky-linux-8"
    echo
    echo "Test Modes:"
    echo "  Online:  Downloads setup-k8s.sh from GitHub during test execution"
    echo "  Offline: Uses pre-bundled script with all modules included"
}

# Prepare data directory for docker-vm-runner (mounted as /data in container)
prepare_runner_directories() {
    mkdir -p "$VM_DATA_DIR"
}

prepare_vm_runner_environment() {
    prepare_runner_directories
}

# Load configuration function
load_config() {
    local distro=$1
    local found=false
    for d in "${SUPPORTED_DISTROS[@]}"; do
        if [ "$d" = "$distro" ]; then found=true; break; fi
    done
    if [ "$found" = false ]; then
        log_error "Unknown distribution: $distro"
        echo "Available distributions:"
        printf '  %s\n' "${SUPPORTED_DISTROS[@]}"
        return 1
    fi
    log_info "Configuration loaded:"
    log_info "  Distribution: $distro"
    log_info "  Login user: $LOGIN_USER"
    return 0
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

# Find a free port for SSH forwarding
find_free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'
}

# SSH helper: run command on VM as root
vm_ssh() {
    ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$LOGIN_USER@localhost" "sudo $*"
}

# SSH helper: run command on VM as user
vm_ssh_user() {
    ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$LOGIN_USER@localhost" "$*"
}

# SCP helper: copy file to VM
vm_scp() {
    local local_path=$1 remote_path=$2
    scp "${SSH_OPTS[@]}" -P "$SSH_PORT" "$local_path" "${LOGIN_USER}@localhost:${remote_path}"
}

# Generate bundled scripts for offline mode
generate_bundled_scripts() {
    local setup_bundle="/tmp/setup-k8s-bundle.sh"
    local cleanup_bundle="/tmp/cleanup-k8s-bundle.sh"

    log_info "Generating bundled scripts (mode: $TEST_MODE)..."

    # Only generate bundled scripts in offline mode
    if [ "$TEST_MODE" = "offline" ]; then
        # Generate setup bundle
        {
            echo "#!/bin/bash"
            echo "# Bundled setup-k8s.sh with all modules"
            echo "set -e"
            echo ""
            echo "# Force offline mode"
            echo "OFFLINE_MODE=true"
            echo ""

        # Include all common modules
        for module in logging variables detection validation helpers networking swap completion helm; do
            echo "# === common/${module}.sh ==="
            cat "${SCRIPT_DIR}/../common/${module}.sh"
            echo ""
        done

        # Include all distro modules (removing source lines that reference other modules)
        for distro_dir in "${SCRIPT_DIR}/../distros/"*/; do
            if [ -d "$distro_dir" ]; then
                distro_name=$(basename "$distro_dir")
                echo "# === distros/${distro_name} modules ==="
                for module_file in "$distro_dir"*.sh; do
                    if [ -f "$module_file" ]; then
                        echo "# === $(basename "$module_file") ==="
                        # Remove source lines and SCRIPT_DIR declarations since everything is bundled
                        awk '!/^source.*SCRIPT_DIR/ && !/^SCRIPT_DIR=/' "$module_file"
                        echo ""
                    fi
                done
            fi
        done

            # Include main setup script (without shebang)
            echo "# === Main setup-k8s.sh ==="
            tail -n +2 "$SETUP_K8S_SCRIPT"
        } > "$setup_bundle"

        # Generate cleanup bundle
        {
            echo "#!/bin/bash"
            echo "# Bundled cleanup-k8s.sh with all modules"
            echo "set -e"
            echo ""
            echo "# Force offline mode"
            echo "OFFLINE_MODE=true"
            echo ""

            # Include all common modules
            for module in logging variables detection validation helpers networking swap completion helm; do
                echo "# === common/${module}.sh ==="
                cat "${SCRIPT_DIR}/../common/${module}.sh"
                echo ""
            done

            # Include all distro cleanup modules (removing source lines that reference other modules)
            for distro_dir in "${SCRIPT_DIR}/../distros/"*/; do
                if [ -d "$distro_dir" ]; then
                    distro_name=$(basename "$distro_dir")
                    if [ -f "$distro_dir/cleanup.sh" ]; then
                        echo "# === distros/${distro_name}/cleanup.sh ==="
                        # Remove source lines and SCRIPT_DIR declarations since everything is bundled
                        awk '!/^source.*SCRIPT_DIR/ && !/^SCRIPT_DIR=/' "$distro_dir/cleanup.sh"
                        echo ""
                    fi
                fi
            done

            # Include main cleanup script (without shebang)
            echo "# === Main cleanup-k8s.sh ==="
            tail -n +2 "$CLEANUP_K8S_SCRIPT"
        } > "$cleanup_bundle"

        log_info "Bundled scripts generated successfully for offline mode"
    else
        # For online mode, create empty files or minimal scripts
        echo "#!/bin/bash" > "$setup_bundle"
        echo "echo 'Online mode - should use curl'" >> "$setup_bundle"
        echo "#!/bin/bash" > "$cleanup_bundle"
        echo "echo 'Online mode - should use curl'" >> "$cleanup_bundle"
        log_info "Placeholder scripts created for online mode"
    fi
}

# Execute and monitor VM via SSH
run_vm_container() {
    local distro=$1
    local k8s_version_arg=$2
    local setup_extra_args_str=$3
    local container_name="k8s-vm-${distro}-$(date +%s)"
    local log_file="results/logs/${distro}-$(date +%Y%m%d-%H%M%S).log"

    log_info "Starting docker-vm-runner for: $distro"
    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    mkdir -p results/logs
    rm -f results/test-result.json

    # Clean up any leftover container from a previous failed test (safety net for --all mode)
    _cleanup_vm_container

    # Stop orphaned containers from previous interrupted runs (label-based)
    for cid in $(docker ps -q --filter "label=managed-by=k8s-test-runner" 2>/dev/null); do
        log_warn "Stopping orphaned test container: $(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')"
        docker stop "$cid" >/dev/null 2>&1 || true
    done

    # Register container for cleanup (module-level for EXIT trap)
    _VM_CONTAINER_NAME=""
    trap '_cleanup_vm_container; cleanup_ssh_key' EXIT INT TERM HUP

    # Generate SSH keypair for this test
    setup_ssh_key
    SSH_PORT=$(find_free_port)

    # Start container in detached mode
    log_info "Starting container: $container_name (SSH port: $SSH_PORT)"
    docker run -d --rm \
        --name "$container_name" \
        --label "managed-by=k8s-test-runner" \
        --device /dev/kvm:/dev/kvm \
        -v "$VM_DATA_DIR:/data" \
        -p "${SSH_PORT}:2222" \
        -e "DISTRO=$distro" \
        -e "GUEST_NAME=$container_name" \
        -e "SSH_PUBKEY=$(cat "$SSH_KEY_DIR/id_test.pub")" \
        -e "NO_CONSOLE=1" \
        -e "MEMORY=$VM_MEMORY" \
        -e "CPUS=$VM_CPUS" \
        -e "DISK_SIZE=$VM_DISK_SIZE" \
        "$DOCKER_VM_RUNNER_IMAGE" >/dev/null
    _VM_CONTAINER_NAME="$container_name"
    _start_vm_container_watchdog "$$" "$container_name"
    log_success "Container started"

    # Wait for cloud-init to complete via docker-vm-runner logs (guest agent based)
    # SSH key injection happens during cloud-init, so SSH is not available until cloud-init succeeds.
    log_info "Waiting for cloud-init to complete (timeout: ${SSH_READY_TIMEOUT}s)..."
    local ci_elapsed=0
    while [ $ci_elapsed -lt $SSH_READY_TIMEOUT ]; do
        if ! docker inspect "$container_name" >/dev/null 2>&1; then
            log_error "Container exited before cloud-init completed"
            _cleanup_vm_container
            return 1
        fi
        if docker logs "$container_name" 2>&1 | grep -qE "Cloud-init (complete|finished|disabled|did not finish)|Could not query cloud-init"; then
            break
        fi
        sleep 5
        ci_elapsed=$((ci_elapsed + 5))
        if (( ci_elapsed % 30 == 0 )); then
            log_info "Still waiting for cloud-init... (${ci_elapsed}s)"
        fi
    done

    if [ $ci_elapsed -ge $SSH_READY_TIMEOUT ]; then
        log_error "Cloud-init did not complete after ${SSH_READY_TIMEOUT}s"
        _cleanup_vm_container
        return 1
    fi
    log_success "Cloud-init complete"

    # Wait for SSH (should be available immediately after cloud-init)
    log_info "Waiting for SSH..."
    local ssh_elapsed=0
    while [ $ssh_elapsed -lt 60 ]; do
        if vm_ssh_user "echo ready" >/dev/null 2>&1; then
            break
        fi
        sleep 3
        ssh_elapsed=$((ssh_elapsed + 3))
    done

    if [ $ssh_elapsed -ge 60 ]; then
        log_error "SSH not available after cloud-init completed"
        _cleanup_vm_container
        return 1
    fi
    log_success "SSH is ready"

    # --- Deploy scripts ---
    if [ "$TEST_MODE" = "online" ]; then
        log_info "Downloading setup-k8s.sh in VM..."
        if ! vm_ssh "curl -fsSL --connect-timeout 10 --max-time 60 https://raw.github.com/MuNeNICK/setup-k8s/main/setup-k8s.sh -o /tmp/setup-k8s.sh && chmod +x /tmp/setup-k8s.sh" >/dev/null 2>&1; then
            log_error "Failed to download setup-k8s.sh in VM"
            _cleanup_vm_container
            return 1
        fi
        log_info "Downloading cleanup-k8s.sh in VM..."
        if ! vm_ssh "curl -fsSL --connect-timeout 10 --max-time 60 https://raw.github.com/MuNeNICK/setup-k8s/main/cleanup-k8s.sh -o /tmp/cleanup-k8s.sh && chmod +x /tmp/cleanup-k8s.sh" >/dev/null 2>&1; then
            log_error "Failed to download cleanup-k8s.sh in VM"
            _cleanup_vm_container
            return 1
        fi
        log_success "Scripts downloaded in VM"
    else
        generate_bundled_scripts
        log_info "Transferring bundled scripts to VM..."
        vm_scp "/tmp/setup-k8s-bundle.sh" "/tmp/setup-k8s.sh"
        vm_scp "/tmp/cleanup-k8s-bundle.sh" "/tmp/cleanup-k8s.sh"
        vm_ssh "chmod +x /tmp/setup-k8s.sh /tmp/cleanup-k8s.sh" >/dev/null 2>&1
        rm -f /tmp/setup-k8s-bundle.sh /tmp/cleanup-k8s-bundle.sh
        log_success "Bundled scripts deployed to VM"
    fi

    # --- Phase 1: Run setup-k8s.sh ---
    log_info "Starting Kubernetes setup (master node)..."
    vm_ssh "bash -c 'nohup bash /tmp/setup-k8s.sh --node-type master ${k8s_version_arg} ${setup_extra_args_str} > /tmp/setup-k8s.log 2>&1; echo \$? > /tmp/setup-exit-code' &" >/dev/null 2>&1

    # Poll for setup completion
    local start_time=$(date +%s)
    while true; do
        local elapsed=$(( $(date +%s) - start_time ))
        if [ $elapsed -gt $TIMEOUT_TOTAL ]; then
            log_error "Setup timeout after ${TIMEOUT_TOTAL}s"
            vm_ssh "cat /tmp/setup-k8s.log" > "$log_file" 2>/dev/null || true
            _cleanup_vm_container
            return 1
        fi
        if ! docker inspect "$container_name" >/dev/null 2>&1; then
            log_error "Container exited unexpectedly"
            _cleanup_vm_container
            return 1
        fi
        if vm_ssh "test -f /tmp/setup-exit-code" >/dev/null 2>&1; then
            break
        fi
        local progress_line
        progress_line=$(vm_ssh "tail -1 /tmp/setup-k8s.log" 2>/dev/null || true)
        if [ -n "$progress_line" ]; then
            log_info "[${elapsed}s] $progress_line"
        fi
        sleep 10
    done

    local setup_exit_code
    setup_exit_code=$(vm_ssh "cat /tmp/setup-exit-code" 2>/dev/null || echo "1")
    setup_exit_code=$(echo "$setup_exit_code" | tr -d '[:space:]')
    log_info "Setup completed with exit code: $setup_exit_code"

    if [ "$setup_exit_code" -ne 0 ]; then
        log_error "=== SETUP ERROR LOG ==="
        vm_ssh "cat /tmp/setup-k8s.log" 2>/dev/null || true
        log_error "=== SETUP ERROR LOG END ==="
    fi

    # --- Phase 2: Verify setup ---
    log_info "Verifying Kubernetes components..."
    local kubelet_status
    kubelet_status=$(vm_ssh "systemctl is-active kubelet" 2>/dev/null) || kubelet_status="inactive"
    kubelet_status=$(echo "$kubelet_status" | tr -d '[:space:]')
    log_info "kubelet: $kubelet_status"

    local kubeconfig_exists="false"
    if vm_ssh "test -f /etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        kubeconfig_exists="true"
    fi

    local api_responsive="false"
    if vm_ssh "timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        api_responsive="true"
        log_info "API server is responsive"
    else
        log_info "API server is not responsive"
    fi

    local setup_test_status="failed"
    if [ "$setup_exit_code" -eq 0 ] && [ "$kubelet_status" = "active" ] && [ "$api_responsive" = "true" ]; then
        setup_test_status="success"
        log_success "Setup test: SUCCESS"
    else
        log_error "Setup test: FAILED"
    fi

    # --- Phase 3: Cleanup (only if setup succeeded) ---
    local cleanup_exit_code=0 cleanup_test_status="skipped"
    local services_stopped="unknown" config_cleaned="unknown" packages_removed="unknown"

    if [ "$setup_test_status" = "success" ]; then
        log_info "Starting Kubernetes cleanup..."
        vm_ssh "bash -c 'nohup bash /tmp/cleanup-k8s.sh --force > /tmp/cleanup-k8s.log 2>&1; echo \$? > /tmp/cleanup-exit-code' &" >/dev/null 2>&1

        # Poll for cleanup completion
        start_time=$(date +%s)
        while true; do
            local elapsed=$(( $(date +%s) - start_time ))
            if [ $elapsed -gt $TIMEOUT_TOTAL ]; then
                log_error "Cleanup timeout"
                break
            fi
            if ! docker inspect "$container_name" >/dev/null 2>&1; then
                log_error "Container exited during cleanup"
                _cleanup_vm_container
                return 1
            fi
            if vm_ssh "test -f /tmp/cleanup-exit-code" >/dev/null 2>&1; then
                break
            fi
            sleep 10
        done

        cleanup_exit_code=$(vm_ssh "cat /tmp/cleanup-exit-code" 2>/dev/null || echo "1")
        cleanup_exit_code=$(echo "$cleanup_exit_code" | tr -d '[:space:]')
        log_info "Cleanup completed with exit code: $cleanup_exit_code"

        # --- Phase 4: Verify cleanup ---
        log_info "Verifying cleanup..."
        local kubelet_active kubelet_enabled
        kubelet_active=$(vm_ssh "systemctl is-active kubelet" 2>/dev/null) || kubelet_active="inactive"
        kubelet_enabled=$(vm_ssh "systemctl is-enabled kubelet" 2>/dev/null) || kubelet_enabled="disabled"

        if [ "$(echo "$kubelet_active" | tr -d '[:space:]')" = "active" ] || [ "$(echo "$kubelet_enabled" | tr -d '[:space:]')" = "enabled" ]; then
            services_stopped="false"
        else
            services_stopped="true"
        fi

        if vm_ssh "test -d /etc/kubernetes && ls -A /etc/kubernetes 2>/dev/null | head -1 | grep -q ." >/dev/null 2>&1; then
            config_cleaned="false"
        elif vm_ssh "test -f /etc/default/kubelet" >/dev/null 2>&1; then
            config_cleaned="false"
        else
            config_cleaned="true"
        fi

        packages_removed="true"
        for cmd in kubeadm kubectl kubelet; do
            if vm_ssh "command -v $cmd" >/dev/null 2>&1; then
                packages_removed="false"
                break
            fi
        done

        if [ "$cleanup_exit_code" -eq 0 ] && [ "$services_stopped" = "true" ] && \
           [ "$config_cleaned" = "true" ] && [ "$packages_removed" = "true" ]; then
            cleanup_test_status="success"
            log_success "Cleanup test: SUCCESS"
        else
            cleanup_test_status="failed"
            log_error "Cleanup test: FAILED"
        fi
    else
        log_info "Skipping cleanup test due to setup failure"
    fi

    # --- Retrieve logs ---
    vm_ssh "cat /tmp/setup-k8s.log" > "$log_file" 2>/dev/null || true
    vm_ssh "cat /tmp/cleanup-k8s.log" >> "$log_file" 2>/dev/null || true

    # --- Write test-result.json (on host) ---
    local final_status="failed"
    if [ "$setup_test_status" = "success" ] && [ "$cleanup_test_status" = "success" ]; then
        final_status="success"
    fi

    cat > "results/test-result.json" <<JSONEOF
{
  "status": "$final_status",
  "setup_test": {
    "status": "$setup_test_status",
    "exit_code": $setup_exit_code,
    "kubelet_status": "$kubelet_status",
    "kubeconfig_exists": $kubeconfig_exists,
    "api_responsive": $api_responsive
  },
  "cleanup_test": {
    "status": "$cleanup_test_status",
    "exit_code": $cleanup_exit_code,
    "services_stopped": "$services_stopped",
    "config_cleaned": "$config_cleaned",
    "packages_removed": "$packages_removed"
  },
  "timestamp": "$(date -Iseconds)"
}
JSONEOF

    # Stop container
    _cleanup_vm_container
    cleanup_ssh_key
    trap - EXIT INT TERM HUP
    return 0
}

# Show test results (uses jq if available, falls back to grep/sed)
show_test_results() {
    local distro=$1

    if [ ! -f "results/test-result.json" ]; then
        log_error "Test result not found"
        return 1
    fi

    log_info "Test Results for $distro:"
    echo "=================="

    local overall_status="" setup_status="" setup_exit_code="" kubelet_status="" api_responsive=""
    local cleanup_status="" cleanup_exit_code="" services_stopped="" config_cleaned="" packages_removed=""

    if command -v jq &>/dev/null; then
        # Preferred: use jq for robust JSON parsing
        overall_status=$(jq -r '.status // "unknown"' results/test-result.json)
        setup_status=$(jq -r '.setup_test.status // "unknown"' results/test-result.json)
        setup_exit_code=$(jq -r '.setup_test.exit_code // "unknown"' results/test-result.json)
        kubelet_status=$(jq -r '.setup_test.kubelet_status // "unknown"' results/test-result.json)
        api_responsive=$(jq -r '.setup_test.api_responsive // "unknown"' results/test-result.json)
        cleanup_status=$(jq -r '.cleanup_test.status // "unknown"' results/test-result.json)
        cleanup_exit_code=$(jq -r '.cleanup_test.exit_code // "unknown"' results/test-result.json)
        services_stopped=$(jq -r '.cleanup_test.services_stopped // "unknown"' results/test-result.json)
        config_cleaned=$(jq -r '.cleanup_test.config_cleaned // "unknown"' results/test-result.json)
        packages_removed=$(jq -r '.cleanup_test.packages_removed // "unknown"' results/test-result.json)
    else
        # Fallback: grep/sed parsing
        local json_content
        json_content=$(cat results/test-result.json)
        overall_status=$(echo "$json_content" | grep -o '"status": *"[^"]*"' | head -1 | cut -d'"' -f4)
        local setup_block
        setup_block=$(echo "$json_content" | sed -n '/"setup_test":/,/^  }/p')
        setup_status=$(echo "$setup_block" | grep '"status"' | head -1 | cut -d'"' -f4)
        setup_exit_code=$(echo "$setup_block" | grep '"exit_code"' | grep -o '[0-9]*' | head -1)
        kubelet_status=$(echo "$setup_block" | grep '"kubelet_status"' | cut -d'"' -f4)
        api_responsive=$(echo "$setup_block" | grep '"api_responsive"' | sed 's/.*: *"\?\([^",]*\)"\?.*/\1/')
        local cleanup_block
        cleanup_block=$(echo "$json_content" | sed -n '/"cleanup_test":/,/^  }/p')
        cleanup_status=$(echo "$cleanup_block" | grep '"status"' | head -1 | cut -d'"' -f4)
        cleanup_exit_code=$(echo "$cleanup_block" | grep '"exit_code"' | grep -o '[0-9]*' | head -1)
        services_stopped=$(echo "$cleanup_block" | grep '"services_stopped"' | cut -d'"' -f4)
        config_cleaned=$(echo "$cleanup_block" | grep '"config_cleaned"' | cut -d'"' -f4)
        packages_removed=$(echo "$cleanup_block" | grep '"packages_removed"' | cut -d'"' -f4)
    fi

    echo "Setup Test:"
    echo "  Status: ${setup_status:-unknown}"
    echo "  Exit Code: ${setup_exit_code:-unknown}"
    echo "  Kubelet Status: ${kubelet_status:-unknown}"
    echo "  API Responsive: ${api_responsive:-unknown}"
    echo "Cleanup Test:"
    echo "  Status: ${cleanup_status:-unknown}"
    echo "  Exit Code: ${cleanup_exit_code:-unknown}"
    echo "  Services Stopped: ${services_stopped:-unknown}"
    echo "  Config Cleaned: ${config_cleaned:-unknown}"
    echo "  Packages Removed: ${packages_removed:-unknown}"
    echo "=================="

    if [ "$overall_status" = "success" ]; then
        log_success "Test PASSED for $distro (both setup and cleanup succeeded)"
        return 0
    else
        if [ "$setup_status" != "success" ]; then
            log_error "Setup test FAILED for $distro"
        fi
        if [ "$cleanup_status" != "success" ] && [ "$cleanup_status" != "skipped" ]; then
            log_error "Cleanup test FAILED for $distro"
        fi
        log_error "Test FAILED for $distro"
        return 1
    fi
}

# Test all distributions
test_all() {
    log_info "Starting test for all distributions"
    log_info "Test mode: $TEST_MODE"
    if [ "$TEST_MODE" = "online" ]; then
        log_info "Script source: GitHub (https://raw.github.com/MuNeNICK/setup-k8s/main/)"
    else
        log_info "Script source: Bundled (all modules included)"
    fi

    # Get all distributions
    local distros=("${SUPPORTED_DISTROS[@]}")
    local total=${#distros[@]}
    local passed=0
    local failed=0
    local current=0

    # Create summary log file
    local summary_file="results/test-all-summary-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p results

    echo "Testing $total distributions in $TEST_MODE mode" | tee "$summary_file"
    echo "===================" | tee -a "$summary_file"
    echo "Start time: $(date)" | tee -a "$summary_file"
    echo "" | tee -a "$summary_file"

    for distro in "${distros[@]}"; do
        current=$((current + 1))
        echo "" | tee -a "$summary_file"
        echo -e "${BLUE}[$current/$total] Testing: $distro${NC}" | tee -a "$summary_file"
        echo "-----------------------------------" | tee -a "$summary_file"

        local start_time=$(date +%s)

        if run_single_test "$distro"; then
            passed=$((passed + 1))
            local status="PASSED"
        else
            failed=$((failed + 1))
            local status="FAILED"
        fi

        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        echo "$distro: $status (${duration}s)" | tee -a "$summary_file"

        # Add individual test result details to summary
        if [ -f "results/test-result.json" ]; then
            echo "  Details from test-result.json:" >> "$summary_file"
            local s_status="" c_status=""
            if command -v jq &>/dev/null; then
                s_status=$(jq -r '.setup_test.status // "unknown"' results/test-result.json)
                c_status=$(jq -r '.cleanup_test.status // "unknown"' results/test-result.json)
            else
                s_status=$(grep -A5 '"setup_test"' results/test-result.json | grep '"status"' | head -1 | cut -d'"' -f4)
                c_status=$(grep -A5 '"cleanup_test"' results/test-result.json | grep '"status"' | head -1 | cut -d'"' -f4)
            fi
            echo "    Setup: $s_status, Cleanup: $c_status" >> "$summary_file"
        fi
    done

    # Summary
    echo "" | tee -a "$summary_file"
    echo -e "${BLUE}===== Test Summary =====${NC}" | tee -a "$summary_file"
    echo "Total: $total, Passed: $passed, Failed: $failed" | tee -a "$summary_file"
    echo "End time: $(date)" | tee -a "$summary_file"
    echo "" | tee -a "$summary_file"

    # List all individual log files
    echo "Individual test logs:" | tee -a "$summary_file"
    ls -la results/logs/*.log 2>/dev/null | tail -n +2 | awk '{print "  " $9}' | tee -a "$summary_file"

    echo "" | tee -a "$summary_file"
    echo "Summary saved to: $summary_file"

    if [ $failed -gt 0 ]; then
        log_error "Some tests failed. Check $summary_file and results/logs/ for details"
        return 1
    else
        log_success "All tests passed!"
        return 0
    fi
}

# Run single test
run_single_test() {
    local distro=$1

    log_info "Starting K8s test for: $distro"
    log_info "Test mode: $TEST_MODE"
    if [ "$TEST_MODE" = "online" ]; then
        log_info "Script source: GitHub (https://raw.github.com/MuNeNICK/setup-k8s/main/)"
    else
        log_info "Script source: Bundled (all modules included)"
    fi
    if [ -n "$K8S_VERSION" ]; then
        log_info "Kubernetes version: $K8S_VERSION"
    else
        log_info "Kubernetes version: default (from setup-k8s.sh)"
    fi
    log_info "Working directory: $SCRIPT_DIR"

    # Resolve K8S_VERSION on host if not provided
    local k8s_version_arg=""
    local setup_extra_args_str=""
    if [ -z "$K8S_VERSION" ]; then
        log_info "Resolving latest stable Kubernetes minor on host..."
        local stable_txt
        stable_txt=$(curl -fsSL --retry 3 --retry-delay 2 https://dl.k8s.io/release/stable.txt 2>/dev/null || true)
        if echo "$stable_txt" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
            K8S_VERSION=$(echo "$stable_txt" | sed -E 's/^v([0-9]+\.[0-9]+)\..*/\1/')
            log_success "Detected stable minor: $K8S_VERSION"
        else
            K8S_VERSION="1.32"
            log_warn "Failed to detect stable version; falling back to $K8S_VERSION"
        fi
    fi
    if [ -n "$K8S_VERSION" ]; then
        k8s_version_arg="--kubernetes-version $K8S_VERSION"
        log_info "Using Kubernetes version: $K8S_VERSION"
    fi
    if [ ${#SETUP_EXTRA_ARGS[@]} -gt 0 ]; then
        setup_extra_args_str="${SETUP_EXTRA_ARGS[*]}"
        log_info "Passing extra setup args: $setup_extra_args_str"
    fi

    # Execute each step
    load_config "$distro" || return 1
    prepare_vm_runner_environment || return 1
    run_vm_container "$distro" "$k8s_version_arg" "$setup_extra_args_str" || return 1

    # Display results and return status
    if show_test_results "$distro"; then
        return 0
    else
        return 1
    fi
}

# Main process
main() {
    local run_all=false
    local distro=""

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            --all|-a)
                run_all=true
                shift
                ;;
            --k8s-version)
                K8S_VERSION="$2"
                shift 2
                ;;
            --online)
                TEST_MODE="online"
                shift
                ;;
            --offline)
                TEST_MODE="offline"
                shift
                ;;
            --memory)
                VM_MEMORY="$2"
                shift 2
                ;;
            --cpus)
                VM_CPUS="$2"
                shift 2
                ;;
            --disk-size)
                VM_DISK_SIZE="$2"
                shift 2
                ;;
            --setup-args)
                # Split quoted string into array
                IFS=' ' read -r -a SETUP_EXTRA_ARGS <<< "$2"
                shift 2
                ;;
            --)
                shift
                # Everything after -- goes into SETUP_EXTRA_ARGS as-is
                while [[ $# -gt 0 ]]; do
                    SETUP_EXTRA_ARGS+=("$1")
                    shift
                done
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                # This should be the distribution name
                distro=$1
                shift
                ;;
        esac
    done

    # Check if we should run all tests
    if [ "$run_all" = true ]; then
        test_all
        exit $?
    fi

    # Check arguments for single test
    if [ -z "$distro" ]; then
        log_error "Distribution name required"
        show_help
        exit 1
    fi

    # Run single test
    if run_single_test "$distro"; then
        exit 0
    else
        exit 1
    fi
}

# Execute script
main "$@"
