#!/bin/bash

# Source common helpers (only when not already loaded by the entry script)
if ! type -t configure_containerd_toml &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/../../common/helpers.sh" 2>/dev/null || true
fi

# Setup containerd for Arch Linux
setup_containerd_arch() {
    echo "Setting up containerd for Arch-based distribution..."
    
    # Install containerd
    pacman -Sy --noconfirm containerd
    
    # Configure containerd
    configure_containerd_toml
    
    systemctl restart containerd
    systemctl enable containerd
    configure_crictl
}