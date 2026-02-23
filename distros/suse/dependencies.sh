#!/bin/sh

# SUSE specific: Install dependencies
install_dependencies_suse() {
    log_info "Installing dependencies for SUSE-based distribution..."
    zypper --non-interactive refresh

    # Install base dependencies
    if ! zypper --non-interactive install -y curl iptables iproute2 ethtool conntrack-tools socat; then
        log_error "Failed to install base dependencies"
        return 1
    fi
    
    install_proxy_mode_packages zypper --non-interactive install -y
}