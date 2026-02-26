#!/bin/sh

# SUSE specific cleanup
cleanup_suse() {
    log_info "Performing SUSE specific cleanup..."

    # Remove package locks before uninstalling (set during setup)
    log_info "Removing package locks..."
    zypper removelock kubelet kubeadm kubectl ||
        log_warn "Failed to remove package locks (may not be set)"

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
    zypper removerepo cri-o || true
    
    # Verify cleanup
    local remaining
    remaining=$(_verify_packages_removed "rpm -q" kubeadm kubelet kubectl kubernetes-cni cri-o)
    _verify_cleanup $remaining "/etc/default/kubelet"
}
