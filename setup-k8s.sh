#!/bin/bash

set -e

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default GitHub base URL (can be overridden)
GITHUB_BASE_URL="${GITHUB_BASE_URL:-https://raw.github.com/MuNeNICK/setup-k8s/main}"

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
    local temp_dir=$(mktemp -d -t setup-k8s-XXXXXX)
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
    
    # Store DISTRO_FAMILY in a local variable to ensure it persists
    local distro_family_local="$DISTRO_FAMILY"
    
    # Download distribution-specific modules
    echo "Downloading modules for $distro_family_local..." >&2
    local distro_modules=(dependencies containerd crio kubernetes cleanup)
    for module in "${distro_modules[@]}"; do
        echo "  - Downloading distros/$distro_family_local/${module}.sh" >&2
        if ! curl -fsSL "${GITHUB_BASE_URL}/distros/$distro_family_local/${module}.sh" > "$temp_dir/${distro_family_local}_${module}.sh"; then
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
    
    # Parse command line arguments
    parse_setup_args "$@"
    
    # Validate inputs
    check_root
    validate_node_type
    validate_worker_args
    validate_cri
    validate_proxy_mode
    
    echo "Starting Kubernetes initialization script..."
    echo "Node type: ${NODE_TYPE}"
    echo "Container Runtime: ${CRI}"
    echo "Proxy mode: ${PROXY_MODE}"
    
    # Detect distribution (if not already detected)
    if [ -z "$DISTRO_FAMILY" ]; then
        detect_distribution
    fi
    
    # Determine Kubernetes version
    determine_k8s_version
    echo "Kubernetes Version (minor): ${K8S_VERSION}"
    
    # Disable swap
    disable_swap
    disable_zram_swap
    
    # Enable kernel modules and network settings
    enable_kernel_modules
    configure_network_settings
    
    # Install dependencies
    echo "Installing dependencies..."
    install_dependencies_${DISTRO_FAMILY}
    
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
        setup_containerd_${DISTRO_FAMILY}
    elif [ "$CRI" = "crio" ]; then
        setup_crio_${DISTRO_FAMILY}
    else
        echo "Unsupported CRI: $CRI"
        exit 1
    fi
    
    # Setup Kubernetes
    echo "Setting up Kubernetes..."
    setup_kubernetes_${DISTRO_FAMILY}
    
    # Pre-cleanup for fresh installation
    echo "Performing pre-installation cleanup..."
    if type -t cleanup_pre_${DISTRO_FAMILY} &> /dev/null; then
        cleanup_pre_${DISTRO_FAMILY}
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
    
    # Initialize or join cluster based on node type
    if [[ "$NODE_TYPE" == "master" ]]; then
        initialize_master
    else
        join_worker
    fi
    
    # Show installed versions
    show_versions
    
    echo "Setup completed successfully!"
}

main "$@"