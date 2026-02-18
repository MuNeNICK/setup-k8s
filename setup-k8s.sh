#!/bin/bash

set -euo pipefail

# Ensure SUDO_USER is defined even when script runs as root without sudo
SUDO_USER="${SUDO_USER:-}"

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default GitHub base URL (can be overridden)
GITHUB_BASE_URL="${GITHUB_BASE_URL:-https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main}"

# Check if running in offline mode
OFFLINE_MODE="${OFFLINE_MODE:-false}"

# GUI mode configuration (optional)
GUI_MODE="${GUI_MODE:-false}"
GUI_BIND_ADDRESS="${GUI_BIND_ADDRESS:-127.0.0.1}"
GUI_PORT="${GUI_PORT:-8080}"

# helper for validating GUI port input
set_gui_port() {
    local gui_port_value="$1"
    if ! [[ "$gui_port_value" =~ ^[0-9]+$ ]] || (( gui_port_value < 1 || gui_port_value > 65535 )); then
        echo "Error: GUI port must be a number between 1 and 65535" >&2
        exit 1
    fi
    GUI_PORT="$gui_port_value"
}

parse_gui_endpoint_arg() {
    local value="$1"
    local address_part=""
    local port_part=""

    if [[ "$value" == *:* ]]; then
        address_part="${value%%:*}"
        port_part="${value##*:}"
        # Allow formats like ":9000" to fall back to default host
        if [ -z "$address_part" ]; then
            address_part=""
        fi
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
        port_part="$value"
    elif [ -n "$value" ]; then
        address_part="$value"
    fi

    if [ -n "$address_part" ]; then
        GUI_BIND_ADDRESS="$address_part"
    fi
    if [ -n "$port_part" ]; then
        set_gui_port "$port_part"
    fi
}

# EXIT trap: collect cleanup paths and run them on exit
_EXIT_CLEANUP_DIRS=()
_run_exit_cleanup() {
    for dir in "${_EXIT_CLEANUP_DIRS[@]}"; do
        rm -rf "$dir"
    done
}
trap _run_exit_cleanup EXIT

_append_exit_trap() {
    _EXIT_CLEANUP_DIRS+=("$1")
}

# Helper to call dynamically-named functions with safety check
_dispatch() {
    local func_name="$1"; shift
    if type -t "$func_name" &>/dev/null; then
        "$func_name" "$@"
    else
        echo "Error: Required function '$func_name' not found." >&2
        exit 1
    fi
}

