#!/bin/bash

# SUSE specific: Install dependencies
install_dependencies_suse() {
    echo "Installing dependencies for SUSE-based distribution..."
    zypper refresh
    
    # Install base dependencies
    zypper install -y curl iptables iproute2 ethtool conntrack-tools socat cri-tools || true
    
    # Install IPVS packages only if IPVS mode is selected
    if [ "$PROXY_MODE" = "ipvs" ]; then
        echo "Installing IPVS packages for IPVS proxy mode..."
        zypper install -y ipvsadm ipset || true
    fi
    
    # Install nftables package only if nftables mode is selected
    if [ "$PROXY_MODE" = "nftables" ]; then
        echo "Installing nftables package for nftables proxy mode..."
        zypper install -y nftables || true
    fi
}