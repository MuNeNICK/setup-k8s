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
    zypper --non-interactive install --allow-vendor-change -y kubelet kubeadm kubectl cri-tools

    # Pin packages to prevent automatic updates - consistent with Debian apt-mark hold
    log_info "Pinning Kubernetes packages to prevent automatic updates..."
    zypper addlock kubelet kubeadm kubectl || log_warn "zypper addlock failed, packages are not pinned"

    # Enable and start kubelet
    systemctl enable --now kubelet
}