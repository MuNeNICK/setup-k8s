#!/bin/bash

# RHEL/CentOS/Fedora specific cleanup
cleanup_rhel() {
    echo "Performing RHEL/CentOS/Fedora specific cleanup..."
    
    # Determine package manager (dnf or yum)
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
        VERSIONLOCK="versionlock"
    else
        PKG_MGR="yum"
        VERSIONLOCK="versionlock"
    fi
    
    echo "Using package manager: $PKG_MGR"
    
    # Check for iptables
    if ! command -v iptables &> /dev/null; then
        echo "Warning: iptables command not found, some cleanup steps may be skipped"
    fi
    
    # Remove version locks
    echo "Removing version locks..."
    $PKG_MGR $VERSIONLOCK delete kubeadm kubectl kubelet || true
    
    # Remove packages
    echo "Removing Kubernetes packages..."
    $PKG_MGR remove -y kubeadm kubectl kubelet kubernetes-cni || true
    echo "Removing CRI-O package if installed..."
    $PKG_MGR remove -y cri-o || true
    
    # Clean up dependencies
    echo "Removing unnecessary dependencies..."
    $PKG_MGR autoremove -y || true
    
    # Remove repository files
    echo "Removing Kubernetes repository files..."
    rm -f /etc/yum.repos.d/kubernetes.repo
    rm -f /etc/yum.repos.d/cri-o.repo
    
    # Clean up Docker repository if it exists
    if [ -f /etc/yum.repos.d/docker-ce.repo ]; then
        echo "Removing Docker repository..."
        rm -f /etc/yum.repos.d/docker-ce.repo
    fi
    
    # Final cleanup
    echo "Performing final cleanup..."
    $PKG_MGR clean all
    
    # Verify cleanup
    echo -e "\nVerifying cleanup..."
    remaining_files=0
    
    # Check for remaining packages
    if $PKG_MGR list installed | grep -E "kube|kubernetes" > /dev/null; then
        echo "Warning: Some Kubernetes packages still remain:"
        $PKG_MGR list installed | grep -E "kube|kubernetes"
        remaining_files=1
    fi
    
    # Check for remaining files
    for file in "/etc/yum.repos.d/kubernetes.repo" \
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

# Pre-cleanup steps specific to RHEL
cleanup_pre_rhel() {
    echo "Resetting cluster state..."
    kubeadm reset -f || true
    rm -rf /etc/cni/net.d/* || true
    rm -rf /var/lib/cni/ || true
}