#!/bin/sh

# Debian/Ubuntu specific: Install dependencies
install_dependencies_debian() {
    log_info "Installing dependencies for Debian-based distribution..."
    apt-get update
    
    # Install base dependencies
    if ! apt-get install -y \
        apt-transport-https ca-certificates curl gnupg \
        software-properties-common \
        conntrack socat ethtool iproute2 iptables; then
        log_error "Failed to install base dependencies"
        return 1
    fi

    install_proxy_mode_packages apt-get install -y
}