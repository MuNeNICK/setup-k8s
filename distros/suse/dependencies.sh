#!/bin/bash

# SUSE specific: Install dependencies
install_dependencies_suse() {
    echo "Installing dependencies for SUSE-based distribution..."
    zypper refresh
    zypper install -y curl iptables iproute2 ethtool conntrack-tools socat cri-tools || true
}