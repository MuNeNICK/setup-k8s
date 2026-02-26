#!/bin/sh

# Configure Kubernetes zypper repository for a given MAJOR.MINOR version.
# Usage: _configure_k8s_zypper_repo <version>
_configure_k8s_zypper_repo() {
    local ver="$1"
    rpm --import "https://pkgs.k8s.io/core:/stable:/v${ver}/rpm/repodata/repomd.xml.key"
    zypper removerepo kubernetes 2>/dev/null || true
    zypper addrepo --gpgcheck "https://pkgs.k8s.io/core:/stable:/v${ver}/rpm/" kubernetes
    zypper --non-interactive refresh
}

# Setup Kubernetes for SUSE
setup_kubernetes_suse() {
    log_info "Setting up Kubernetes for SUSE-based distribution..."

    _configure_k8s_zypper_repo "$K8S_VERSION"

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
    _enable_and_start_kubelet
}

# Upgrade kubeadm to a specific MAJOR.MINOR.PATCH version
upgrade_kubeadm_suse() {
    local target="$1"
    local minor
    minor=$(_k8s_minor_version "$target")

    log_info "Updating Kubernetes zypper repository to v${minor}..."
    _configure_k8s_zypper_repo "$minor"

    zypper removelock kubeadm 2>/dev/null || true
    zypper --non-interactive install --allow-vendor-change --replacefiles -y kubeadm
    zypper addlock kubeadm 2>/dev/null || log_warn "zypper addlock failed for kubeadm"
}

# Upgrade kubelet and kubectl to a specific MAJOR.MINOR.PATCH version
upgrade_kubelet_kubectl_suse() {
    local target="$1"

    zypper removelock kubelet kubectl 2>/dev/null || true
    zypper --non-interactive install --allow-vendor-change --replacefiles -y kubelet kubectl
    zypper addlock kubelet kubectl 2>/dev/null || log_warn "zypper addlock failed for kubelet/kubectl"
}