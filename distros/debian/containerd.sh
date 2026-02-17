#!/bin/bash

# Source common helpers (only when not already loaded by the entry script)
if ! type -t configure_containerd_toml &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/../../common/helpers.sh" 2>/dev/null || true
fi

# Setup containerd for Debian/Ubuntu
setup_containerd_debian() {
    echo "Setting up containerd for Debian-based distribution..."
    
    # Create keyrings directory if it doesn't exist
    mkdir -p /etc/apt/keyrings
    
    # Add Docker repository (for containerd) without using lsb_release
    CODENAME=$(get_debian_codename)
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        if [ "$DISTRO_NAME" = "ubuntu" ]; then
            curl -fsSL --retry 3 --retry-delay 2 https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
        else
            curl -fsSL --retry 3 --retry-delay 2 https://download.docker.com/linux/debian/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
        fi
    fi
    if [ "$DISTRO_NAME" = "ubuntu" ]; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list
    else
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list
    fi
    
    # Install containerd
    apt-get update
    apt-get install -y containerd.io
    
    # Configure containerd
    configure_containerd_toml
    configure_crictl containerd
}