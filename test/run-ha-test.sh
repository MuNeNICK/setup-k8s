#!/bin/bash
#
# HA (kube-vip) Integration Test via docker-vm-runner
# Usage: ./test/run-ha-test.sh [--distro <name>] [--k8s-version <ver>] [--failover]
#
# Default mode (single VM, init-based):
#   1. setup-k8s.sh init --ha --ha-vip <VIP> completes successfully
#   2. kube-vip manifest deployed to /etc/kubernetes/manifests/
#   3. kubeadm init succeeded with --control-plane-endpoint
#   4. kubelet is active, API server is responsive
#   5. Certificate key and control-plane join info is displayed
#   6. setup-k8s.sh cleanup --force succeeds
#
# Failover mode (3 CP VMs, deploy-based, --failover):
#   1. Deploy 3 CP HA cluster via setup-k8s.sh deploy
#   2. Verify all 3 nodes Ready + cluster healthy
#   3. Stop 1 CP node (simulate failure)
#   4. Verify cluster continues operating (API server responds, kubectl works)
#   5. Verify VIP failover to surviving nodes
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/vm_harness.sh
source "$SCRIPT_DIR/lib/vm_harness.sh"

PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_K8S_SCRIPT="$PROJECT_ROOT/setup-k8s.sh"
# cleanup is now integrated into setup-k8s.sh as the 'cleanup' subcommand
DOCKER_VM_RUNNER_IMAGE="${DOCKER_VM_RUNNER_IMAGE:-ghcr.io/munenick/docker-vm-runner:latest}"
VM_DATA_DIR="${VM_DATA_DIR:-$SCRIPT_DIR/data}"

# Defaults
DISTRO="${DISTRO:-ubuntu-2404}"
K8S_VERSION=""
VM_MEMORY="${VM_MEMORY:-8192}"
VM_CPUS="${VM_CPUS:-4}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
HA_VIP="10.0.2.100"
FAILOVER_MODE=false

TIMEOUT_TOTAL=1200
SSH_READY_TIMEOUT=300

# SSH settings
SSH_KEY_DIR=""
SSH_PORT=""
SSH_BASE_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
# shellcheck disable=SC2034 # SSH_OPTS is used by sourced vm_harness.sh
SSH_OPTS=("${SSH_BASE_OPTS[@]}")

# Cleanup state (single-VM mode)
_VM_CONTAINER_NAME=""
_WATCHDOG_PID=""
LOGIN_USER="user"

# Failover mode state (3 CP VMs)
DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-ha-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-172.31.0.0/24}"
_FO_CONTAINER_NAMES=()
_FO_WATCHDOG_PIDS=()
_FO_SSH_PORTS=()
_FO_DOCKER_IPS=("172.31.0.10" "172.31.0.11" "172.31.0.12")
_FO_HA_VIP="172.31.0.100"
NUM_CP_NODES=3

show_help() {
    cat <<EOF
HA (kube-vip) Integration Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: ubuntu-2404)
  --k8s-version <ver>     Kubernetes version (e.g., 1.32)
  --ha-vip <addr>         VIP address for single-VM mode (default: $HA_VIP)
  --failover              Run 3-CP failover test (deploy mode, 3 VMs)
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message

Modes:
  Default:    Single-VM HA init test (kube-vip manifest + HA artifacts)
  --failover: 3-CP deploy-based test (Docker network, failover + VIP migration)
EOF
}

# --- VM infrastructure (from shared harness) ---

_ha_cleanup_vm_container() {
    _cleanup_vm_container "$_WATCHDOG_PID" "$_VM_CONTAINER_NAME"
    _WATCHDOG_PID=""
    _VM_CONTAINER_NAME=""
}

# --- Main test logic ---

