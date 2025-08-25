#!/bin/bash

set -e

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default GitHub base URL (can be overridden)
GITHUB_BASE_URL="${GITHUB_BASE_URL:-https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main}"

# Check if running in offline mode
OFFLINE_MODE="${OFFLINE_MODE:-false}"

# Parse early arguments for offline mode
for arg in "$@"; do
    if [ "$arg" = "--offline" ]; then
        OFFLINE_MODE="true"
        break
    fi
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
    local temp_dir=$(mktemp -d -t cleanup-k8s-XXXXXX)
    trap "rm -rf $temp_dir" EXIT
    
    # Download common modules
    echo "Downloading common modules..." >&2
    local common_modules=(variables detection validation helpers networking swap)
    for module in "${common_modules[@]}"; do
        echo "  - Downloading common/${module}.sh" >&2
        if ! curl -fsSL "${GITHUB_BASE_URL}/common/${module}.sh" > "$temp_dir/${module}.sh"; then
            echo "Error: Failed to download common/${module}.sh" >&2
            return 1
        fi
    done
    
    # Source common modules to get distribution detection
    for module in variables detection; do
        source "$temp_dir/${module}.sh"
    done
    
    # Detect distribution first
    detect_distribution
    
    # Download distribution-specific cleanup module
    echo "Downloading cleanup module for $DISTRO_FAMILY..." >&2
    if ! curl -fsSL "${GITHUB_BASE_URL}/distros/$DISTRO_FAMILY/cleanup.sh" > "$temp_dir/${DISTRO_FAMILY}_cleanup.sh"; then
        echo "Error: Failed to download distros/$DISTRO_FAMILY/cleanup.sh" >&2
        return 1
    fi
    
    # Source all modules
    echo "Loading all modules..." >&2
    for module in "${common_modules[@]}"; do
        source "$temp_dir/${module}.sh"
    done
    source "$temp_dir/${DISTRO_FAMILY}_cleanup.sh"
    
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
    
    # Parse command line arguments
    parse_cleanup_args "$@"
    
    # Check root privileges
    check_root
    
    # Confirmation prompt
    confirm_cleanup
    
    echo "Starting Kubernetes cleanup..."
    
    # Detect distribution (if not already detected)
    if [ -z "$DISTRO_FAMILY" ]; then
        detect_distribution
    fi
    
    # Check Docker warning
    check_docker_warning
    
    # Stop services first
    echo "Stopping Kubernetes services..."
    systemctl stop kubelet || true
    systemctl disable kubelet || true
    
    # Stop CRI runtimes where safe
    # Do not stop containerd to avoid impacting Docker; we only reset its config later.
    if systemctl list-unit-files | grep -q '^crio\.service'; then
        echo "Stopping and disabling CRI-O service..."
        systemctl stop crio || true
        systemctl disable crio || true
    fi
    
    # Reset kubeadm if present to clean cluster state
    if command -v kubeadm &> /dev/null; then
        echo "Resetting kubeadm cluster state..."
        kubeadm reset -f || true
    fi
    
    # Remove configuration files
    echo "Removing common configuration files..."
    rm -f /etc/default/kubelet
    rm -rf /etc/kubernetes
    rm -rf /etc/systemd/system/kubelet.service.d
    
    # Restore zram swap if it was disabled
    restore_zram_swap
    
    # Clean up CNI configurations if not preserving
    if [ "$PRESERVE_CNI" = false ]; then
        cleanup_cni
    else
        echo "Preserving CNI configurations as requested."
    fi
    
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
    cleanup_${DISTRO_FAMILY}
    
    echo "Cleanup complete! Please reboot the system for all changes to take effect."
}

# If script is run directly (not sourced), execute main
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi