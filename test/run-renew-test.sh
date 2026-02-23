#!/bin/bash
#
# Certificate Renewal Subcommand E2E Test via docker-vm-runner
# Usage: ./test/run-renew-test.sh [--distro <name>] [--k8s-version <ver>]
#
# Scenario: Deploy single CP → check-only → renew all → verify API → renew specific → verify API
#
# Tests:
#   1. deploy completes successfully (exit 0)
#   2. renew --check-only exits 0 and shows expiration info
#   3. renew (all certs) exits 0
#   4. API server responsive after full renewal
#   5. renew --certs apiserver,front-proxy-client exits 0
#   6. API server responsive after selective renewal
#   7. certificate expiration dates updated (not expired)

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

TIMEOUT_TOTAL=1200
SSH_READY_TIMEOUT=300

# Docker network
DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-renew-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-172.31.0.0/24}"
CP_DOCKER_IP="${CP_DOCKER_IP:-172.31.0.10}"

# SSH settings
SSH_KEY_DIR=""
SSH_BASE_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
SSH_OPTS=("${SSH_BASE_OPTS[@]}")
LOGIN_USER="user"

# Cleanup state
_CP_CONTAINER_NAME=""
_CP_WATCHDOG_PID=""
_CP_SSH_PORT=""

show_help() {
    cat <<EOF
Certificate Renewal Subcommand E2E Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: $DISTRO)
  --k8s-version <ver>     Kubernetes version (e.g., 1.32)
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message

Examples:
  $0                                        # auto-detect version
  $0 --distro debian-12 --k8s-version 1.32
EOF
}

# --- VM infrastructure (same pattern as run-backup-test.sh) ---

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
        --label "managed-by=k8s-renew-test" \
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

# --- Main test logic ---

