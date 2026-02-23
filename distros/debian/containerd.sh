#!/bin/sh

# Setup containerd for Debian/Ubuntu
setup_containerd_debian() {
    log_info "Setting up containerd for Debian-based distribution..."
    
    # Create keyrings directory if it doesn't exist
    mkdir -p /etc/apt/keyrings
    
    # Add Docker repository (for containerd) without using lsb_release
    local CODENAME
    CODENAME=$(get_debian_codename)
    curl -fsSL --retry 3 --retry-delay 2 "https://download.docker.com/linux/${DISTRO_NAME}/gpg" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod 0644 /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_NAME} ${CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list
    
    # Install containerd
    apt-get update
    apt-get install -y containerd.io
    
    # Configure containerd
    configure_containerd_toml
    configure_crictl
}