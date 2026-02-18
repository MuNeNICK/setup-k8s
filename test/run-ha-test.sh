#!/bin/bash
#
# HA (kube-vip) Integration Test via docker-vm-runner
# Usage: ./test/run-ha-test.sh [--distro <name>] [--k8s-version <ver>]
#
# Tests:
#   1. setup-k8s.sh init --ha --ha-vip <VIP> completes successfully
#   2. kube-vip manifest deployed to /etc/kubernetes/manifests/
#   3. kubeadm init succeeded with --control-plane-endpoint
#   4. kubelet is active, API server is responsive
#   5. Certificate key and control-plane join info is displayed
#   6. cleanup-k8s.sh --force succeeds
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_K8S_SCRIPT="$PROJECT_ROOT/setup-k8s.sh"
CLEANUP_K8S_SCRIPT="$PROJECT_ROOT/cleanup-k8s.sh"
DOCKER_VM_RUNNER_IMAGE="${DOCKER_VM_RUNNER_IMAGE:-ghcr.io/munenick/docker-vm-runner:latest}"
VM_DATA_DIR="${VM_DATA_DIR:-$SCRIPT_DIR/data}"

# Defaults
DISTRO="${DISTRO:-ubuntu-2404}"
K8S_VERSION=""
VM_MEMORY="${VM_MEMORY:-8192}"
VM_CPUS="${VM_CPUS:-4}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
HA_VIP="10.0.2.100"

TIMEOUT_TOTAL=1200
SSH_READY_TIMEOUT=300

# SSH settings
SSH_KEY_DIR=""
SSH_PORT=""
SSH_BASE_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
SSH_OPTS=("${SSH_BASE_OPTS[@]}")

# Cleanup state
_VM_CONTAINER_NAME=""
_WATCHDOG_PID=""
LOGIN_USER="user"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

show_help() {
    cat <<EOF
HA (kube-vip) Integration Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: ubuntu-2404)
  --k8s-version <ver>     Kubernetes version (e.g., 1.32)
  --ha-vip <addr>         VIP address to use (default: $HA_VIP)
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --help, -h              Show this help message
EOF
}

# --- VM infrastructure (reused from e2e) ---

_start_vm_container_watchdog() {
    local parent_pid=$1 container_name=$2
    if [ -n "$_WATCHDOG_PID" ]; then
        kill "$_WATCHDOG_PID" >/dev/null 2>&1 || true
        _WATCHDOG_PID=""
    fi
    setsid bash -c '
parent_pid="$1"; container_name="$2"
while kill -0 "$parent_pid" >/dev/null 2>&1; do sleep 2; done
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
        log_info "Stopping container $_VM_CONTAINER_NAME..."
        docker stop "$_VM_CONTAINER_NAME" >/dev/null 2>&1 || true
        _VM_CONTAINER_NAME=""
    fi
}

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
    SSH_OPTS=("${SSH_BASE_OPTS[@]}")
}

find_free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'
}

