#!/bin/sh

# RHEL/CentOS/Fedora specific cleanup
cleanup_rhel() {
    log_info "Performing RHEL/CentOS/Fedora specific cleanup..."

    local PKG_MGR
    PKG_MGR=$(_rhel_pkg_mgr)

    # Remove version locks
    $PKG_MGR versionlock delete kubeadm kubectl kubelet || true

    # Remove packages
    log_info "Removing Kubernetes and CRI packages..."
    $PKG_MGR remove -y kubeadm kubectl kubelet kubernetes-cni ||
        log_warn "Package removal had errors (some packages may not be installed)"
    $PKG_MGR remove -y cri-o ||
        log_warn "CRI-O removal had errors (may not be installed)"
    $PKG_MGR autoremove -y || true

    # Remove repository files
    log_info "Removing repository files..."
    rm -f /etc/yum.repos.d/kubernetes.repo
    rm -f /etc/yum.repos.d/cri-o.repo
    rm -f /etc/yum.repos.d/docker-ce.repo

    $PKG_MGR clean all

    # Verify cleanup
    local remaining
    remaining=$(_verify_packages_removed "rpm -q" kubeadm kubelet kubectl kubernetes-cni cri-o)
    _verify_cleanup $remaining \
        "/etc/yum.repos.d/kubernetes.repo" \
        "/etc/default/kubelet"
}
