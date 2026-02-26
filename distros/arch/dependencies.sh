#!/bin/sh

# Arch Linux specific: Install dependencies
install_dependencies_arch() {
    log_info "Installing dependencies for Arch-based distribution..."

    # Full system upgrade to avoid partial upgrades (pacman -Sy alone is dangerous)
    log_info "Performing full system upgrade (required to avoid partial upgrades on Arch)..."
    pacman -Syu --noconfirm

    # Install common base dependencies
    pacman -S --noconfirm curl sudo conntrack-tools socat ethtool iproute2 crictl

    # Handle iptables variant selection
    if pacman -Qi iptables-nft >/dev/null 2>&1; then
        log_info "iptables-nft already installed (uses nftables backend)"
    elif [ "$CRI" = "crio" ]; then
        # CRI-O requires iptables-nft; --ask 4 auto-resolves conflict with iptables
        log_info "Installing iptables-nft for CRI-O compatibility..."
        pacman -S --noconfirm --ask 4 iptables-nft
    else
        pacman -S --noconfirm iptables
    fi

    install_proxy_mode_packages pacman -S --noconfirm
}