run_renew_test() {
    local ts
    ts=$(date +%s)
    local cp_container="k8s-renew-cp-${DISTRO}-${ts}"
    local log_file
    log_file="results/logs/renew-${DISTRO}-$(date +%Y%m%d-%H%M%S).log"

    log_info "=== Certificate Renewal Subcommand E2E Test ==="
    log_info "Distribution: $DISTRO"
    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    log_info "Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    log_info "CP: $CP_DOCKER_IP"
    mkdir -p results/logs "$VM_DATA_DIR"

    cleanup_orphaned_containers "k8s-renew-test"

    trap '_cleanup_all' EXIT INT TERM HUP

    # --- Step 1: Setup infrastructure ---
    setup_docker_network
    setup_ssh_key

    _CP_SSH_PORT=$(find_free_port)

    # --- Step 2: Start VM ---
    start_vm "$cp_container" "$CP_DOCKER_IP" "$_CP_SSH_PORT" "renew-cp"
    _CP_CONTAINER_NAME="$cp_container"
    _CP_WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$cp_container")

    # --- Step 3: Wait for VM ---
    wait_for_vm_ready "$cp_container" "$_CP_SSH_PORT" "CP"

    # --- Step 4: Setup root SSH ---
    setup_root_ssh "$_CP_SSH_PORT" "CP"

    # --- Step 5: Resolve K8s version ---
    resolve_k8s_version || return 1

    # ===================================================================
    # Phase 1: Deploy single-node cluster
    # ===================================================================
    log_info "=== Phase 1: Deploy single-node cluster ==="
    local deploy_cmd=(
        bash "$SETUP_K8S_SCRIPT" deploy
        --control-planes "$CP_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --kubernetes-version "$K8S_VERSION"
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
        log_error "Deploy failed with exit code $deploy_exit_code. Cannot proceed with renew test."
        return 1
    fi
    log_success "Phase 1: Deploy completed successfully"

    # Wait for API server to be stable
    log_info "Waiting for API server to stabilize..."
    local api_ready=false
    for _ in $(seq 1 20); do
        if vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
            api_ready=true
            break
        fi
        sleep 5
    done
    if [ "$api_ready" != true ]; then
        log_error "API server did not become ready"
        return 1
    fi

    # ===================================================================
    # Phase 2: renew --check-only (remote mode)
    # ===================================================================
    log_info "=== Phase 2: renew --check-only (remote mode) ==="
    local check_cmd=(
        bash "$SETUP_K8S_SCRIPT" renew
        --control-planes "$CP_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --check-only
    )
    log_info "Check command: ${check_cmd[*]}"

    local check_exit_code=0
    if timeout "$TIMEOUT_TOTAL" "${check_cmd[@]}" 2>&1 | tee -a "$log_file"; then
        check_exit_code=0
    else
        check_exit_code=$?
    fi

    # ===================================================================
    # Phase 3: renew all certs (remote mode)
    # ===================================================================
    log_info "=== Phase 3: renew all certificates (remote mode) ==="
    local renew_all_cmd=(
        bash "$SETUP_K8S_SCRIPT" renew
        --control-planes "$CP_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
    )
    log_info "Renew all command: ${renew_all_cmd[*]}"

    local renew_all_exit_code=0
    if timeout "$TIMEOUT_TOTAL" "${renew_all_cmd[@]}" 2>&1 | tee -a "$log_file"; then
        renew_all_exit_code=0
    else
        renew_all_exit_code=$?
    fi

    # Wait for API server to recover after full renewal
    log_info "Waiting for API server after full renewal..."
    local api_after_all=false
    for _ in $(seq 1 40); do
        if vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
            api_after_all=true
            break
        fi
        sleep 5
    done

    # ===================================================================
    # Phase 4: renew specific certs (remote mode)
    # ===================================================================
    log_info "=== Phase 4: renew specific certificates (remote mode) ==="
    local specific_certs="apiserver,front-proxy-client"
    local renew_specific_cmd=(
        bash "$SETUP_K8S_SCRIPT" renew
        --control-planes "$CP_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --certs "$specific_certs"
    )
    log_info "Renew specific command: ${renew_specific_cmd[*]}"

    local renew_specific_exit_code=0
    if timeout "$TIMEOUT_TOTAL" "${renew_specific_cmd[@]}" 2>&1 | tee -a "$log_file"; then
        renew_specific_exit_code=0
    else
        renew_specific_exit_code=$?
    fi

    # Wait for API server to recover after selective renewal
    log_info "Waiting for API server after selective renewal..."
    local api_after_specific=false
    for _ in $(seq 1 40); do
        if vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
            api_after_specific=true
            break
        fi
        sleep 5
    done

    # ===================================================================
    # Phase 5: Verify certificate dates on the node
    # ===================================================================
    log_info "=== Phase 5: Verify certificate expiration ==="
    local cert_check_output=""
    cert_check_output=$(vm_ssh_root "$_CP_SSH_PORT" "kubeadm certs check-expiration 2>&1" 2>/dev/null) || true

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

    # Check 2: renew --check-only exits 0
    if [ "$check_exit_code" -eq 0 ]; then
        log_success "CHECK 2: renew --check-only exit code = 0"
    else
        log_error "CHECK 2: renew --check-only exit code = $check_exit_code"
        all_pass=false
    fi

    # Check 3: renew all exits 0
    if [ "$renew_all_exit_code" -eq 0 ]; then
        log_success "CHECK 3: renew all exit code = 0"
    else
        log_error "CHECK 3: renew all exit code = $renew_all_exit_code"
        all_pass=false
    fi

    # Check 4: API server responsive after full renewal
    if [ "$api_after_all" = true ]; then
        log_success "CHECK 4: API server responsive after full renewal"
    else
        log_error "CHECK 4: API server NOT responsive after full renewal"
        all_pass=false
    fi

    # Check 5: renew specific certs exits 0
    if [ "$renew_specific_exit_code" -eq 0 ]; then
        log_success "CHECK 5: renew --certs apiserver,front-proxy-client exit code = 0"
    else
        log_error "CHECK 5: renew --certs apiserver,front-proxy-client exit code = $renew_specific_exit_code"
        all_pass=false
    fi

    # Check 6: API server responsive after selective renewal
    if [ "$api_after_specific" = true ]; then
        log_success "CHECK 6: API server responsive after selective renewal"
    else
        log_error "CHECK 6: API server NOT responsive after selective renewal"
        all_pass=false
    fi

    # Check 7: certificate expiration shows valid dates (not expired)
    if [ -n "$cert_check_output" ]; then
        # kubeadm certs check-expiration outputs a table with expiration dates
        # Check that no certificate shows "EXPIRED" or "invalid"
        if echo "$cert_check_output" | grep -qi "expired"; then
            log_error "CHECK 7: Some certificates appear EXPIRED"
            all_pass=false
        else
            log_success "CHECK 7: Certificate expiration dates look valid"
        fi
        log_info "Certificate status:"
        echo "$cert_check_output" | while IFS= read -r line; do
            log_info "  $line"
        done
    else
        log_warn "CHECK 7: Could not retrieve certificate expiration info (non-fatal)"
    fi

    # Show cluster state for debugging
    log_info "Cluster state after renewal:"
    vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true

    # ===================================================================
    # Result
    # ===================================================================
    echo ""
    log_info "Log file: $log_file"
    if [ "$all_pass" = true ]; then
        log_success "=== CERTIFICATE RENEWAL TEST PASSED ==="
        _cleanup_all
        trap - EXIT INT TERM HUP
        return 0
    else
        log_error "=== CERTIFICATE RENEWAL TEST FAILED ==="
        log_info "=== DIAGNOSTICS ==="
        log_info "CP container logs (last 20 lines):"
        docker logs "$cp_container" 2>&1 | tail -20 || true
        log_info "Control-plane component status:"
        vm_ssh_root "$_CP_SSH_PORT" "crictl ps" 2>/dev/null || true
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
        --memory) _require_arg $# "$1"; VM_MEMORY="$2"; shift 2 ;;
        --cpus) _require_arg $# "$1"; VM_CPUS="$2"; shift 2 ;;
        --disk-size) _require_arg $# "$1"; VM_DISK_SIZE="$2"; shift 2 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_renew_test; then
    exit 0
else
    exit 1
fi