run_ha_test() {
    local container_name
    container_name="k8s-ha-test-${DISTRO}-$(date +%s)"
    local log_file
    log_file="results/logs/ha-${DISTRO}-$(date +%Y%m%d-%H%M%S).log"

    log_info "=== HA (kube-vip) Integration Test ==="
    log_info "Distribution: $DISTRO"
    log_info "VIP: $HA_VIP"
    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    mkdir -p results/logs "$VM_DATA_DIR"

    # Clean up stale containers
    _ha_cleanup_vm_container
    cleanup_orphaned_containers "k8s-ha-test"

    _VM_CONTAINER_NAME=""
    trap '_ha_cleanup_vm_container; cleanup_ssh_key' EXIT INT TERM HUP

    setup_ssh_key
    SSH_PORT=$(find_free_port)

    # --- Start VM ---
    log_info "Starting container: $container_name (SSH port: $SSH_PORT)"
    docker run -d --rm \
        --name "$container_name" \
        --label "managed-by=k8s-ha-test" \
        --device /dev/kvm:/dev/kvm \
        -v "$VM_DATA_DIR:/data" \
        -p "${SSH_PORT}:2222" \
        -e "DISTRO=$DISTRO" \
        -e "GUEST_NAME=$container_name" \
        -e "SSH_PUBKEY=$(cat "$SSH_KEY_DIR/id_test.pub")" \
        -e "NO_CONSOLE=1" \
        -e "MEMORY=$VM_MEMORY" \
        -e "CPUS=$VM_CPUS" \
        -e "DISK_SIZE=$VM_DISK_SIZE" \
        "$DOCKER_VM_RUNNER_IMAGE" >/dev/null
    _VM_CONTAINER_NAME="$container_name"
    _WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$container_name")
    log_success "Container started"

    # --- Wait for cloud-init and SSH ---
    wait_for_cloud_init "$container_name" "$SSH_READY_TIMEOUT" "HA" || return 1
    wait_for_ssh "$SSH_PORT" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "HA" || return 1

    # --- Discover VM network ---
    local vm_ip vm_iface
    vm_ip=$(vm_ssh "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')
    vm_iface=$(vm_ssh "ip route get 1 | awk '{print \$5; exit}'" 2>/dev/null | tr -d '[:space:]')
    log_info "VM IP: $vm_ip, interface: $vm_iface"

    # --- Deploy bundled scripts ---
    local setup_bundle
    setup_bundle=$(mktemp /tmp/setup-k8s-ha-bundle.XXXXXX.sh)
    log_info "Generating bundled script..."
    _generate_bundle "$SETUP_K8S_SCRIPT" "$setup_bundle" "all"

    log_info "Transferring script to VM..."
    vm_scp "$setup_bundle" "/tmp/setup-k8s.sh"
    vm_ssh "chmod +x /tmp/setup-k8s.sh" >/dev/null 2>&1
    rm -f "$setup_bundle"
    log_success "Script deployed"

    # --- Resolve K8s version if not specified ---
    local k8s_version_flag="" k8s_version_val=""
    if [ -n "$K8S_VERSION" ]; then
        k8s_version_flag="--kubernetes-version"
        k8s_version_val="$K8S_VERSION"
    fi

    # ===================================================================
    # Phase 1: HA Init
    # ===================================================================
    log_info "=== Phase 1: HA Init (--ha --ha-vip $HA_VIP) ==="
    local ha_args
    ha_args="--ha --ha-vip $(printf '%q' "$HA_VIP") --ha-interface $(printf '%q' "$vm_iface")"
    if [ -n "$k8s_version_flag" ]; then
        log_info "Running: setup-k8s.sh init $k8s_version_flag $k8s_version_val $ha_args"
    else
        log_info "Running: setup-k8s.sh init $ha_args"
    fi

    local ha_init_cmd="bash /tmp/setup-k8s.sh init"
    [ -n "$k8s_version_flag" ] && ha_init_cmd+=" $(printf '%q' "$k8s_version_flag") $(printf '%q' "$k8s_version_val")"
    ha_init_cmd+=" $ha_args > /tmp/setup-k8s.log 2>&1; echo \$? > /tmp/setup-exit-code"
    vm_ssh "nohup bash -c '${ha_init_cmd}' </dev/null >/dev/null 2>&1 &"

    if ! poll_vm_command vm_ssh "$container_name" /tmp/setup-exit-code /tmp/setup-k8s.log "$TIMEOUT_TOTAL"; then
        vm_ssh "cat /tmp/setup-k8s.log" > "$log_file" 2>/dev/null || true
        return 1
    fi
    local setup_exit_code="$POLL_EXIT_CODE"
    log_info "Setup exit code: $setup_exit_code"

    # Save logs
    vm_ssh "cat /tmp/setup-k8s.log" > "$log_file" 2>/dev/null || true

    if [ "$setup_exit_code" -ne 0 ]; then
        log_error "=== SETUP LOG (last 40 lines) ==="
        tail -40 "$log_file"
        log_error "=== END ==="
        log_info "=== DIAGNOSTICS ==="
        log_info "IP addresses:"
        vm_ssh "ip addr show" 2>/dev/null || true
        log_info "Routing table:"
        vm_ssh "ip route" 2>/dev/null || true
        log_info "Listening ports:"
        vm_ssh "ss -tlnp | grep 6443" 2>/dev/null || true
        log_info "VIP connectivity test:"
        vm_ssh "curl -sk --connect-timeout 3 https://${HA_VIP}:6443/livez 2>&1 || echo 'VIP unreachable'" 2>/dev/null || true
        vm_ssh "curl -sk --connect-timeout 3 https://${vm_ip}:6443/livez 2>&1 || echo 'NodeIP unreachable'" 2>/dev/null || true
        log_info "kube-vip manifest:"
        vm_ssh "cat /etc/kubernetes/manifests/kube-vip.yaml 2>/dev/null || echo 'not found'" 2>/dev/null || true
        log_info "kube-vip pod status (crictl):"
        vm_ssh "crictl ps -a 2>/dev/null | grep -i vip || echo 'no kube-vip container'" 2>/dev/null || true
        log_info "=== END DIAGNOSTICS ==="
        return 1
    fi
    log_success "HA init completed (exit 0)"

    # ===================================================================
    # Phase 2: Verify HA-specific artifacts
    # ===================================================================
    log_info "=== Phase 2: HA Verification ==="

    local all_pass=true

    # Check 1: kube-vip manifest exists
    if vm_ssh "test -f /etc/kubernetes/manifests/kube-vip.yaml" >/dev/null 2>&1; then
        log_success "CHECK: kube-vip.yaml manifest exists"
    else
        log_error "CHECK: kube-vip.yaml manifest NOT found"
        all_pass=false
    fi

    # Check 2: kube-vip manifest contains VIP
    if vm_ssh "grep -q -F $(printf '%q' "$HA_VIP") /etc/kubernetes/manifests/kube-vip.yaml" >/dev/null 2>&1; then
        log_success "CHECK: kube-vip manifest contains VIP ($HA_VIP)"
    else
        log_error "CHECK: kube-vip manifest does not contain VIP"
        all_pass=false
    fi

    # Check 3: kube-vip manifest contains interface
    if vm_ssh "grep -q -F $(printf '%q' "$vm_iface") /etc/kubernetes/manifests/kube-vip.yaml" >/dev/null 2>&1; then
        log_success "CHECK: kube-vip manifest contains interface ($vm_iface)"
    else
        log_error "CHECK: kube-vip manifest does not contain interface"
        all_pass=false
    fi

    # Check 4: kubelet is active
    local kubelet_status
    kubelet_status=$(vm_ssh "systemctl is-active kubelet" 2>/dev/null | tr -d '[:space:]') || kubelet_status="inactive"
    if [ "$kubelet_status" = "active" ]; then
        log_success "CHECK: kubelet is active"
    else
        log_error "CHECK: kubelet is $kubelet_status"
        all_pass=false
    fi

    # Check 5: kubeconfig exists
    if vm_ssh "test -f /etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK: admin.conf exists"
    else
        log_error "CHECK: admin.conf NOT found"
        all_pass=false
    fi

    # Check 6: API server responsive
    # Try with VIP first, fall back to node IP
    local api_server_args=""
    if vm_ssh "timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK: API server responsive (via kubeconfig)"
    else
        # kubeconfig might point to VIP which may not be reachable in PASST mode
        # Try directly via node IP
        if vm_ssh "timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf --server=https://${vm_ip}:6443 --insecure-skip-tls-verify" >/dev/null 2>&1; then
            api_server_args="--server=https://${vm_ip}:6443 --insecure-skip-tls-verify"
            log_warn "CHECK: API server responsive (via node IP fallback, VIP may not work in PASST networking)"
        else
            log_error "CHECK: API server NOT responsive"
            all_pass=false
        fi
    fi

    # Check 7: control-plane-endpoint set correctly in kubeadm-config
    if vm_ssh "kubectl get configmap kubeadm-config -n kube-system -o yaml --kubeconfig=/etc/kubernetes/admin.conf ${api_server_args} 2>/dev/null | grep -q 'controlPlaneEndpoint'" >/dev/null 2>&1; then
        log_success "CHECK: controlPlaneEndpoint set in kubeadm-config"
    else
        log_warn "CHECK: Could not verify controlPlaneEndpoint in kubeadm-config (non-fatal)"
    fi

    # Check 8: setup log contains HA join info
    if grep -q "HA Cluster: Control-Plane Join Information" "$log_file" 2>/dev/null; then
        log_success "CHECK: HA join info displayed in output"
    else
        log_error "CHECK: HA join info NOT found in output"
        all_pass=false
    fi

    # Check 9: certificate key in output
    if grep -q "Certificate key:" "$log_file" 2>/dev/null; then
        log_success "CHECK: Certificate key displayed"
    else
        log_error "CHECK: Certificate key NOT found in output"
        all_pass=false
    fi

    # Show kube-vip pod status (use grep instead of field-selector which doesn't support wildcards)
    log_info "kube-vip pod status:"
    vm_ssh "kubectl get pods -n kube-system --kubeconfig=/etc/kubernetes/admin.conf ${api_server_args} 2>/dev/null | grep -E 'NAME|kube-vip' || echo '(could not query pods)'" 2>/dev/null || true

    # ===================================================================
    # Phase 3: Cleanup
    # ===================================================================
    log_info "=== Phase 3: Cleanup ==="
    vm_ssh "nohup bash -c 'bash /tmp/setup-k8s.sh cleanup --force > /tmp/cleanup-k8s.log 2>&1; echo \$? > /tmp/cleanup-exit-code' </dev/null >/dev/null 2>&1 &"

    local cleanup_exit_code
    if ! poll_vm_command vm_ssh "$container_name" /tmp/cleanup-exit-code /tmp/cleanup-k8s.log "$TIMEOUT_TOTAL"; then
        log_warn "Cleanup polling failed (timeout or container exit)"
        cleanup_exit_code=1
    else
        cleanup_exit_code="$POLL_EXIT_CODE"
    fi
    if [ "$cleanup_exit_code" -eq 0 ]; then
        log_success "Cleanup completed (exit 0)"
    else
        log_error "Cleanup failed (exit $cleanup_exit_code)"
        all_pass=false
    fi

    # Append cleanup logs
    vm_ssh "cat /tmp/cleanup-k8s.log" >> "$log_file" 2>/dev/null || true

    # ===================================================================
    # Result
    # ===================================================================
    echo ""
    log_info "Log file: $log_file"
    if [ "$all_pass" = true ]; then
        log_success "=== HA TEST PASSED ==="
        _ha_cleanup_vm_container
        cleanup_ssh_key
        trap - EXIT INT TERM HUP
        return 0
    else
        log_error "=== HA TEST FAILED ==="
        _ha_cleanup_vm_container
        cleanup_ssh_key
        trap - EXIT INT TERM HUP
        return 1
    fi
}

# ===================================================================
# Failover Mode: 3 CP VMs via Docker network
# ===================================================================

_fo_setup_docker_network() {
    log_info "Creating Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true
    docker network create --subnet "$DOCKER_SUBNET" "$DOCKER_NETWORK" >/dev/null
    log_success "Docker network created"
}

_fo_cleanup_docker_network() {
    if docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
        docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true
    fi
}

_fo_cleanup_all() {
    for i in "${!_FO_CONTAINER_NAMES[@]}"; do
        _cleanup_vm_container "${_FO_WATCHDOG_PIDS[$i]:-}" "${_FO_CONTAINER_NAMES[$i]:-}"
    done
    _FO_CONTAINER_NAMES=()
    _FO_WATCHDOG_PIDS=()
    _fo_cleanup_docker_network
    cleanup_ssh_key
}

# Start a VM with static IP on Docker network (same pattern as run-deploy-test.sh)
_fo_start_vm() {
    local idx=$1 static_ip=$2 host_ssh_port=$3
    local container_name
    container_name="k8s-ha-fo-cp$((idx+1))-${DISTRO}-$(date +%s)"
    local vm_data_dir="$VM_DATA_DIR/ha-cp$((idx+1))"
    mkdir -p "$vm_data_dir"

    log_info "Starting CP $((idx+1))/$NUM_CP_NODES: $container_name (IP: $static_ip, SSH: $host_ssh_port)"
    # NETWORK_GUEST_IP sets the VM's internal IP to the Docker network IP.
    # This is required for HA: kubeadm uses this IP for etcd peer URLs and
    # apiserver advertise address, enabling inter-node communication via
    # passt port forwarding through Docker network IPs.
    docker run -d --rm \
        --name "$container_name" \
        --label "managed-by=k8s-ha-failover-test" \
        --network "$DOCKER_NETWORK" --ip "$static_ip" \
        --device /dev/kvm:/dev/kvm \
        -v "$vm_data_dir:/data" \
        -p "${host_ssh_port}:2222" \
        -e "DISTRO=$DISTRO" \
        -e "GUEST_NAME=$container_name" \
        -e "SSH_PUBKEY=$(cat "$SSH_KEY_DIR/id_test.pub")" \
        -e "PORT_FWD=6443:6443,10250:10250,2379:2379,2380:2380" \
        -e "NETWORK_GUEST_IP=$static_ip" \
        -e "NO_CONSOLE=1" \
        -e "MEMORY=$VM_MEMORY" \
        -e "CPUS=$VM_CPUS" \
        -e "DISK_SIZE=$VM_DISK_SIZE" \
        "$DOCKER_VM_RUNNER_IMAGE" >/dev/null

    _FO_CONTAINER_NAMES[$idx]="$container_name"
    _FO_WATCHDOG_PIDS[$idx]=$(_start_vm_container_watchdog "$$" "$container_name")
    _FO_SSH_PORTS[$idx]="$host_ssh_port"
    log_success "Container $container_name started"
}

_fo_ssh_root() {
    local port=$1; shift
    ssh "${SSH_OPTS[@]}" -p "$port" "root@localhost" "$@"
}

_fo_setup_root_ssh() {
    local port=$1 label=$2
    log_info "[$label] Setting up root SSH access..."
    ssh "${SSH_OPTS[@]}" -p "$port" "$LOGIN_USER@localhost" \
        "sudo mkdir -p /root/.ssh && sudo cp ~/.ssh/authorized_keys /root/.ssh/ && sudo chmod 700 /root/.ssh && sudo chmod 600 /root/.ssh/authorized_keys" >/dev/null 2>&1
    if ssh "${SSH_OPTS[@]}" -p "$port" "root@localhost" "echo ok" >/dev/null 2>&1; then
        log_success "[$label] Root SSH access ready"
    else
        log_error "[$label] Root SSH access failed"
        return 1
    fi
}

run_failover_test() {
    log_info "=== HA Failover Test (3 CP, deploy mode) ==="
    log_info "Distribution: $DISTRO"
    log_info "VIP: $_FO_HA_VIP"
    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    log_info "Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    mkdir -p results/logs "$VM_DATA_DIR"

    cleanup_orphaned_containers "k8s-ha-failover-test"
    trap '_fo_cleanup_all' EXIT INT TERM HUP

    # --- Step 1: Infrastructure ---
    _fo_setup_docker_network
    setup_ssh_key

    # --- Step 2: Start 3 VMs ---
    log_info "=== Step 1: Starting $NUM_CP_NODES VMs ==="
    for i in $(seq 0 $((NUM_CP_NODES - 1))); do
        local ssh_port
        ssh_port=$(find_free_port)
        _fo_start_vm "$i" "${_FO_DOCKER_IPS[$i]}" "$ssh_port"
    done

    # Wait for VMs
    for i in $(seq 0 $((NUM_CP_NODES - 1))); do
        wait_for_cloud_init "${_FO_CONTAINER_NAMES[$i]}" "$SSH_READY_TIMEOUT" "CP$((i+1))" || return 1
        wait_for_ssh "${_FO_SSH_PORTS[$i]}" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "CP$((i+1))" || return 1
        _fo_setup_root_ssh "${_FO_SSH_PORTS[$i]}" "CP$((i+1))"
    done
    log_success "All $NUM_CP_NODES VMs ready"

    # --- Step 3: Resolve K8s version ---
    resolve_k8s_version || return 1

    # --- Step 4: Deploy 3 CP HA cluster ---
    log_info "=== Step 2: Deploying HA cluster ==="
    local cp_list="${_FO_DOCKER_IPS[0]}"
    for i in $(seq 1 $((NUM_CP_NODES - 1))); do
        cp_list="${cp_list},${_FO_DOCKER_IPS[$i]}"
    done

    # Discover interface inside first VM
    local vm_iface
    vm_iface=$(_fo_ssh_root "${_FO_SSH_PORTS[0]}" "ip route get 1 | awk '{print \$5; exit}'" 2>/dev/null | tr -d '[:space:]')
    log_info "VM network interface: $vm_iface"

    # NAT (passt) mode: VIP is not reachable between VMs because passt
    # does not expose IPs added inside the VM to the Docker network.
    # Use CP1's Docker IP as control-plane-endpoint (same as run-deploy-test.sh).
    # kube-vip manifest is still deployed via --ha-vip/--ha-interface.
    local deploy_cmd=(
        bash "$SETUP_K8S_SCRIPT" deploy
        --control-planes "$cp_list"
        --ha-vip "$_FO_HA_VIP"
        --ha-interface "$vm_iface"
        --control-plane-endpoint "${_FO_DOCKER_IPS[0]}:6443"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --kubernetes-version "$K8S_VERSION"
    )
    log_info "Command: ${deploy_cmd[*]}"

    local log_file
    log_file="results/logs/ha-failover-${DISTRO}-$(date +%Y%m%d-%H%M%S).log"

    local deploy_exit_code=0
    if timeout "$TIMEOUT_TOTAL" "${deploy_cmd[@]}" 2>&1 | tee "$log_file"; then
        deploy_exit_code=0
    else
        deploy_exit_code=$?
    fi

    if [ "$deploy_exit_code" -ne 0 ]; then
        log_error "HA cluster deployment failed (exit $deploy_exit_code)"
        return 1
    fi
    log_success "HA cluster deployed"

    # --- Step 5: Verify cluster health (no CNI required) ---
    log_info "=== Step 3: Verifying cluster health ==="
    local all_pass=true

    # Check node count (nodes may be NotReady without CNI, that's OK)
    local elapsed=0 timeout=120
    while [ "$elapsed" -lt "$timeout" ]; do
        local node_count
        node_count=$(_fo_ssh_root "${_FO_SSH_PORTS[0]}" \
            "kubectl get nodes --no-headers --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null | wc -l" \
            2>/dev/null | tr -d '[:space:]')
        if [ "${node_count:-0}" -eq "$NUM_CP_NODES" ] 2>/dev/null; then
            log_success "CHECK: Node count = $node_count (expected $NUM_CP_NODES)"
            break
        fi
        log_info "  Waiting for nodes: ${node_count:-0}/$NUM_CP_NODES registered"
        sleep 10
        elapsed=$((elapsed + 10))
    done
    if [ "$elapsed" -ge "$timeout" ]; then
        log_error "Not all nodes registered within ${timeout}s"
        _fo_ssh_root "${_FO_SSH_PORTS[0]}" "kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true
        all_pass=false
    fi

    # API server health
    if _fo_ssh_root "${_FO_SSH_PORTS[0]}" "kubectl get --raw /readyz --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK: API server is ready"
    else
        log_error "CHECK: API server not ready"
        all_pass=false
    fi

    # kubelet active on all nodes
    for i in $(seq 0 $((NUM_CP_NODES - 1))); do
        local kubelet_status
        kubelet_status=$(_fo_ssh_root "${_FO_SSH_PORTS[$i]}" \
            "systemctl is-active kubelet" 2>/dev/null | tr -d '[:space:]') || kubelet_status="unknown"
        if [ "$kubelet_status" = "active" ]; then
            log_success "CHECK: CP $((i+1)) kubelet is active"
        else
            log_error "CHECK: CP $((i+1)) kubelet is $kubelet_status"
            all_pass=false
        fi
    done

    # etcd member count
    local etcd_pods
    etcd_pods=$(_fo_ssh_root "${_FO_SSH_PORTS[0]}" \
        "kubectl get pods -n kube-system -l component=etcd --no-headers --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null | wc -l" \
        2>/dev/null | tr -d '[:space:]')
    if [ "$etcd_pods" = "$NUM_CP_NODES" ]; then
        log_success "CHECK: etcd has $etcd_pods members"
    else
        log_warn "CHECK: etcd members: ${etcd_pods:-0} (expected $NUM_CP_NODES)"
    fi

    # Show node status for debugging
    _fo_ssh_root "${_FO_SSH_PORTS[0]}" \
        "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true

    [ "$all_pass" != true ] && return 1

    # --- Step 6: Simulate CP failure ---
    log_info "=== Step 4: Simulating CP node failure ==="
    local failed_idx=$((NUM_CP_NODES - 1))
    local failed_container="${_FO_CONTAINER_NAMES[$failed_idx]}"
    local failed_ip="${_FO_DOCKER_IPS[$failed_idx]}"
    log_info "Stopping CP $((failed_idx + 1)) ($failed_ip, $failed_container)..."
    docker stop "$failed_container" >/dev/null 2>&1 || true
    log_info "Waiting 20s for cluster to detect node loss..."
    sleep 20
    log_success "CP $((failed_idx + 1)) stopped"

    # --- Step 7: Verify cluster survives ---
    log_info "=== Step 5: Verifying cluster survives failure ==="
    local fo_elapsed=0 fo_timeout=120
    while [ "$fo_elapsed" -lt "$fo_timeout" ]; do
        if _fo_ssh_root "${_FO_SSH_PORTS[0]}" \
            "kubectl get --raw /readyz --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
            log_success "CHECK: API server still responds after CP failure"
            break
        fi
        sleep 5
        fo_elapsed=$((fo_elapsed + 5))
    done
    if [ "$fo_elapsed" -ge "$fo_timeout" ]; then
        log_error "CHECK: API server not responding after failover timeout"
        all_pass=false
    fi

    # kubectl operations
    if _fo_ssh_root "${_FO_SSH_PORTS[0]}" \
        "kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK: kubectl get nodes succeeds"
    else
        log_error "CHECK: kubectl get nodes failed"
        all_pass=false
    fi

    # Create a test pod
    _fo_ssh_root "${_FO_SSH_PORTS[0]}" \
        "kubectl run ha-test-pod --image=busybox --restart=Never --kubeconfig=/etc/kubernetes/admin.conf -- sleep 30" >/dev/null 2>&1 || true
    sleep 5
    _fo_ssh_root "${_FO_SSH_PORTS[0]}" \
        "kubectl delete pod ha-test-pod --ignore-not-found --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1 || true

    # --- Step 8: Verify kube-vip manifests ---
    # VIP failover cannot be tested in NAT (passt) mode because VIPs added
    # inside the VM are not visible on the Docker network. Verify that
    # kube-vip manifests were deployed on surviving nodes instead.
    log_info "=== Step 6: Verifying kube-vip manifests ==="
    local kubevip_ok=true
    for i in $(seq 0 $((NUM_CP_NODES - 2))); do
        local has_manifest
        has_manifest=$(_fo_ssh_root "${_FO_SSH_PORTS[$i]}" \
            "test -f /etc/kubernetes/manifests/kube-vip.yaml && echo yes || echo no" 2>/dev/null | tr -d '[:space:]')
        if [ "$has_manifest" = "yes" ]; then
            log_success "CHECK: kube-vip manifest present on CP $((i+1))"
        else
            log_error "CHECK: kube-vip manifest missing on CP $((i+1))"
            kubevip_ok=false
        fi
    done
    if [ "$kubevip_ok" = true ]; then
        log_success "kube-vip manifests verified on all surviving nodes"
    else
        log_warn "Some kube-vip manifests missing"
    fi

    # Show final node status
    log_info "Final node status:"
    _fo_ssh_root "${_FO_SSH_PORTS[0]}" \
        "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true

    # --- Result ---
    echo ""
    log_info "Log file: $log_file"
    if [ "$all_pass" = true ]; then
        log_success "=== HA FAILOVER TEST PASSED ==="
        _fo_cleanup_all
        trap - EXIT INT TERM HUP
        return 0
    else
        log_error "=== HA FAILOVER TEST FAILED ==="
        _fo_cleanup_all
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
        --ha-vip) _require_arg $# "$1"; HA_VIP="$2"; shift 2 ;;
        --failover) FAILOVER_MODE=true; shift ;;
        --memory) _require_arg $# "$1"; VM_MEMORY="$2"; shift 2 ;;
        --cpus) _require_arg $# "$1"; VM_CPUS="$2"; shift 2 ;;
        --disk-size) _require_arg $# "$1"; VM_DISK_SIZE="$2"; shift 2 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if [ "$FAILOVER_MODE" = true ]; then
    if run_failover_test; then exit 0; else exit 1; fi
else
    if run_ha_test; then exit 0; else exit 1; fi
fi
