#!/bin/bash

# Source common helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../common/helpers.sh"

# Setup containerd for SUSE
setup_containerd_suse() {
    echo "Setting up containerd for SUSE-based distribution..."
    
    # Prefer official repositories and avoid Docker CE to reduce conflicts
    echo "Installing containerd from SUSE official repositories..."
    zypper refresh
    zypper install -y containerd || true
    
    # Configure containerd if it was installed
    if command -v containerd &> /dev/null; then
        echo "Configuring containerd..."
        configure_containerd_toml
        configure_crictl containerd
    else
        echo "Error: containerd installation failed"
        return 1
    fi
}