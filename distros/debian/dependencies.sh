#!/bin/bash

# Debian/Ubuntu specific: Install dependencies
install_dependencies_debian() {
    echo "Installing dependencies for Debian-based distribution..."
    apt-get update
    
    # Install base dependencies
    apt-get install -y \
        apt-transport-https ca-certificates curl gnupg \
        software-properties-common \
        conntrack socat ethtool iproute2 iptables \
        ebtables || true
    
    # Install IPVS packages only if IPVS mode is selected
    if [ "$PROXY_MODE" = "ipvs" ]; then
        echo "Installing IPVS packages for IPVS proxy mode..."
        apt-get install -y ipvsadm ipset || true
    fi
    
    # Install nftables package only if nftables mode is selected
    if [ "$PROXY_MODE" = "nftables" ]; then
        echo "Installing nftables package for nftables proxy mode..."
        apt-get install -y nftables || true
    fi
    
    # If ebtables is unavailable, try arptables as a fallback
    if ! dpkg -s ebtables >/dev/null 2>&1; then
        apt-get install -y arptables || true
    fi
}