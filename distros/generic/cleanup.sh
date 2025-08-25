#!/bin/bash

# Generic cleanup for unsupported distributions
cleanup_generic() {
    echo "Warning: Using generic cleanup method for unsupported distribution."
    echo "This may not completely remove all Kubernetes components."
    
    # Check for iptables
    if ! command -v iptables &> /dev/null; then
        echo "Warning: iptables command not found, some cleanup steps may be skipped"
    fi
    
    # Try to remove packages using common package managers
    if command -v apt-get &> /dev/null; then
        echo "Attempting to remove packages with apt-get..."
        apt-get remove -y kubeadm kubectl kubelet kubernetes-cni cri-o cri-o-runc || true
        apt-get purge -y kubeadm kubectl kubelet kubernetes-cni cri-o cri-o-runc || true
        apt-get autoremove -y || true
    elif command -v dnf &> /dev/null; then
        echo "Attempting to remove packages with dnf..."
        dnf remove -y kubeadm kubectl kubelet kubernetes-cni cri-o || true
        dnf autoremove -y || true
    elif command -v yum &> /dev/null; then
        echo "Attempting to remove packages with yum..."
        yum remove -y kubeadm kubectl kubelet kubernetes-cni cri-o || true
        yum autoremove -y || true
    elif command -v zypper &> /dev/null; then
        echo "Attempting to remove packages with zypper..."
        zypper remove -y kubeadm kubectl kubelet kubernetes-cni cri-o || true
    elif command -v pacman &> /dev/null; then
        echo "Attempting to remove packages with pacman..."
        pacman -Rns --noconfirm kubeadm kubectl kubelet cri-o || true
    else
        echo "No supported package manager found. Please remove Kubernetes packages manually."
    fi
    
    echo "Note: You may need to manually remove some components."
}

# Pre-cleanup steps for generic distributions
cleanup_pre_generic() {
    if command -v kubeadm &> /dev/null; then
        kubeadm reset -f || true
    fi
    rm -rf /etc/cni/net.d/* || true
    rm -rf /var/lib/cni/ || true
}