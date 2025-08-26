#!/bin/bash

# Arch Linux specific: Install dependencies
install_dependencies_arch() {
    echo "Installing dependencies for Arch-based distribution..."
    
    # Check if iptables-nft is already installed or if CRI-O will be used
    # iptables-nft uses nftables backend and includes nftables as dependency
    if pacman -Qi iptables-nft &>/dev/null; then
        echo "Note: iptables-nft detected (uses nftables backend)"
        # Don't install regular iptables to avoid conflicts
        pacman -Sy --noconfirm curl conntrack-tools socat ethtool iproute2 crictl || true
    elif [ "$CRI" = "crio" ]; then
        # For CRI-O, install iptables-nft directly to avoid later replacement
        echo "Installing iptables-nft for CRI-O compatibility..."
        pacman -Sy --noconfirm curl conntrack-tools socat ethtool iproute2 crictl || true
        # Remove regular iptables if exists and install iptables-nft
        if pacman -Qi iptables &>/dev/null 2>&1; then
            pacman -Rdd --noconfirm iptables || true
        fi
        pacman -S --noconfirm iptables-nft || true
    else
        # Install base dependencies with regular iptables (for containerd or other CRIs)
        pacman -Sy --noconfirm curl conntrack-tools socat ethtool iproute2 iptables crictl || true
    fi
    
    # Install IPVS packages only if IPVS mode is selected
    if [ "$PROXY_MODE" = "ipvs" ]; then
        echo "Installing IPVS packages for IPVS proxy mode..."
        pacman -Sy --noconfirm ipvsadm ipset || true
    fi
    
    # Install nftables package only if nftables mode is selected
    # Note: nftables might already be installed as dependency of iptables-nft (used by CRI-O)
    if [ "$PROXY_MODE" = "nftables" ]; then
        if ! pacman -Qi nftables &>/dev/null; then
            echo "Installing nftables package for nftables proxy mode..."
            pacman -Sy --noconfirm nftables || true
        else
            echo "nftables already installed (possibly via iptables-nft)"
        fi
    fi
}