#!/bin/bash

# Debian/Ubuntu specific: Install dependencies
install_dependencies_debian() {
    echo "Installing dependencies for Debian-based distribution..."
    apt-get update
    apt-get install -y \
        apt-transport-https ca-certificates curl gnupg \
        software-properties-common \
        conntrack socat ethtool iproute2 iptables \
        ebtables || true
    # If ebtables is unavailable, try arptables as a fallback
    if ! dpkg -s ebtables >/dev/null 2>&1; then
        apt-get install -y arptables || true
    fi
}