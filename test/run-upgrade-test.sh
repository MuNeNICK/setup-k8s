#!/bin/bash
#
# Upgrade Subcommand E2E Test via docker-vm-runner
# Usage: ./test/run-upgrade-test.sh [--distro <name>] [--from-version <ver>] [--to-version <ver>]
#
# Scenario: Deploy cluster with --from-version, then upgrade to --to-version
#
# Tests:
#   1. deploy completes successfully (exit 0)
#   2. upgrade completes successfully (exit 0)
#   3. CP: kubeadm version matches target
#   4. CP: kubelet version matches target
#   5. Worker: kubelet version matches target
#   6. CP: kubectl get nodes responds
#   7. Node count = 2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/vm_harness.sh
source "$SCRIPT_DIR/lib/vm_harness.sh"

PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_K8S_SCRIPT="$PROJECT_ROOT/setup-k8s.sh"
DOCKER_VM_RUNNER_IMAGE="${DOCKER_VM_RUNNER_IMAGE:-ghcr.io/munenick/docker-vm-runner:latest}"
VM_DATA_DIR="${VM_DATA_DIR:-$SCRIPT_DIR/data}"

# Defaults
DISTRO="${DISTRO:-ubuntu-2404}"
FROM_VERSION=""  # MAJOR.MINOR for deploy (e.g., 1.32)
TO_VERSION=""    # MAJOR.MINOR.PATCH for upgrade (e.g., 1.33.2)
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CPUS="${VM_CPUS:-2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"

TIMEOUT_TOTAL=1200
SSH_READY_TIMEOUT=300

# Docker network
DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-upgrade-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-172.30.0.0/24}"
CP_DOCKER_IP="${CP_DOCKER_IP:-172.30.0.10}"
WORKER_DOCKER_IP="${WORKER_DOCKER_IP:-172.30.0.20}"

# SSH settings
SSH_KEY_DIR=""
SSH_BASE_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
SSH_OPTS=("${SSH_BASE_OPTS[@]}")
LOGIN_USER="user"

# Cleanup state
_CP_CONTAINER_NAME=""
_WORKER_CONTAINER_NAME=""
_CP_WATCHDOG_PID=""
_WORKER_WATCHDOG_PID=""
_CP_SSH_PORT=""
_WORKER_SSH_PORT=""

show_help() {
    cat <<EOF
Upgrade Subcommand E2E Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: $DISTRO)
  --from-version <ver>    Initial K8s version MAJOR.MINOR (e.g., 1.32)
  --to-version <ver>      Target K8s version MAJOR.MINOR.PATCH (e.g., 1.33.2)
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message

If --from-version / --to-version are not specified, the script resolves the
latest stable version and upgrades from the previous minor version's latest patch.

Examples:
  $0                                                  # auto-detect versions
  $0 --from-version 1.32 --to-version 1.33.2          # explicit versions
  $0 --distro debian-12 --from-version 1.32 --to-version 1.33.2
EOF
}

# --- VM infrastructure (same pattern as run-deploy-test.sh) ---

setup_docker_network() {
    log_info "Creating Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true
    docker network create --subnet "$DOCKER_SUBNET" "$DOCKER_NETWORK" >/dev/null
    log_success "Docker network created"
}

cleanup_docker_network() {
    if docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
        log_info "Removing Docker network: $DOCKER_NETWORK"
        docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true
    fi
}

_cleanup_all() {
    _cleanup_vm_container "$_CP_WATCHDOG_PID" "$_CP_CONTAINER_NAME"
    _CP_WATCHDOG_PID=""
    _CP_CONTAINER_NAME=""
    _cleanup_vm_container "$_WORKER_WATCHDOG_PID" "$_WORKER_CONTAINER_NAME"
    _WORKER_WATCHDOG_PID=""
    _WORKER_CONTAINER_NAME=""
    cleanup_docker_network
    cleanup_ssh_key
}

