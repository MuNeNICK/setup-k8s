#!/bin/bash

# Enable kernel modules
enable_kernel_modules() {
    echo "Enabling required kernel modules..."
    
    # Basic modules required for all modes
    cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

    modprobe overlay
    modprobe br_netfilter
    
    # Add IPVS modules if IPVS mode is selected
    if [ "$PROXY_MODE" = "ipvs" ]; then
        echo "Enabling IPVS kernel modules..."
        cat >> /etc/modules-load.d/k8s.conf <<EOF
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF
        
        # Load IPVS modules
        modprobe ip_vs || true
        modprobe ip_vs_rr || true
        modprobe ip_vs_wrr || true
        modprobe ip_vs_sh || true
        modprobe nf_conntrack || true
    fi
    
    # Add nftables modules if nftables mode is selected
    if [ "$PROXY_MODE" = "nftables" ]; then
        echo "Enabling nftables kernel modules..."
        cat >> /etc/modules-load.d/k8s.conf <<EOF
nf_tables
nf_tables_ipv4
nf_tables_ipv6
nft_chain_nat_ipv4
nft_chain_nat_ipv6
nf_nat
nf_conntrack
EOF
        
        # Load nftables modules
        modprobe nf_tables || true
        modprobe nf_tables_ipv4 || true
        modprobe nf_tables_ipv6 || true
        modprobe nft_chain_nat_ipv4 || true
        modprobe nft_chain_nat_ipv6 || true
        modprobe nf_nat || true
        modprobe nf_conntrack || true
    fi
}

# Configure network settings
configure_network_settings() {
    echo "Adjusting network settings..."
    cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    sysctl --system
}

# Reset iptables rules
reset_iptables() {
    echo "Resetting iptables rules..."
    if command -v iptables &> /dev/null; then
        iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X || true
    else
        echo "Warning: iptables command not found, skipping iptables reset"
    fi
    
    # Reset IPVS rules if ipvsadm is available
    if command -v ipvsadm &> /dev/null; then
        echo "Resetting IPVS rules..."
        ipvsadm -C || true
    fi
    
    # Reset nftables rules if nft is available
    if command -v nft &> /dev/null; then
        echo "Resetting nftables rules..."
        nft flush ruleset || true
    fi
}

# Check IPVS availability
check_ipvs_availability() {
    local ipvs_available=true
    
    echo "Checking IPVS availability..."
    
    # Check if IPVS modules can be loaded
    if ! modprobe -n ip_vs &>/dev/null; then
        echo "Warning: IPVS kernel module not available"
        ipvs_available=false
    fi
    
    # Check if ipvsadm is installed
    if ! command -v ipvsadm &> /dev/null; then
        echo "Warning: ipvsadm command not found"
        ipvs_available=false
    fi
    
    # Check if ipset is installed
    if ! command -v ipset &> /dev/null; then
        echo "Warning: ipset command not found"
        ipvs_available=false
    fi
    
    if [ "$ipvs_available" = false ] && [ "$PROXY_MODE" = "ipvs" ]; then
        echo "Error: IPVS mode requested but IPVS prerequisites are not met"
        echo "Please ensure ipvsadm and ipset are installed and IPVS kernel modules are available"
        echo "Falling back to iptables mode..."
        PROXY_MODE="iptables"
    fi
    
    return 0
}

# Check nftables availability
check_nftables_availability() {
    local nftables_available=true
    
    echo "Checking nftables availability..."
    
    # Note if iptables-nft is being used (common on Arch with CRI-O)
    if command -v iptables &> /dev/null && iptables --version 2>/dev/null | grep -q nf_tables; then
        echo "Note: iptables-nft detected (iptables using nftables backend)"
    fi
    
    # Check if nftables modules can be loaded
    if ! modprobe -n nf_tables &>/dev/null; then
        echo "Warning: nftables kernel module not available"
        nftables_available=false
    fi
    
    # Check if nft command is installed
    if ! command -v nft &> /dev/null; then
        echo "Warning: nft command not found"
        nftables_available=false
    fi
    
    # Check kernel version (nftables requires >= 3.13, recommended >= 4.14)
    local kernel_version=$(uname -r | cut -d. -f1,2 | tr -d .)
    if [ "$kernel_version" -lt 313 ]; then
        echo "Warning: Kernel version too old for nftables (requires >= 3.13)"
        nftables_available=false
    elif [ "$kernel_version" -lt 414 ]; then
        echo "Warning: Kernel version $kernel_version may have limited nftables support (>= 4.14 recommended)"
    fi
    
    if [ "$nftables_available" = false ] && [ "$PROXY_MODE" = "nftables" ]; then
        echo "Error: nftables mode requested but prerequisites are not met"
        echo "Please ensure nftables package is installed and kernel supports nftables"
        echo "Falling back to iptables mode..."
        PROXY_MODE="iptables"
    fi
    
    return 0
}

# Clean up CNI configurations
cleanup_cni() {
    echo "Removing CNI configurations..."
    rm -rf /etc/cni/net.d/* || true
    rm -rf /var/lib/cni/ || true
}

# Remove kernel module and sysctl configurations
cleanup_network_configs() {
    echo "Removing Kubernetes kernel module and sysctl configurations..."
    rm -f /etc/modules-load.d/k8s.conf || true
    rm -f /etc/sysctl.d/k8s.conf || true
}

# Remove crictl configuration
cleanup_crictl_config() {
    if [ -f /etc/crictl.yaml ]; then
        echo "Removing crictl configuration..."
        rm -f /etc/crictl.yaml || true
    fi
}