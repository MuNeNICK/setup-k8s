#!/bin/bash

# SUSE specific cleanup
cleanup_suse() {
    log_info "Performing SUSE specific cleanup..."

    # Remove package locks before uninstalling (set during setup)
    log_info "Removing package locks..."
    zypper removelock kubelet kubeadm kubectl 2>/dev/null || true

    # Remove packages
    log_info "Removing Kubernetes packages..."
    zypper --non-interactive remove -y kubeadm kubectl kubelet kubernetes-cni ||
        log_warn "Package removal had errors (some packages may not be installed)"
    log_info "Removing CRI-O package if installed..."
    zypper --non-interactive remove -y cri-o ||
        log_warn "CRI-O removal had errors (may not be installed)"

    # Clean up dependencies
    log_info "Removing unnecessary dependencies..."
    zypper --non-interactive clean
    
    # Remove repository
    log_info "Removing Kubernetes repository..."
    zypper removerepo kubernetes || true
    zypper removerepo cri-o 2>/dev/null || true
    
    # Verify cleanup
    local remaining=0
    local remaining_pkgs
    remaining_pkgs=$(zypper search -i 2>/dev/null | grep -E "\|[[:space:]]*(kubeadm|kubelet|kubectl|kubernetes-cni)[[:space:]]" || true)
    if [ -n "$remaining_pkgs" ]; then
        log_warn "Some Kubernetes packages still remain:"
        echo "$remaining_pkgs"
        remaining=1
    fi
    _verify_cleanup $remaining "/etc/default/kubelet"
}