start_vm() {
    local container_name=$1 static_ip=$2 host_ssh_port=$3 data_subdir=$4

    local vm_data_dir="$VM_DATA_DIR/$data_subdir"
    mkdir -p "$vm_data_dir"

    log_info "Starting VM: $container_name (IP: $static_ip, SSH port: $host_ssh_port)"
    docker run -d --rm \
        --name "$container_name" \
        --label "managed-by=k8s-upgrade-test" \
        --network "$DOCKER_NETWORK" --ip "$static_ip" \
        --device /dev/kvm:/dev/kvm \
        -v "$vm_data_dir:/data" \
        -p "${host_ssh_port}:2222" \
        -e "DISTRO=$DISTRO" \
        -e "GUEST_NAME=$container_name" \
        -e "SSH_PUBKEY=$(cat "$SSH_KEY_DIR/id_test.pub")" \
        -e "PORT_FWD=6443:6443,10250:10250" \
        -e "NO_CONSOLE=1" \
        -e "MEMORY=$VM_MEMORY" \
        -e "CPUS=$VM_CPUS" \
        -e "DISK_SIZE=$VM_DISK_SIZE" \
        "$DOCKER_VM_RUNNER_IMAGE" >/dev/null
    log_success "Container $container_name started"
}

wait_for_vm_ready() {
    local container_name=$1 host_ssh_port=$2 label=$3
    wait_for_cloud_init "$container_name" "$SSH_READY_TIMEOUT" "$label" || return 1
    wait_for_ssh "$host_ssh_port" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "$label" || return 1
}

setup_root_ssh() {
    local host_ssh_port=$1 label=$2

    log_info "[$label] Setting up root SSH access..."
    ssh "${SSH_OPTS[@]}" -p "$host_ssh_port" "$LOGIN_USER@localhost" \
        "sudo mkdir -p /root/.ssh && sudo cp ~/.ssh/authorized_keys /root/.ssh/ && sudo chmod 700 /root/.ssh && sudo chmod 600 /root/.ssh/authorized_keys" >/dev/null 2>&1

    if ssh "${SSH_OPTS[@]}" -p "$host_ssh_port" "root@localhost" "echo ok" >/dev/null 2>&1; then
        log_success "[$label] Root SSH access ready"
    else
        log_error "[$label] Root SSH access failed"
        return 1
    fi
}

vm_ssh_root() {
    local port=$1; shift
    ssh "${SSH_OPTS[@]}" -p "$port" "root@localhost" "$@"
}

# --- Version resolution ---

