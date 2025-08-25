#!/bin/bash

# Source common helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../common/helpers.sh"

# Setup containerd for Debian/Ubuntu
setup_containerd_debian() {
    echo "Setting up containerd for Debian-based distribution..."
    
    # Create keyrings directory if it doesn't exist
    mkdir -p /etc/apt/keyrings
    
    # Add Docker repository (for containerd) without using lsb_release
    CODENAME=$(get_debian_codename)
    if [ "$DISTRO_NAME" = "ubuntu" ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list
    else
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list
    fi
    
    # Install containerd
    apt-get update
    apt-get install -y containerd.io
    
    # Configure containerd
    configure_containerd_toml
    configure_crictl containerd
}