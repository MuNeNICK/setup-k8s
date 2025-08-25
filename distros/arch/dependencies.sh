#!/bin/bash

# Arch Linux specific: Install dependencies
install_dependencies_arch() {
    echo "Installing dependencies for Arch-based distribution..."
    pacman -Sy --noconfirm curl conntrack-tools socat ethtool iproute2 iptables crictl || true
}