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
    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml
    
    # For containerd v2, SystemdCgroup is in a different location
    # Check containerd version and apply correct configuration
    CONTAINERD_VERSION=$(containerd --version | grep -oP 'v\d+' | sed 's/v//')
    
    if [ "$CONTAINERD_VERSION" -ge 2 ]; then
        echo "Detected containerd v2, applying v2 configuration..."
        # For containerd v2, add SystemdCgroup to runc options
        sed -i '/\[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options\]/a\            SystemdCgroup = true' /etc/containerd/config.toml
    else
        # For containerd v1.x
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    fi
    
    systemctl restart containerd
    systemctl enable containerd
    configure_crictl containerd
}