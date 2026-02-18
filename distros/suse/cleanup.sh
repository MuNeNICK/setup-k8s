#!/bin/bash

# SUSE specific cleanup
cleanup_suse() {
    echo "Performing SUSE specific cleanup..."
    
    # Check for iptables
    if ! command -v iptables &> /dev/null; then
        echo "Warning: iptables command not found, some cleanup steps may be skipped"
    fi
    
    # Remove packages
    echo "Removing Kubernetes packages..."
    zypper remove -y kubeadm kubectl kubelet kubernetes-cni || true
    echo "Removing CRI-O package if installed..."
    zypper remove -y cri-o || true
    
    # Clean up dependencies
    echo "Removing unnecessary dependencies..."
    zypper clean
    
    # Remove repository
    echo "Removing Kubernetes repository..."
    zypper removerepo kubernetes || true
    
    # Remove Docker repository if it exists
    zypper removerepo docker-ce || true
    
    # Verify cleanup
    echo -e "\nVerifying cleanup..."
    remaining_files=0
    
    # Check for remaining packages
    if zypper search -i | grep -E "kube|kubernetes" > /dev/null; then
        echo "Warning: Some Kubernetes packages still remain:"
        zypper search -i | grep -E "kube|kubernetes"
        remaining_files=1
    fi
    
    # Check for remaining files
    if [ -f "/etc/default/kubelet" ]; then
        echo "Warning: File still exists: /etc/default/kubelet"
        remaining_files=1
    fi
    
    if [ $remaining_files -eq 1 ]; then
        echo -e "\nSome files or packages could not be removed. You may want to remove them manually."
    else
        echo -e "\nAll specified components have been successfully removed."
    fi
}

# Pre-cleanup steps specific to SUSE
cleanup_pre_suse() {
    echo "Resetting cluster state..."
    kubeadm reset -f || true
    rm -rf /etc/cni/net.d/* || true
    rm -rf /var/lib/cni/ || true
}