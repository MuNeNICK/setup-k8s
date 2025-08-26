#!/bin/bash

# Arch Linux specific: Install dependencies
install_dependencies_arch() {
    echo "Installing dependencies for Arch-based distribution..."
    
    # Install base dependencies
    pacman -Sy --noconfirm curl conntrack-tools socat ethtool iproute2 iptables crictl || true
    
    # Install IPVS packages only if IPVS mode is selected
    if [ "$PROXY_MODE" = "ipvs" ]; then
        echo "Installing IPVS packages for IPVS proxy mode..."
        pacman -Sy --noconfirm ipvsadm ipset || true
    fi
}