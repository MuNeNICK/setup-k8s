#!/bin/bash

# Debian/Ubuntu specific cleanup
cleanup_debian() {
    echo "Performing Debian/Ubuntu specific cleanup..."
    
    # Remove package holds
    echo "Removing package holds..."
    for pkg in kubeadm kubectl kubelet kubernetes-cni; do
        apt-mark unhold $pkg 2>/dev/null || true
    done
    
    # First round: Remove packages normally
    echo "Removing packages (first round)..."
    apt-get remove -y kubeadm kubectl kubelet kubernetes-cni cri-o cri-o-runc || true
    
    # Second round: Purge packages
    echo "Purging packages (second round)..."
    apt-get purge -y kubeadm kubectl kubelet kubernetes-cni cri-o cri-o-runc || true
    
    # Third round: Force purge with dpkg
    echo "Force purging packages (third round)..."
    for pkg in kubeadm kubectl kubelet kubernetes-cni cri-o cri-o-runc; do
        dpkg --force-all --purge $pkg 2>/dev/null || true
    done
    
    # Fourth round: Clean up any remaining configuration packages
    echo "Cleaning up remaining configurations..."
    dpkg -l | awk '/^rc.*(kube|kubernetes|cri-o)/ {print $2}' | xargs -r dpkg --force-all --purge
    
    # Clean up dependencies
    echo "Removing unnecessary dependencies..."
    apt-get autoremove -y || true
    
    # Remove repository files
    echo "Removing Kubernetes repository files..."
    rm -f /etc/apt/sources.list.d/kubernetes.list
    rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.gpg
    rm -f /etc/apt/sources.list.d/cri-o.list
    rm -f /etc/apt/keyrings/crio-apt-keyring.gpg
    
    # Remove dpkg info files
    rm -f /var/lib/dpkg/info/kubelet.* || true
    
    # Update package lists
    echo "Updating package lists..."
    apt-get update || true
    
    # Final cleanup
    echo "Performing final cleanup..."
    apt-get clean
    apt-get autoremove -y || true
    
    # Verify cleanup
    echo -e "\nVerifying cleanup..."
    remaining_files=0
    
    # Check for remaining packages
    if dpkg -l | grep -E "kube|kubernetes" > /dev/null; then
        echo "Warning: Some Kubernetes packages still remain:"
        dpkg -l | grep -E "kube|kubernetes"
        remaining_files=1
    fi
    
    # Check for remaining files
    for file in "/etc/apt/sources.list.d/kubernetes.list" \
               "/etc/apt/keyrings/kubernetes-apt-keyring.gpg" \
               "/etc/default/kubelet"; do
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

# Pre-cleanup steps specific to Debian
cleanup_pre_debian() {
    echo "Resetting cluster state..."
    kubeadm reset -f || true
    rm -rf /etc/cni/net.d/* || true
    rm -rf /var/lib/cni/ || true
}