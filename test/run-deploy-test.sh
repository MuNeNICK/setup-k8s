#!/bin/bash
#
# Deploy Subcommand E2E Test via docker-vm-runner
# Usage: ./test/run-deploy-test.sh [--distro <name>] [--k8s-version <ver>]
#
# Scenario: Single CP + Single Worker (key-based SSH)
#
# Tests:
#   1. setup-k8s.sh deploy completes successfully (exit 0)
#   2. CP: kubelet is active
#   3. CP: /etc/kubernetes/admin.conf exists
#   4. CP: kubectl get nodes responds
#   5. Total node count = 2 (1 CP + 1 Worker)
#   6. Worker: kubelet is active
#
# Test matrix (combine with --cri / --proxy-mode flags):
#   ./run-deploy-test.sh                                    # default (containerd + iptables)
#   ./run-deploy-test.sh --cri crio                         # CRI-O runtime
#   ./run-deploy-test.sh --proxy-mode ipvs                  # IPVS proxy mode
#   ./run-deploy-test.sh --proxy-mode nftables              # nftables proxy mode
#   ./run-deploy-test.sh --cri crio --proxy-mode ipvs       # CRI-O + IPVS
#

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
K8S_VERSION=""
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CPUS="${VM_CPUS:-2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
DEPLOY_CRI=""
DEPLOY_PROXY_MODE=""

TIMEOUT_TOTAL=1200
SSH_READY_TIMEOUT=300

# Docker network for VM-to-VM communication (overridable via environment)
DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-deploy-net-$$}"
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
Deploy Subcommand E2E Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: $DISTRO)
  --k8s-version <ver>     Kubernetes version (e.g., 1.32)
  --cri <runtime>         Container runtime: containerd or crio
  --proxy-mode <mode>     Proxy mode: iptables, ipvs, or nftables
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message
EOF
}

# --- VM infrastructure ---

