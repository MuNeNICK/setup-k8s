#!/bin/bash

# Source common helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../common/helpers.sh"
source "${SCRIPT_DIR}/../../common/variables.sh"

# Setup containerd for RHEL/CentOS/Fedora
setup_containerd_rhel() {
    echo "Setting up containerd for RHEL-based distribution..."
    
    # Determine package manager (dnf or yum)
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi
    
    echo "Using package manager: $PKG_MGR"
    
    # Install required packages for repository management
    echo "Installing repository management tools..."
    if [ "$PKG_MGR" = "dnf" ]; then
        $PKG_MGR install -y dnf-plugins-core device-mapper-persistent-data lvm2 || true
    else
        $PKG_MGR install -y yum-utils device-mapper-persistent-data lvm2 || true
    fi
    
    # Add Docker repository (for containerd)
    echo "Adding Docker repository..."
    if [ "$DISTRO_NAME" = "fedora" ]; then
        # Check Fedora version for correct config-manager syntax
        if [[ "$DISTRO_VERSION" -ge 41 ]]; then
            # Fedora 41+ uses new syntax - download repo file directly
            echo "Using direct repo file download for Fedora 41+"
            curl -fsSL https://download.docker.com/linux/fedora/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
        else
            $PKG_MGR config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        fi
    else
        # For CentOS/RHEL
        $PKG_MGR config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    
    # Install containerd
    echo "Installing containerd.io package..."
    # Prefer containerd.io, allow nobest fallback for dependency resolution
    if [ "$PKG_MGR" = "dnf" ]; then
        $PKG_MGR install -y --setopt=install_weak_deps=False containerd.io || $PKG_MGR install -y --nobest containerd.io || true
    else
        $PKG_MGR install -y containerd.io || true
    fi
    
    # Check if containerd was installed successfully
    if ! command -v containerd &> /dev/null; then
        echo "Error: containerd installation failed. Trying alternative approach..."
        # Try installing docker-ce as it includes containerd
        $PKG_MGR install -y docker-ce docker-ce-cli containerd.io || true
        
        # If still not installed, try installing from CentOS 8 repository for CentOS 9
        if ! command -v containerd &> /dev/null && [ "$DISTRO_NAME" = "centos" ] && [[ "$DISTRO_VERSION" == "9"* ]]; then
            echo "Trying to install containerd from CentOS 8 repository..."
            $PKG_MGR install -y --releasever=8 containerd.io || true
        fi
    fi
    
    # Configure containerd
    if command -v containerd &> /dev/null; then
        echo "Configuring containerd..."
        configure_containerd_toml
        configure_crictl containerd
        echo "Containerd configured and restarted."
    else
        echo "Error: containerd is not installed. Kubernetes setup may fail."
    fi
}