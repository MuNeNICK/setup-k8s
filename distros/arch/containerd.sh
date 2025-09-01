#!/bin/bash

# Source common helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../common/helpers.sh"

# Setup containerd for Arch Linux
setup_containerd_arch() {
    echo "Setting up containerd for Arch-based distribution..."
    
    # Install containerd
    pacman -Sy --noconfirm containerd
    
    # Configure containerd
    configure_containerd_toml
    
    systemctl restart containerd
    systemctl enable containerd
    configure_crictl containerd
}