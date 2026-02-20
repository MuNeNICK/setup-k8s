#!/bin/bash

# Debian/Ubuntu specific cleanup
cleanup_debian() {
    log_info "Performing Debian/Ubuntu specific cleanup..."
    
    # Remove package holds
    log_info "Removing package holds..."
    for pkg in kubeadm kubectl kubelet kubernetes-cni; do
        apt-mark unhold "$pkg" 2>/dev/null || true
    done

    # Purge packages and clean up dependencies
    log_info "Purging Kubernetes and CRI packages..."
    apt-get purge -y kubeadm kubectl kubelet kubernetes-cni ||
        log_warn "Package purge had errors (some packages may not be installed)"
    apt-get purge -y cri-o cri-o-runc 2>/dev/null || true
    apt-get autoremove -y || true

    # Remove repository files
    log_info "Removing Kubernetes repository files..."
    rm -f /etc/apt/sources.list.d/kubernetes.list
    rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.gpg
    rm -f /etc/apt/sources.list.d/cri-o.list
    rm -f /etc/apt/keyrings/crio-apt-keyring.gpg
    
    # Verify cleanup
    local remaining=0
    local remaining_pkgs
    remaining_pkgs=$(dpkg -l | grep -E "[[:space:]](kubeadm|kubelet|kubectl|kubernetes-cni)[[:space:]]" || true)
    if [ -n "$remaining_pkgs" ]; then
        log_warn "Some Kubernetes packages still remain:"
        echo "$remaining_pkgs"
        remaining=1
    fi
    _verify_cleanup $remaining \
        "/etc/apt/sources.list.d/kubernetes.list" \
        "/etc/apt/keyrings/kubernetes-apt-keyring.gpg" \
        "/etc/default/kubelet"
}