setup_docker_network() {
    log_info "Creating Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    # Remove stale network if exists
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

# Start a VM container with static IP on the Docker network
# Usage: start_vm <container_name> <static_ip> <host_ssh_port> <data_subdir>
start_vm() {
    local container_name=$1 static_ip=$2 host_ssh_port=$3 data_subdir=$4

    local vm_data_dir="$VM_DATA_DIR/$data_subdir"
    mkdir -p "$vm_data_dir"

    log_info "Starting VM: $container_name (IP: $static_ip, SSH port: $host_ssh_port)"
    docker run -d --rm \
        --name "$container_name" \
        --label "managed-by=k8s-deploy-test" \
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

# Wait for cloud-init + SSH to become ready on a VM
# Usage: wait_for_vm_ready <container_name> <host_ssh_port> <label>
wait_for_vm_ready() {
    local container_name=$1 host_ssh_port=$2 label=$3
    wait_for_cloud_init "$container_name" "$SSH_READY_TIMEOUT" "$label" || return 1
    wait_for_ssh "$host_ssh_port" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "$label" || return 1
}

# Setup root SSH access on a VM (copy user's authorized_keys to root)
# Usage: setup_root_ssh <host_ssh_port> <label>
setup_root_ssh() {
    local host_ssh_port=$1 label=$2

    log_info "[$label] Setting up root SSH access..."
    ssh "${SSH_OPTS[@]}" -p "$host_ssh_port" "$LOGIN_USER@localhost" \
        "sudo mkdir -p /root/.ssh && sudo cp ~/.ssh/authorized_keys /root/.ssh/ && sudo chmod 700 /root/.ssh && sudo chmod 600 /root/.ssh/authorized_keys" >/dev/null 2>&1

    # Verify root SSH works
    if ssh "${SSH_OPTS[@]}" -p "$host_ssh_port" "root@localhost" "echo ok" >/dev/null 2>&1; then
        log_success "[$label] Root SSH access ready"
    else
        log_error "[$label] Root SSH access failed"
        return 1
    fi
}

# SSH to a VM via Docker IP as root (through another VM)
# Usage: vm_ssh_via_docker <host_ssh_port> <command...>
vm_ssh_root() {
    local port=$1; shift
    ssh "${SSH_OPTS[@]}" -p "$port" "root@localhost" "$@"
}

# --- Main test logic ---

run_deploy_test() {
    local ts
    ts=$(date +%s)
    local cp_container="k8s-deploy-cp-${DISTRO}-${ts}"
    local worker_container="k8s-deploy-w-${DISTRO}-${ts}"
    local log_file
    log_file="results/logs/deploy-${DISTRO}-$(date +%Y%m%d-%H%M%S).log"

    log_info "=== Deploy Subcommand E2E Test ==="
    log_info "Distribution: $DISTRO"
    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    log_info "Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    log_info "CP: $CP_DOCKER_IP, Worker: $WORKER_DOCKER_IP"
    mkdir -p results/logs "$VM_DATA_DIR"

    # Clean up orphaned containers from previous runs
    cleanup_orphaned_containers "k8s-deploy-test"

    trap '_cleanup_all' EXIT INT TERM HUP

    # --- Step 1: Setup infrastructure ---
    setup_docker_network
    setup_ssh_key

    _CP_SSH_PORT=$(find_free_port)
    _WORKER_SSH_PORT=$(find_free_port)

    # --- Step 2: Start VMs ---
    start_vm "$cp_container" "$CP_DOCKER_IP" "$_CP_SSH_PORT" "cp"
    _CP_CONTAINER_NAME="$cp_container"
    _CP_WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$cp_container")

    start_vm "$worker_container" "$WORKER_DOCKER_IP" "$_WORKER_SSH_PORT" "worker"
    _WORKER_CONTAINER_NAME="$worker_container"
    _WORKER_WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$worker_container")

    # --- Step 3: Wait for VMs to be ready ---
    wait_for_vm_ready "$cp_container" "$_CP_SSH_PORT" "CP"
    wait_for_vm_ready "$worker_container" "$_WORKER_SSH_PORT" "Worker"

    # --- Step 4: Setup root SSH on all VMs ---
    setup_root_ssh "$_CP_SSH_PORT" "CP"
    setup_root_ssh "$_WORKER_SSH_PORT" "Worker"

    # --- Step 5: Resolve K8s version ---
    resolve_k8s_version || return 1

    # --- Step 6: Run deploy ---
    log_info "=== Running deploy ==="
    local deploy_cmd=(
        bash "$SETUP_K8S_SCRIPT" deploy
        --control-planes "$CP_DOCKER_IP"
        --workers "$WORKER_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --kubernetes-version "$K8S_VERSION"
        --control-plane-endpoint "${CP_DOCKER_IP}:6443"
    )
    [ -n "$DEPLOY_CRI" ] && deploy_cmd+=(--cri "$DEPLOY_CRI")
    [ -n "$DEPLOY_PROXY_MODE" ] && deploy_cmd+=(--proxy-mode "$DEPLOY_PROXY_MODE")
    log_info "Command: ${deploy_cmd[*]}"

    local deploy_exit_code=0
    if timeout "$TIMEOUT_TOTAL" "${deploy_cmd[@]}" 2>&1 | tee "$log_file"; then
        deploy_exit_code=0
    else
        deploy_exit_code=$?
        if [ "$deploy_exit_code" -eq 124 ]; then
            log_error "Deploy command timed out after ${TIMEOUT_TOTAL}s"
            log_info "=== TIMEOUT DIAGNOSTICS ==="
            log_info "CP container status:"
            docker inspect --format='{{.State.Status}}' "$cp_container" 2>/dev/null || true
            log_info "Worker container status:"
            docker inspect --format='{{.State.Status}}' "$worker_container" 2>/dev/null || true
            log_info "=== END TIMEOUT DIAGNOSTICS ==="
        fi
    fi

    # ===================================================================
    # Verification
    # ===================================================================
    log_info "=== Verification ==="

    local all_pass=true

    # Check 1: deploy exit code = 0
    if [ "$deploy_exit_code" -eq 0 ]; then
        log_success "CHECK 1: deploy exit code = 0"
    else
        log_error "CHECK 1: deploy exit code = $deploy_exit_code"
        all_pass=false
    fi

    # Check 2: CP kubelet active
    local kubelet_status
    kubelet_status=$(vm_ssh_root "$_CP_SSH_PORT" "systemctl is-active kubelet" 2>/dev/null | tr -d '[:space:]') || kubelet_status="inactive"
    if [ "$kubelet_status" = "active" ]; then
        log_success "CHECK 2: CP kubelet is active"
    else
        log_error "CHECK 2: CP kubelet is $kubelet_status"
        all_pass=false
    fi

    # Check 3: CP admin.conf exists
    if vm_ssh_root "$_CP_SSH_PORT" "test -f /etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK 3: CP admin.conf exists"
    else
        log_error "CHECK 3: CP admin.conf NOT found"
        all_pass=false
    fi

    # Check 4: CP API server responsive
    if vm_ssh_root "$_CP_SSH_PORT" "timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK 4: CP API server responsive"
    else
        log_error "CHECK 4: CP API server NOT responsive"
        all_pass=false
    fi

    # Check 5: Node count = 2
    local node_count
    node_count=$(vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes --no-headers --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]') || node_count="0"
    if [ "$node_count" -eq 2 ]; then
        log_success "CHECK 5: Node count = $node_count (expected 2)"
    else
        log_error "CHECK 5: Node count = $node_count (expected 2)"
        all_pass=false
    fi

    # Check 6: Worker kubelet active
    local worker_kubelet
    worker_kubelet=$(vm_ssh_root "$_WORKER_SSH_PORT" "systemctl is-active kubelet" 2>/dev/null | tr -d '[:space:]') || worker_kubelet="inactive"
    if [ "$worker_kubelet" = "active" ]; then
        log_success "CHECK 6: Worker kubelet is active"
    else
        log_error "CHECK 6: Worker kubelet is $worker_kubelet"
        all_pass=false
    fi

    # Show node list for debugging
    log_info "Node status:"
    vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true

    # ===================================================================
    # Result
    # ===================================================================
    echo ""
    log_info "Log file: $log_file"
    if [ "$all_pass" = true ]; then
        log_success "=== DEPLOY TEST PASSED ==="
        _cleanup_all
        trap - EXIT INT TERM HUP
        return 0
    else
        log_error "=== DEPLOY TEST FAILED ==="
        log_info "=== DIAGNOSTICS ==="
        log_info "CP container logs (last 20 lines):"
        docker logs "$cp_container" 2>&1 | tail -20 || true
        log_info "Worker container logs (last 20 lines):"
        docker logs "$worker_container" 2>&1 | tail -20 || true
        log_info "CP listening ports:"
        vm_ssh_root "$_CP_SSH_PORT" "ss -tlnp | grep -E '6443|10250'" 2>/dev/null || true
        log_info "Worker listening ports:"
        vm_ssh_root "$_WORKER_SSH_PORT" "ss -tlnp | grep -E '6443|10250'" 2>/dev/null || true
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
        --k8s-version) _require_arg $# "$1"; K8S_VERSION="$2"; shift 2 ;;
        --cri) _require_arg $# "$1"; DEPLOY_CRI="$2"; shift 2 ;;
        --proxy-mode) _require_arg $# "$1"; DEPLOY_PROXY_MODE="$2"; shift 2 ;;
        --memory) _require_arg $# "$1"; VM_MEMORY="$2"; shift 2 ;;
        --cpus) _require_arg $# "$1"; VM_CPUS="$2"; shift 2 ;;
        --disk-size) _require_arg $# "$1"; VM_DISK_SIZE="$2"; shift 2 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_deploy_test; then
    exit 0
else
    exit 1
fi
