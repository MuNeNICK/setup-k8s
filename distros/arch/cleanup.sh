#!/bin/bash

# Arch Linux specific cleanup
cleanup_arch() {
    echo "Performing Arch Linux specific cleanup..."
    
    # Check for iptables
    if ! command -v iptables &> /dev/null; then
        echo "Warning: iptables command not found, some cleanup steps may be skipped"
    fi
    
    # Remove AUR packages (with -bin suffix)
    echo "Removing Kubernetes packages from AUR..."
    for pkg in kubeadm-bin kubectl-bin kubelet-bin kubeadm kubectl kubelet; do
        if pacman -Qi $pkg &>/dev/null; then
            echo "Removing $pkg..."
            pacman -Rns --noconfirm $pkg || true
        fi
    done

    # Remove CRI-O package if installed
    if pacman -Qi cri-o &>/dev/null; then
        echo "Removing cri-o..."
        pacman -Rns --noconfirm cri-o || true
    fi
    
    # Remove binaries from /usr/local/bin if they exist
    echo "Removing Kubernetes binaries from /usr/local/bin..."
    for binary in kubeadm kubectl kubelet; do
        if [ -f "/usr/local/bin/$binary" ]; then
            echo "Removing /usr/local/bin/$binary..."
            rm -f "/usr/local/bin/$binary"
        fi
    done
    
    # Remove systemd service files if they were manually created
    if [ -f "/etc/systemd/system/kubelet.service" ]; then
        echo "Removing manually created kubelet service file..."
        rm -f "/etc/systemd/system/kubelet.service"
        rm -rf "/etc/systemd/system/kubelet.service.d"
        systemctl daemon-reload
    fi
    
    # Clean up dependencies
    echo "Removing unnecessary dependencies..."
    pacman -Sc --noconfirm
    
    # Disable zram swap specifically for Arch
    echo "Disabling zram swap on Arch Linux..."
    for service in systemd-zram-setup@zram0.service dev-zram0.swap; do
        if systemctl is-active "$service" &>/dev/null; then
            echo "Stopping $service..."
            systemctl stop "$service"
        fi
        if systemctl is-enabled "$service" &>/dev/null; then
            echo "Disabling $service..."
            systemctl disable "$service"
        fi
        echo "Unmasking $service if it was masked..."
        systemctl unmask "$service" 2>/dev/null || true
    done
    
    # Turn off all swap devices
    swapoff -a
    
    # Remove zram module if loaded
    if lsmod | grep -q zram; then
        echo "Removing zram kernel module..."
        modprobe -r zram || true
    fi
    
    # Verify cleanup
    echo -e "\nVerifying cleanup..."
    remaining_files=0
    
    # Check for remaining packages
    if pacman -Qs kubeadm kubectl kubelet | grep -E "kube|kubernetes" > /dev/null; then
        echo "Warning: Some Kubernetes packages still remain:"
        pacman -Qs kubeadm kubectl kubelet | grep -E "kube|kubernetes"
        remaining_files=1
    fi
    
    # Check for remaining binaries
    for binary in kubeadm kubectl kubelet; do
        if [ -f "/usr/local/bin/$binary" ] || command -v $binary &>/dev/null; then
            echo "Warning: $binary still exists in PATH"
            remaining_files=1
        fi
    done
    
    # Check for remaining files
    for file in "/etc/default/kubelet" "/etc/systemd/system/kubelet.service"; do
        if [ -f "$file" ]; then
            echo "Warning: File still exists: $file"
            remaining_files=1
        fi
    done
    
    if [ $remaining_files -eq 1 ]; then
        echo -e "\nSome files or packages could not be removed. You may want to remove them manually."
    else
        echo -e "\nAll specified components have been successfully removed."
    fi
}

# Pre-cleanup steps specific to Arch
cleanup_pre_arch() {
    echo "Resetting cluster state..."
    kubeadm reset -f || true
    rm -rf /etc/cni/net.d/* || true
    rm -rf /var/lib/cni/ || true
}