# Parse early arguments for offline / GUI / help / verbose / quiet / dry-run
# (needs to happen before modules load)
original_args=("$@")
i=0
while [ $i -lt ${#original_args[@]} ]; do
    arg="${original_args[$i]}"
    case "$arg" in
        --help|-h)
            cat <<'HELPEOF'
Usage: setup-k8s.sh <init|join> [options]

Subcommands:
  init                    Initialize a new Kubernetes cluster
  join                    Join an existing cluster as a worker or control-plane node

Options:
  --cri RUNTIME           Container runtime (containerd or crio). Default: containerd
  --proxy-mode MODE       Kube-proxy mode (iptables, ipvs, or nftables). Default: iptables
  --pod-network-cidr CIDR Pod network CIDR (e.g., 192.168.0.0/16)
  --apiserver-advertise-address ADDR  API server advertise address
  --control-plane-endpoint ENDPOINT   Control plane endpoint
  --service-cidr CIDR     Service CIDR (e.g., 10.96.0.0/12)
  --kubernetes-version VER Kubernetes version (e.g., 1.29, 1.28)
  --join-token TOKEN      Join token (join only)
  --join-address ADDR     Control plane address (join only)
  --discovery-token-hash HASH  Discovery token hash (join only)
  --control-plane         Join as control-plane node (join only, HA cluster)
  --certificate-key KEY   Certificate key for control-plane join
  --ha                    Enable HA mode with kube-vip (init only)
  --ha-vip ADDRESS        VIP address (required when --ha; also for join --control-plane)
  --ha-interface IFACE    Network interface for VIP (auto-detected if omitted)
  --enable-completion BOOL  Enable shell completion setup (default: true)
  --completion-shells LIST  Shells to configure (auto, bash, zsh, fish, or comma-separated)
  --install-helm BOOL     Install Helm package manager (default: false)
  --gui [address[:port]]  Launch the interactive web installer (requires python3)
  --offline               Run in offline mode (use bundled modules)
  --dry-run               Show configuration summary and exit without making changes
  --verbose               Enable debug logging
  --quiet                 Suppress informational messages (errors only)
  --help, -h              Display this help message
HELPEOF
            exit 0
            ;;
        --offline)
            OFFLINE_MODE="true"
            ((i += 1))
            continue
            ;;
        --verbose)
            LOG_LEVEL=2
            ((i += 1))
            continue
            ;;
        --quiet)
            LOG_LEVEL=0
            ((i += 1))
            continue
            ;;
        --dry-run)
            DRY_RUN=true
            ((i += 1))
            continue
            ;;
        --gui)
            GUI_MODE="true"
            if (( i + 1 < ${#original_args[@]} )); then
                next_arg="${original_args[$((i + 1))]}"
                if [[ -n "$next_arg" && "$next_arg" != -* ]]; then
                    parse_gui_endpoint_arg "$next_arg"
                    ((i += 2))
                    continue
                fi
            fi
            ((i += 1))
            continue
            ;;
        --gui=*)
            GUI_MODE="true"
            gui_value="${arg#*=}"
            if [ -n "$gui_value" ]; then
                parse_gui_endpoint_arg "$gui_value"
            fi
            ((i += 1))
            continue
            ;;
        init|join)
            ACTION="$arg"
            ((i += 1))
            continue
            ;;
    esac
    ((i += 1))
done

# Declare DRY_RUN / LOG_LEVEL / ACTION defaults if not set by early parse
DRY_RUN="${DRY_RUN:-false}"
LOG_LEVEL="${LOG_LEVEL:-1}"
ACTION="${ACTION:-}"

# Function to load modules
load_modules() {
    if [ "$OFFLINE_MODE" = "true" ]; then
        # Offline mode: assume all functions are already loaded (bundled)
        echo "Running in offline mode (bundled)" >&2
        return 0
    fi

    # Online mode: fetch modules from GitHub
    echo "Loading modules from GitHub..." >&2

    # Create temporary directory for modules
    local temp_dir
    temp_dir=$(mktemp -d -t setup-k8s-XXXXXX)
    _append_exit_trap "$temp_dir"

    # Download common modules
    echo "Downloading common modules..." >&2
    local common_modules=(variables logging detection validation helpers networking swap completion helm gui)
    for module in "${common_modules[@]}"; do
        echo "  - Downloading common/${module}.sh" >&2
        if ! curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/common/${module}.sh" > "$temp_dir/${module}.sh"; then
            echo "Error: Failed to download common/${module}.sh" >&2
            return 1
        fi
    done

    # Source common modules to get distribution detection
    for module in variables logging detection; do
        source "$temp_dir/${module}.sh"
    done

    # Detect distribution first
    detect_distribution

    # Store DISTRO_FAMILY in a local variable to ensure it persists
    local distro_family_local="$DISTRO_FAMILY"

    # Download distribution-specific modules
    echo "Downloading modules for $distro_family_local..." >&2
    local distro_modules=(dependencies containerd crio kubernetes cleanup)
    for module in "${distro_modules[@]}"; do
        echo "  - Downloading distros/$distro_family_local/${module}.sh" >&2
        if ! curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/distros/$distro_family_local/${module}.sh" > "$temp_dir/${distro_family_local}_${module}.sh"; then
            echo "Error: Failed to download distros/$distro_family_local/${module}.sh" >&2
            return 1
        fi
    done

    # Source all modules
    echo "Loading all modules..." >&2
    for module in "${common_modules[@]}"; do
        source "$temp_dir/${module}.sh"
    done
    for module in "${distro_modules[@]}"; do
        source "$temp_dir/${distro_family_local}_${module}.sh"
    done

    echo "All modules loaded successfully" >&2
    return 0
}

# Function to run offline (all modules already included)
run_offline() {
    # When running offline, all functions should already be defined
    # This function is called when the script is bundled with all modules
    return 0
}

# Main execution starts here
main() {
    # Load modules or run offline
    if [ "$OFFLINE_MODE" = "true" ]; then
        run_offline
    else
        load_modules || exit 1
    fi

    # Ensure GUI helper is available if requested (helpful for local/offline runs)
    if [ "$GUI_MODE" = "true" ] && ! type -t run_gui_installer >/dev/null 2>&1; then
        if [ -f "$SCRIPT_DIR/common/gui.sh" ]; then
            source "$SCRIPT_DIR/common/gui.sh"
        else
            echo "Error: GUI module is missing. Please update your checkout." >&2
            exit 1
        fi
    fi

    # Strip special flags and subcommand that have already been handled
    local -a cli_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline|--verbose|--quiet|--dry-run)
                shift
                ;;
            --gui)
                if [[ $# -gt 1 && "$2" != -* ]]; then
                    shift 2
                else
                    shift
                fi
                ;;
            --gui=*)
                shift
                ;;
            init|join)
                # Already handled in early parse
                shift
                ;;
            *)
                cli_args+=("$1")
                shift
                ;;
        esac
    done

    if [ "$GUI_MODE" = "true" ]; then
        if [ "${#cli_args[@]}" -gt 0 ]; then
            echo "Note: CLI options are ignored when --gui mode is active." >&2
        fi
        run_gui_installer
        if type -t gui_enable_progress_logging >/dev/null 2>&1; then
            gui_enable_progress_logging
        fi
    else
        # Parse command line arguments
        parse_setup_args "${cli_args[@]+"${cli_args[@]}"}"
    fi

    # Validate inputs
    check_root
    validate_action
    validate_join_args
    validate_cri
    validate_completion_options

    # Detect distribution (if not already detected)
    if [ -z "${DISTRO_FAMILY:-}" ]; then
        detect_distribution
    fi

    # Determine Kubernetes version
    determine_k8s_version

    # Validate proxy mode after K8S_VERSION is determined
    validate_proxy_mode

    # Validate HA arguments
    validate_ha_args

    # Dry-run: show configuration summary and exit
    if [ "$DRY_RUN" = true ]; then
        echo "=== Dry-run Configuration Summary ==="
        echo "Action: ${ACTION}"
        echo "Container Runtime: ${CRI}"
        echo "Proxy mode: ${PROXY_MODE}"
        echo "Kubernetes Version (minor): ${K8S_VERSION}"
        echo "Distribution: ${DISTRO_NAME:-unknown} (family: ${DISTRO_FAMILY:-unknown})"
        echo "Install Helm: ${INSTALL_HELM}"
        echo "Shell Completion: ${ENABLE_COMPLETION} (shells: ${COMPLETION_SHELLS})"
        if [ "${#KUBEADM_ARGS[@]}" -gt 0 ]; then
            echo "Kubeadm args: ${KUBEADM_ARGS[*]}"
        fi
        if [ "$JOIN_AS_CONTROL_PLANE" = true ]; then
            echo "HA Mode: joining as control-plane"
        fi
        if [ "$HA_ENABLED" = true ]; then
            echo "HA Mode: kube-vip enabled"
            echo "HA VIP: ${HA_VIP_ADDRESS}"
            echo "HA Interface: ${HA_VIP_INTERFACE}"
        fi
        echo "=== End of dry-run (no changes made) ==="
        exit 0
    fi

    echo "Starting Kubernetes initialization script..."
    echo "Action: ${ACTION}"
    echo "Container Runtime: ${CRI}"
    echo "Proxy mode: ${PROXY_MODE}"
    echo "Kubernetes Version (minor): ${K8S_VERSION}"

    # Disable swap
    disable_swap
    disable_zram_swap

    # Enable kernel modules and network settings
    enable_kernel_modules
    configure_network_settings

    # Install dependencies
    echo "Installing dependencies..."
    _dispatch "install_dependencies_${DISTRO_FAMILY}"

    # Check IPVS availability if IPVS mode is requested
    if [ "$PROXY_MODE" = "ipvs" ]; then
        check_ipvs_availability
    fi

    # Check nftables availability if nftables mode is requested
    if [ "$PROXY_MODE" = "nftables" ]; then
        check_nftables_availability
    fi

    # Setup container runtime
    echo "Setting up container runtime: ${CRI}..."
    if [ "$CRI" = "containerd" ]; then
        _dispatch "setup_containerd_${DISTRO_FAMILY}"
    elif [ "$CRI" = "crio" ]; then
        _dispatch "setup_crio_${DISTRO_FAMILY}"
    else
        echo "Unsupported CRI: $CRI"
        exit 1
    fi

    # Setup Kubernetes
    echo "Setting up Kubernetes..."
    _dispatch "setup_kubernetes_${DISTRO_FAMILY}"

    # Pre-cleanup for fresh installation
    echo "Performing pre-installation cleanup..."
    if type -t "cleanup_pre_${DISTRO_FAMILY}" &> /dev/null; then
        _dispatch "cleanup_pre_${DISTRO_FAMILY}"
    else
        # Fallback to generic pre-cleanup
        kubeadm reset -f || true
        rm -rf /etc/cni/net.d/* || true
        rm -rf /var/lib/cni/ || true
    fi

    # Clean up existing kube configs
    cleanup_kube_configs

    # Reset iptables rules
    reset_iptables

    # Initialize or join cluster based on action
    if [[ "$ACTION" == "init" ]]; then
        initialize_cluster
    else
        join_cluster
    fi

    # Show installed versions
    show_versions

    # Setup Helm if requested
    setup_helm

    # Setup shell completions
    setup_k8s_shell_completion

    echo "Setup completed successfully!"
}

main "$@"