# Resolve FROM and TO versions automatically if not set.
# FROM = previous stable minor, TO = current stable latest patch
resolve_upgrade_versions() {
    if [ -n "$FROM_VERSION" ] && [ -n "$TO_VERSION" ]; then
        log_info "Using explicit versions: $FROM_VERSION -> $TO_VERSION"
        return 0
    fi

    log_info "Resolving Kubernetes versions for upgrade test..."
    local stable_txt
    if ! stable_txt=$(curl -fsSL --retry 3 --retry-delay 2 https://dl.k8s.io/release/stable.txt); then
        log_error "Failed to fetch stable Kubernetes version"
        return 1
    fi
    # stable_txt = e.g. "v1.33.2"
    if ! echo "$stable_txt" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
        log_error "Unexpected response from dl.k8s.io: $stable_txt"
        return 1
    fi

    local full_ver
    full_ver=$(echo "$stable_txt" | sed 's/^v//')
    local major minor patch
    major=$(echo "$full_ver" | cut -d. -f1)
    minor=$(echo "$full_ver" | cut -d. -f2)
    patch=$(echo "$full_ver" | cut -d. -f3)

    if [ -z "$TO_VERSION" ]; then
        TO_VERSION="${major}.${minor}.${patch}"
    fi

    if [ -z "$FROM_VERSION" ]; then
        local prev_minor=$((minor - 1))
        FROM_VERSION="${major}.${prev_minor}"
    fi

    log_success "Upgrade path: ${FROM_VERSION} -> ${TO_VERSION}"
}

# --- Main test logic ---

run_upgrade_test() {
    local ts
    ts=$(date +%s)
    local cp_container="k8s-upgrade-cp-${DISTRO}-${ts}"
    local worker_container="k8s-upgrade-w-${DISTRO}-${ts}"
    local log_file
    log_file="results/logs/upgrade-${DISTRO}-$(date +%Y%m%d-%H%M%S).log"

    log_info "=== Upgrade Subcommand E2E Test ==="
    log_info "Distribution: $DISTRO"
    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    log_info "Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    log_info "CP: $CP_DOCKER_IP, Worker: $WORKER_DOCKER_IP"
    mkdir -p results/logs "$VM_DATA_DIR"

    cleanup_orphaned_containers "k8s-upgrade-test"

    trap '_cleanup_all' EXIT INT TERM HUP

    # --- Step 1: Resolve versions ---
    resolve_upgrade_versions || return 1
    log_info "Upgrade path: v${FROM_VERSION} -> v${TO_VERSION}"

    # --- Step 2: Setup infrastructure ---
    setup_docker_network
    setup_ssh_key

    _CP_SSH_PORT=$(find_free_port)
    _WORKER_SSH_PORT=$(find_free_port)

    # --- Step 3: Start VMs ---
    start_vm "$cp_container" "$CP_DOCKER_IP" "$_CP_SSH_PORT" "upgrade-cp"
    _CP_CONTAINER_NAME="$cp_container"
    _CP_WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$cp_container")

    start_vm "$worker_container" "$WORKER_DOCKER_IP" "$_WORKER_SSH_PORT" "upgrade-worker"
    _WORKER_CONTAINER_NAME="$worker_container"
    _WORKER_WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$worker_container")

    # --- Step 4: Wait for VMs ---
    wait_for_vm_ready "$cp_container" "$_CP_SSH_PORT" "CP"
    wait_for_vm_ready "$worker_container" "$_WORKER_SSH_PORT" "Worker"

    # --- Step 5: Setup root SSH ---
    setup_root_ssh "$_CP_SSH_PORT" "CP"
    setup_root_ssh "$_WORKER_SSH_PORT" "Worker"

    # ===================================================================
    # Phase 1: Deploy cluster with FROM_VERSION
    # ===================================================================
    log_info "=== Phase 1: Deploy cluster with v${FROM_VERSION} ==="
    local deploy_cmd=(
        bash "$SETUP_K8S_SCRIPT" deploy
        --control-planes "$CP_DOCKER_IP"
        --workers "$WORKER_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --kubernetes-version "$FROM_VERSION"
        --control-plane-endpoint "${CP_DOCKER_IP}:6443"
    )
    log_info "Deploy command: ${deploy_cmd[*]}"

    local deploy_exit_code=0
    if timeout "$TIMEOUT_TOTAL" "${deploy_cmd[@]}" 2>&1 | tee "$log_file"; then
        deploy_exit_code=0
    else
        deploy_exit_code=$?
    fi

    if [ "$deploy_exit_code" -ne 0 ]; then
        log_error "Deploy failed with exit code $deploy_exit_code. Cannot proceed with upgrade test."
        return 1
    fi
    log_success "Phase 1: Deploy completed successfully"

    # Verify deploy baseline
    local pre_version
    pre_version=$(vm_ssh_root "$_CP_SSH_PORT" "kubeadm version -o short" 2>/dev/null | tr -d '[:space:]')
    log_info "Pre-upgrade kubeadm version: $pre_version"

    # ===================================================================
    # Phase 2: Run upgrade
    # ===================================================================
    log_info "=== Phase 2: Upgrade cluster to v${TO_VERSION} ==="
    local upgrade_cmd=(
        bash "$SETUP_K8S_SCRIPT" upgrade
        --control-planes "$CP_DOCKER_IP"
        --workers "$WORKER_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --kubernetes-version "$TO_VERSION"
    )
    log_info "Upgrade command: ${upgrade_cmd[*]}"

    local upgrade_exit_code=0
    if timeout "$TIMEOUT_TOTAL" "${upgrade_cmd[@]}" 2>&1 | tee -a "$log_file"; then
        upgrade_exit_code=0
    else
        upgrade_exit_code=$?
    fi

    # ===================================================================
    # Phase 3: Verification
    # ===================================================================
    log_info "=== Verification ==="

    local all_pass=true
    local target_minor
    target_minor=$(echo "$TO_VERSION" | cut -d. -f1,2)

    # Check 1: deploy exit code
    if [ "$deploy_exit_code" -eq 0 ]; then
        log_success "CHECK 1: deploy exit code = 0"
    else
        log_error "CHECK 1: deploy exit code = $deploy_exit_code"
        all_pass=false
    fi

    # Check 2: upgrade exit code
    if [ "$upgrade_exit_code" -eq 0 ]; then
        log_success "CHECK 2: upgrade exit code = 0"
    else
        log_error "CHECK 2: upgrade exit code = $upgrade_exit_code"
        all_pass=false
    fi

    # Check 3: CP kubeadm version contains target
    local cp_kubeadm_ver
    cp_kubeadm_ver=$(vm_ssh_root "$_CP_SSH_PORT" "kubeadm version -o short" 2>/dev/null | tr -d '[:space:]') || cp_kubeadm_ver="unknown"
    if echo "$cp_kubeadm_ver" | grep -q "v${target_minor}"; then
        log_success "CHECK 3: CP kubeadm version = $cp_kubeadm_ver (contains v${target_minor})"
    else
        log_error "CHECK 3: CP kubeadm version = $cp_kubeadm_ver (expected v${target_minor}.*)"
        all_pass=false
    fi

    # Check 4: CP kubelet version contains target
    local cp_kubelet_ver
    cp_kubelet_ver=$(vm_ssh_root "$_CP_SSH_PORT" "kubelet --version" 2>/dev/null | tr -d '[:space:]') || cp_kubelet_ver="unknown"
    if echo "$cp_kubelet_ver" | grep -q "v${target_minor}"; then
        log_success "CHECK 4: CP kubelet version = $cp_kubelet_ver (contains v${target_minor})"
    else
        log_error "CHECK 4: CP kubelet version = $cp_kubelet_ver (expected v${target_minor}.*)"
        all_pass=false
    fi

    # Check 5: Worker kubelet version contains target
    local worker_kubelet_ver
    worker_kubelet_ver=$(vm_ssh_root "$_WORKER_SSH_PORT" "kubelet --version" 2>/dev/null | tr -d '[:space:]') || worker_kubelet_ver="unknown"
    if echo "$worker_kubelet_ver" | grep -q "v${target_minor}"; then
        log_success "CHECK 5: Worker kubelet version = $worker_kubelet_ver (contains v${target_minor})"
    else
        log_error "CHECK 5: Worker kubelet version = $worker_kubelet_ver (expected v${target_minor}.*)"
        all_pass=false
    fi

    # Check 6: CP API server responsive
    if vm_ssh_root "$_CP_SSH_PORT" "timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK 6: CP API server responsive"
    else
        log_error "CHECK 6: CP API server NOT responsive"
        all_pass=false
    fi

    # Check 7: Node count = 2
    local node_count
    node_count=$(vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes --no-headers --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]') || node_count="0"
    if [ "$node_count" -eq 2 ]; then
        log_success "CHECK 7: Node count = $node_count (expected 2)"
    else
        log_error "CHECK 7: Node count = $node_count (expected 2)"
        all_pass=false
    fi

    # Show node list
    log_info "Node status:"
    vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true

    # ===================================================================
    # Result
    # ===================================================================
    echo ""
    log_info "Log file: $log_file"
    if [ "$all_pass" = true ]; then
        log_success "=== UPGRADE TEST PASSED ==="
        _cleanup_all
        trap - EXIT INT TERM HUP
        return 0
    else
        log_error "=== UPGRADE TEST FAILED ==="
        log_info "=== DIAGNOSTICS ==="
        log_info "CP kubeadm version: $cp_kubeadm_ver"
        log_info "CP kubelet version: $cp_kubelet_ver"
        log_info "Worker kubelet version: $worker_kubelet_ver"
        log_info "CP container logs (last 20 lines):"
        docker logs "$cp_container" 2>&1 | tail -20 || true
        log_info "Worker container logs (last 20 lines):"
        docker logs "$worker_container" 2>&1 | tail -20 || true
        log_info "=== END DIAGNOSTICS ==="
        _cleanup_all
        trap - EXIT INT TERM HUP
        return 1
    fi
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h) show_help; exit 0 ;;
        --distro) _require_arg $# "$1"; DISTRO="$2"; shift 2 ;;
        --from-version) _require_arg $# "$1"; FROM_VERSION="$2"; shift 2 ;;
        --to-version) _require_arg $# "$1"; TO_VERSION="$2"; shift 2 ;;
        --memory) _require_arg $# "$1"; VM_MEMORY="$2"; shift 2 ;;
        --cpus) _require_arg $# "$1"; VM_CPUS="$2"; shift 2 ;;
        --disk-size) _require_arg $# "$1"; VM_DISK_SIZE="$2"; shift 2 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_upgrade_test; then
    exit 0
else
    exit 1
fi