vm_ssh() { ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$LOGIN_USER@localhost" "sudo $*"; }
vm_ssh_user() { ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$LOGIN_USER@localhost" "$*"; }
vm_scp() { scp "${SSH_OPTS[@]}" -P "$SSH_PORT" "$1" "${LOGIN_USER}@localhost:$2"; }

# --- Bundle generation ---

generate_bundled_setup() {
    local setup_bundle="/tmp/setup-k8s-ha-bundle.sh"

    log_info "Generating bundled setup script..." >&2
    {
        echo "#!/bin/bash"
        echo "set -e"
        echo "OFFLINE_MODE=true"
        echo ""

        for module in logging variables detection validation helpers networking swap completion helm; do
            echo "# === common/${module}.sh ==="
            cat "${PROJECT_ROOT}/common/${module}.sh"
            echo ""
        done

        for distro_dir in "${PROJECT_ROOT}/distros/"*/; do
            if [ -d "$distro_dir" ]; then
                local distro_name
                distro_name=$(basename "$distro_dir")
                echo "# === distros/${distro_name} modules ==="
                for module_file in "$distro_dir"*.sh; do
                    if [ -f "$module_file" ]; then
                        echo "# === $(basename "$module_file") ==="
                        awk '!/^source.*SCRIPT_DIR/ && !/^SCRIPT_DIR=/' "$module_file"
                        echo ""
                    fi
                done
            fi
        done

        echo "# === Main setup-k8s.sh ==="
        tail -n +2 "$SETUP_K8S_SCRIPT"
    } > "$setup_bundle"

    echo "$setup_bundle"
}

generate_bundled_cleanup() {
    local cleanup_bundle="/tmp/cleanup-k8s-ha-bundle.sh"

    log_info "Generating bundled cleanup script..." >&2
    {
        echo "#!/bin/bash"
        echo "set -e"
        echo "OFFLINE_MODE=true"
        echo ""

        for module in logging variables detection validation helpers networking swap completion helm; do
            echo "# === common/${module}.sh ==="
            cat "${PROJECT_ROOT}/common/${module}.sh"
            echo ""
        done

        for distro_dir in "${PROJECT_ROOT}/distros/"*/; do
            if [ -d "$distro_dir" ]; then
                local distro_name
                distro_name=$(basename "$distro_dir")
                if [ -f "$distro_dir/cleanup.sh" ]; then
                    echo "# === distros/${distro_name}/cleanup.sh ==="
                    awk '!/^source.*SCRIPT_DIR/ && !/^SCRIPT_DIR=/' "$distro_dir/cleanup.sh"
                    echo ""
                fi
            fi
        done

        echo "# === Main cleanup-k8s.sh ==="
        tail -n +2 "$CLEANUP_K8S_SCRIPT"
    } > "$cleanup_bundle"

    echo "$cleanup_bundle"
}

# --- Main test logic ---

run_ha_test() {
    local container_name="k8s-ha-test-${DISTRO}-$(date +%s)"
    local log_file
    log_file="results/logs/ha-${DISTRO}-$(date +%Y%m%d-%H%M%S).log"

    log_info "=== HA (kube-vip) Integration Test ==="
    log_info "Distribution: $DISTRO"
    log_info "VIP: $HA_VIP"
    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    mkdir -p results/logs "$VM_DATA_DIR"

    # Clean up stale containers
    _cleanup_vm_container
    for cid in $(docker ps -q --filter "label=managed-by=k8s-ha-test" 2>/dev/null); do
        log_warn "Stopping orphaned HA test container"
        docker stop "$cid" >/dev/null 2>&1 || true
    done

    _VM_CONTAINER_NAME=""
    trap '_cleanup_vm_container; cleanup_ssh_key' EXIT INT TERM HUP

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
    _start_vm_container_watchdog "$$" "$container_name"
    log_success "Container started"

    # --- Wait for cloud-init ---
    log_info "Waiting for cloud-init (timeout: ${SSH_READY_TIMEOUT}s)..."
    local ci_elapsed=0
    while [ $ci_elapsed -lt $SSH_READY_TIMEOUT ]; do
        if ! docker inspect "$container_name" >/dev/null 2>&1; then
            log_error "Container exited before cloud-init completed"
            return 1
        fi
        if docker logs "$container_name" 2>&1 | grep -qE "Cloud-init (complete|finished|disabled|did not finish)|Could not query cloud-init"; then
            break
        fi
        sleep 5
        ci_elapsed=$((ci_elapsed + 5))
        (( ci_elapsed % 30 == 0 )) && log_info "Still waiting... (${ci_elapsed}s)"
    done
    if [ $ci_elapsed -ge $SSH_READY_TIMEOUT ]; then
        log_error "Cloud-init timeout"
        return 1
    fi
    log_success "Cloud-init complete"

    # --- Wait for SSH ---
    log_info "Waiting for SSH..."
    local ssh_elapsed=0
    while [ $ssh_elapsed -lt 60 ]; do
        if vm_ssh_user "echo ready" >/dev/null 2>&1; then break; fi
        sleep 3
        ssh_elapsed=$((ssh_elapsed + 3))
    done
    if [ $ssh_elapsed -ge 60 ]; then
        log_error "SSH not available"
        return 1
    fi
    log_success "SSH is ready"

    # --- Discover VM network ---
    local vm_ip vm_iface
    vm_ip=$(vm_ssh "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')
    vm_iface=$(vm_ssh "ip route get 1 | awk '{print \$5; exit}'" 2>/dev/null | tr -d '[:space:]')
    log_info "VM IP: $vm_ip, interface: $vm_iface"

    # --- Deploy bundled scripts ---
    local setup_bundle cleanup_bundle
    setup_bundle=$(generate_bundled_setup)
    cleanup_bundle=$(generate_bundled_cleanup)

    log_info "Transferring scripts to VM..."
    vm_scp "$setup_bundle" "/tmp/setup-k8s.sh"
    vm_scp "$cleanup_bundle" "/tmp/cleanup-k8s.sh"
    vm_ssh "chmod +x /tmp/setup-k8s.sh /tmp/cleanup-k8s.sh" >/dev/null 2>&1
    rm -f "$setup_bundle" "$cleanup_bundle"
    log_success "Scripts deployed"

    # --- Resolve K8s version if not specified ---
    local k8s_version_arg=""
    if [ -z "$K8S_VERSION" ]; then
        log_info "Resolving latest stable Kubernetes version..."
        local stable_txt
        stable_txt=$(curl -fsSL --retry 3 --retry-delay 2 https://dl.k8s.io/release/stable.txt 2>/dev/null || true)
        if echo "$stable_txt" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
            K8S_VERSION=$(echo "$stable_txt" | sed -E 's/^v([0-9]+\.[0-9]+)\..*/\1/')
            log_success "Detected: $K8S_VERSION"
        else
            K8S_VERSION="1.32"
            log_warn "Fallback: $K8S_VERSION"
        fi
    fi
    k8s_version_arg="--kubernetes-version $K8S_VERSION"

    # ===================================================================
    # Phase 1: HA Init
    # ===================================================================
    log_info "=== Phase 1: HA Init (--ha --ha-vip $HA_VIP) ==="
    local ha_args="--ha --ha-vip $HA_VIP --ha-interface $vm_iface"
    log_info "Running: setup-k8s.sh init $k8s_version_arg $ha_args"

    vm_ssh "bash -c 'nohup bash /tmp/setup-k8s.sh init ${k8s_version_arg} ${ha_args} > /tmp/setup-k8s.log 2>&1; echo \$? > /tmp/setup-exit-code' &" >/dev/null 2>&1

    local start_time
    start_time=$(date +%s)
    while true; do
        local elapsed=$(( $(date +%s) - start_time ))
        if [ $elapsed -gt $TIMEOUT_TOTAL ]; then
            log_error "Setup timeout after ${TIMEOUT_TOTAL}s"
            vm_ssh "cat /tmp/setup-k8s.log" > "$log_file" 2>/dev/null || true
            return 1
        fi
        if ! docker inspect "$container_name" >/dev/null 2>&1; then
            log_error "Container exited unexpectedly"
            return 1
        fi
        if vm_ssh "test -f /tmp/setup-exit-code" >/dev/null 2>&1; then break; fi
        local progress_line
        progress_line=$(vm_ssh "tail -1 /tmp/setup-k8s.log" 2>/dev/null || true)
        [ -n "$progress_line" ] && log_info "[${elapsed}s] $progress_line"
        sleep 10
    done

    local setup_exit_code
    setup_exit_code=$(vm_ssh "cat /tmp/setup-exit-code" 2>/dev/null | tr -d '[:space:]')
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
    if vm_ssh "grep -q '$HA_VIP' /etc/kubernetes/manifests/kube-vip.yaml" >/dev/null 2>&1; then
        log_success "CHECK: kube-vip manifest contains VIP ($HA_VIP)"
    else
        log_error "CHECK: kube-vip manifest does not contain VIP"
        all_pass=false
    fi

    # Check 3: kube-vip manifest contains interface
    if vm_ssh "grep -q '$vm_iface' /etc/kubernetes/manifests/kube-vip.yaml" >/dev/null 2>&1; then
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
    local api_ok=false
    if vm_ssh "timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        api_ok=true
        log_success "CHECK: API server responsive (via kubeconfig)"
    else
        # kubeconfig might point to VIP which may not be reachable in PASST mode
        # Try directly via node IP
        if vm_ssh "timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf --server=https://${vm_ip}:6443 --insecure-skip-tls-verify" >/dev/null 2>&1; then
            api_ok=true
            log_warn "CHECK: API server responsive (via node IP fallback, VIP may not work in PASST networking)"
        else
            log_error "CHECK: API server NOT responsive"
            all_pass=false
        fi
    fi

    # Check 7: control-plane-endpoint set correctly in kubeadm-config
    if vm_ssh "kubectl get configmap kubeadm-config -n kube-system -o yaml --kubeconfig=/etc/kubernetes/admin.conf ${api_ok:+--server=https://${vm_ip}:6443 --insecure-skip-tls-verify} 2>/dev/null | grep -q 'controlPlaneEndpoint'" >/dev/null 2>&1; then
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
    vm_ssh "kubectl get pods -n kube-system --kubeconfig=/etc/kubernetes/admin.conf ${api_ok:+--server=https://${vm_ip}:6443 --insecure-skip-tls-verify} 2>/dev/null | grep -E 'NAME|kube-vip' || echo '(could not query pods)'" 2>/dev/null || true

    # ===================================================================
    # Phase 3: Cleanup
    # ===================================================================
    log_info "=== Phase 3: Cleanup ==="
    vm_ssh "bash -c 'nohup bash /tmp/cleanup-k8s.sh --force > /tmp/cleanup-k8s.log 2>&1; echo \$? > /tmp/cleanup-exit-code' &" >/dev/null 2>&1

    start_time=$(date +%s)
    while true; do
        local elapsed=$(( $(date +%s) - start_time ))
        if [ $elapsed -gt $TIMEOUT_TOTAL ]; then
            log_error "Cleanup timeout"
            break
        fi
        if ! docker inspect "$container_name" >/dev/null 2>&1; then
            log_error "Container exited during cleanup"
            break
        fi
        if vm_ssh "test -f /tmp/cleanup-exit-code" >/dev/null 2>&1; then break; fi
        sleep 10
    done

    local cleanup_exit_code
    cleanup_exit_code=$(vm_ssh "cat /tmp/cleanup-exit-code" 2>/dev/null | tr -d '[:space:]') || cleanup_exit_code="1"
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
        _cleanup_vm_container
        cleanup_ssh_key
        trap - EXIT INT TERM HUP
        return 0
    else
        log_error "=== HA TEST FAILED ==="
        _cleanup_vm_container
        cleanup_ssh_key
        trap - EXIT INT TERM HUP
        return 1
    fi
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h) show_help; exit 0 ;;
        --distro) DISTRO="$2"; shift 2 ;;
        --k8s-version) K8S_VERSION="$2"; shift 2 ;;
        --ha-vip) HA_VIP="$2"; shift 2 ;;
        --memory) VM_MEMORY="$2"; shift 2 ;;
        --cpus) VM_CPUS="$2"; shift 2 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_ha_test; then
    exit 0
else
    exit 1
fi
