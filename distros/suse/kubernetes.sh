#!/bin/bash

# Setup Kubernetes for SUSE
setup_kubernetes_suse() {
    log_info "Setting up Kubernetes for SUSE-based distribution..."
    
    # Import GPG key for Kubernetes repository
    rpm --import "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key"

    # Remove existing Kubernetes repository if present (idempotent re-runs)
    zypper removerepo kubernetes 2>/dev/null || true

    # Add Kubernetes repository with GPG check enabled
    zypper addrepo --gpgcheck "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/" kubernetes
    
    # Install Kubernetes components (non-interactive mode)
    zypper --non-interactive refresh

    # Remove SUSE-distro kubernetes packages that may have been pulled in as CRI-O
    # dependencies (e.g., kubernetes1.24-*) to avoid file conflicts with pkgs.k8s.io packages
    local suse_k8s_pkgs
    suse_k8s_pkgs=$(rpm -qa 'kubernetes1*' | tr '\n' ' ')
    if [ -n "$suse_k8s_pkgs" ]; then
        log_info "Removing SUSE-distro Kubernetes packages to avoid conflicts: $suse_k8s_pkgs"
        # shellcheck disable=SC2086
        if ! zypper --non-interactive remove -y $suse_k8s_pkgs; then
            log_warn "Failed to remove SUSE-distro Kubernetes packages: $suse_k8s_pkgs"
            log_error "Cannot proceed — conflicting packages would cause file conflicts during install"
            return 1
        fi
    fi

    zypper --non-interactive install --allow-vendor-change --replacefiles -y kubelet kubeadm kubectl cri-tools

    # Pin packages to prevent automatic updates - consistent with Debian apt-mark hold
    log_info "Pinning Kubernetes packages to prevent automatic updates..."
    zypper addlock kubelet kubeadm kubectl || log_warn "zypper addlock failed, packages are not pinned"

    # Enable and start kubelet
    systemctl enable --now kubelet
}