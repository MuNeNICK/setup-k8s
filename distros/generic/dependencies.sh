#!/bin/bash

# Generic functions for unsupported distributions
install_dependencies_generic() {
    echo "Warning: Using generic method to install dependencies."
    echo "This may not work correctly on your distribution."
    echo "Please install the following packages manually if needed:"
    echo "- curl"
    echo "- containerd"
    echo "- kubeadm, kubelet, kubectl"
    echo "- iptables, conntrack, socat, ethtool, iproute2, crictl/cri-tools"
    if [ "$PROXY_MODE" = "ipvs" ]; then
        echo "- ipvsadm, ipset (required for IPVS mode)"
    fi
    if [ "$PROXY_MODE" = "nftables" ]; then
        echo "- nftables (required for nftables mode)"
    fi
    
    # Try to install iptables if not present
    if ! command -v iptables &> /dev/null; then
        echo "Attempting to install iptables..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y iptables
        elif command -v dnf &> /dev/null; then
            dnf install -y iptables
        elif command -v yum &> /dev/null; then
            yum install -y iptables
        elif command -v zypper &> /dev/null; then
            zypper install -y iptables
        elif command -v pacman &> /dev/null; then
            pacman -Sy --noconfirm iptables
        fi
    fi

    # Try to install other useful dependencies if package manager is available
    if command -v apt-get &> /dev/null; then
        apt-get install -y conntrack socat ethtool iproute2 cri-tools || true
        if [ "$PROXY_MODE" = "ipvs" ]; then apt-get install -y ipvsadm ipset || true; fi
        if [ "$PROXY_MODE" = "nftables" ]; then apt-get install -y nftables || true; fi
    elif command -v dnf &> /dev/null; then
        dnf install -y conntrack-tools socat ethtool iproute cri-tools || true
        if [ "$PROXY_MODE" = "ipvs" ]; then dnf install -y ipvsadm ipset || true; fi
        if [ "$PROXY_MODE" = "nftables" ]; then dnf install -y nftables || true; fi
    elif command -v yum &> /dev/null; then
        yum install -y conntrack-tools socat ethtool iproute cri-tools || true
        if [ "$PROXY_MODE" = "ipvs" ]; then yum install -y ipvsadm ipset || true; fi
        if [ "$PROXY_MODE" = "nftables" ]; then yum install -y nftables || true; fi
    elif command -v zypper &> /dev/null; then
        zypper install -y conntrack-tools socat ethtool iproute2 cri-tools || true
        if [ "$PROXY_MODE" = "ipvs" ]; then zypper install -y ipvsadm ipset || true; fi
        if [ "$PROXY_MODE" = "nftables" ]; then zypper install -y nftables || true; fi
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm conntrack-tools socat ethtool iproute2 crictl || true
        if [ "$PROXY_MODE" = "ipvs" ]; then pacman -Sy --noconfirm ipvsadm ipset || true; fi
        if [ "$PROXY_MODE" = "nftables" ]; then pacman -Sy --noconfirm nftables || true; fi
    fi
    
    # Print message about mode-specific packages
    if [ "$PROXY_MODE" = "ipvs" ]; then
        echo "Note: IPVS mode selected. Please ensure ipvsadm and ipset are installed."
    elif [ "$PROXY_MODE" = "nftables" ]; then
        echo "Note: nftables mode selected. Please ensure nftables is installed."
    fi
}