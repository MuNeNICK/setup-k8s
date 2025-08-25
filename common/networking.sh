#!/bin/bash

# Enable kernel modules
enable_kernel_modules() {
    echo "Enabling required kernel modules..."
    cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

    modprobe overlay
    modprobe br_netfilter
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