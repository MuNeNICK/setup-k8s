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

# Helper to safely append commands to the EXIT trap
_append_exit_trap() {
    local new_cmd="$1"
    local existing_trap
    existing_trap=$(trap -p EXIT | sed -n "s/^trap -- '\(.*\)' EXIT$/\1/p") || true
    if [ -n "$existing_trap" ]; then
        trap "${existing_trap}"$'\n'"${new_cmd}" EXIT
    else
        trap "${new_cmd}" EXIT
    fi
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

# Parse early arguments for offline / help / verbose / quiet mode
for arg in "$@"; do
    case "$arg" in
        --offline)
            OFFLINE_MODE="true"
            ;;
        --help|-h)
            cat <<'HELPEOF'
Usage: cleanup-k8s.sh [options]

Options:
  --force         Skip confirmation prompt
  --preserve-cni  Preserve CNI configurations
  --node-type     Specify node type (master/worker) to override auto-detection
  --verbose       Enable debug logging
  --quiet         Suppress informational messages (errors only)
  --offline       Run in offline mode (use bundled modules)
  --help, -h      Display this help message
HELPEOF
            exit 0
            ;;
        --verbose)
            LOG_LEVEL=2
            ;;
        --quiet)
            LOG_LEVEL=0
            ;;
    esac
done

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
    temp_dir=$(mktemp -d -t cleanup-k8s-XXXXXX)
    _append_exit_trap "rm -rf '${temp_dir}'"

    # Download common modules
    echo "Downloading common modules..." >&2
    local common_modules=(variables logging detection validation helpers networking swap completion helm)
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

    # Download distribution-specific cleanup module
    echo "Downloading cleanup module for $distro_family_local..." >&2
    local cleanup_module_file="$temp_dir/${distro_family_local}_cleanup.sh"
    if ! curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/distros/$distro_family_local/cleanup.sh" > "$cleanup_module_file"; then
        echo "Error: Failed to download distros/$distro_family_local/cleanup.sh" >&2
        return 1
    fi

    # Source all modules
    echo "Loading all modules..." >&2
    for module in "${common_modules[@]}"; do
        source "$temp_dir/${module}.sh"
    done

    # Source distribution-specific cleanup module (using saved file path)
    source "$cleanup_module_file"

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

    # Parse command line arguments (strip already-handled flags)
    local -a cli_args=()
    for arg in "$@"; do
        case "$arg" in
            --offline|--verbose|--quiet) ;;
            *) cli_args+=("$arg") ;;
        esac
    done
    parse_cleanup_args "${cli_args[@]+"${cli_args[@]}"}"

    # Check root privileges
    check_root

    # Confirmation prompt
    confirm_cleanup

    echo "Starting Kubernetes cleanup..."

    # Detect distribution (if not already detected)
    if [ -z "${DISTRO_FAMILY:-}" ]; then
        detect_distribution
    fi

    # Check Docker warning
    check_docker_warning

    # Stop Kubernetes and CRI services
    stop_kubernetes_services
    stop_cri_services

    # Reset cluster state
    reset_kubernetes_cluster

    # Remove Kubernetes configurations
    remove_kubernetes_configs

    # Restore zram swap if it was disabled
    restore_zram_swap

    # Clean up CNI configurations conditionally
    cleanup_cni_conditionally

    # Remove kernel modules and sysctl configurations
    cleanup_network_configs

    # Clean up .kube directories
    cleanup_kube_configs

    # Remove crictl configuration
    cleanup_crictl_config

    # Reset iptables rules
    reset_iptables

    # Reset containerd configuration (but don't remove containerd)
    reset_containerd_config

    # Reload systemd
    systemctl daemon-reload

    # Perform distribution-specific cleanup
    _dispatch "cleanup_${DISTRO_FAMILY}"

    # Cleanup shell completions
    cleanup_kubernetes_completions

    # Cleanup Helm if it was installed
    cleanup_helm

    echo "Cleanup complete! Please reboot the system for all changes to take effect."
}

main "$@"
