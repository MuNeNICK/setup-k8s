#!/bin/bash

# Cached RHEL package manager detection (also defined in dependencies.sh)
_rhel_pkg_mgr() { echo "${_RHEL_PKG_MGR:=$(command -v dnf &>/dev/null && echo dnf || echo yum)}"; }

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
    $PKG_MGR remove -y cri-o 2>/dev/null || true
    $PKG_MGR autoremove -y || true

    # Remove repository files
    log_info "Removing repository files..."
    rm -f /etc/yum.repos.d/kubernetes.repo
    rm -f /etc/yum.repos.d/cri-o.repo
    rm -f /etc/yum.repos.d/docker-ce.repo

    $PKG_MGR clean all

    # Verify cleanup
    local remaining=0
    local remaining_pkgs
    remaining_pkgs=$($PKG_MGR list installed 2>/dev/null | grep -E "^(kubeadm|kubelet|kubectl|kubernetes-cni)\." || true)
    if [ -n "$remaining_pkgs" ]; then
        log_warn "Some Kubernetes packages still remain:"
        echo "$remaining_pkgs"
        remaining=1
    fi
    _verify_cleanup $remaining \
        "/etc/yum.repos.d/kubernetes.repo" \
        "/etc/default/kubelet"
}
