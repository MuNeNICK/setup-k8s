#!/bin/bash

# RHEL/CentOS/Fedora specific: Install dependencies
install_dependencies_rhel() {
    echo "Installing dependencies for RHEL-based distribution..."
    
    # Determine package manager (dnf or yum)
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi
    
    echo "Using package manager: $PKG_MGR"
    
    # Install essential packages including iptables and networking tools
    echo "Installing essential packages..."
    if [ "$PKG_MGR" = "dnf" ]; then
        $PKG_MGR install -y dnf-plugins-core || true
    fi
    
    # Install base dependencies
    $PKG_MGR install -y curl gnupg2 iptables iptables-services ethtool iproute conntrack-tools socat ebtables cri-tools || true
    
    # Install IPVS packages only if IPVS mode is selected
    if [ "$PROXY_MODE" = "ipvs" ]; then
        echo "Installing IPVS packages for IPVS proxy mode..."
        $PKG_MGR install -y ipvsadm ipset || true
    fi
    
    # Check if iptables was installed successfully
    if ! command -v iptables &> /dev/null; then
        echo "Warning: iptables installation failed. Trying alternative package..."
        $PKG_MGR install -y iptables-legacy || $PKG_MGR install -y iptables-services || true
    fi
    
    # For CentOS 9 Stream, we need to enable additional repositories
    if [ "$DISTRO_NAME" = "centos" ] && [[ "$DISTRO_VERSION" == "9"* ]]; then
        echo "Detected CentOS 9 Stream, enabling additional repositories..."
        $PKG_MGR install -y epel-release || true
        $PKG_MGR config-manager --set-enabled crb || $PKG_MGR config-manager --set-enabled powertools || true
    fi
}