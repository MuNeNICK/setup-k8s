#!/bin/sh

# _rhel_pkg_mgr is defined in dependencies.sh (loaded before this module)

# Setup Kubernetes for RHEL/CentOS/Fedora
setup_kubernetes_rhel() {
    log_info "Setting up Kubernetes for RHEL-based distribution..."

    local PKG_MGR
    PKG_MGR=$(_rhel_pkg_mgr)
    log_info "Using package manager: $PKG_MGR"
    
    # Add Kubernetes repository
    log_info "Adding Kubernetes repository for version ${K8S_VERSION}..."
    cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF
    
    # Install Kubernetes components (cri-tools lives in the K8s repo, so install it here)
    log_info "Installing Kubernetes components..."
    $PKG_MGR install -y kubelet kubeadm kubectl cri-tools
    
    # Check if installation was successful
    if ! command -v kubeadm >/dev/null 2>&1; then
        log_error "Kubernetes package installation failed."
        log_error "Ensure the repository GPG key is trusted and the repo is accessible."
        return 1
    fi
    
    # Hold packages (prevent automatic updates) - consistent with Debian apt-mark hold
    log_info "Pinning Kubernetes packages to prevent automatic updates..."
    local versionlock_pkg="python3-dnf-plugin-versionlock"
    [ "$PKG_MGR" = "yum" ] && versionlock_pkg="yum-plugin-versionlock"
    if $PKG_MGR install -y "$versionlock_pkg"; then
        $PKG_MGR versionlock add kubelet kubeadm kubectl || log_warn "versionlock failed"
    else
        log_warn "versionlock plugin not available, packages are not pinned"
    fi

    # Enable and start kubelet
    _service_enable kubelet
    _service_start kubelet
}

# Upgrade kubeadm to a specific MAJOR.MINOR.PATCH version
upgrade_kubeadm_rhel() {
    local target="$1"
    local minor
    minor=$(_version_minor "$target")

    local PKG_MGR
    PKG_MGR=$(_rhel_pkg_mgr)

    log_info "Updating Kubernetes yum repository to v${minor}..."
    cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${minor}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${minor}/rpm/repodata/repomd.xml.key
EOF

    # Remove version lock, upgrade, re-lock
    $PKG_MGR versionlock delete kubeadm 2>/dev/null || true
    $PKG_MGR install -y kubeadm
    $PKG_MGR versionlock add kubeadm 2>/dev/null || log_warn "versionlock failed for kubeadm"
}

# Upgrade kubelet and kubectl to a specific MAJOR.MINOR.PATCH version
upgrade_kubelet_kubectl_rhel() {
    local target="$1"

    local PKG_MGR
    PKG_MGR=$(_rhel_pkg_mgr)

    $PKG_MGR versionlock delete kubelet kubectl 2>/dev/null || true
    $PKG_MGR install -y kubelet kubectl
    $PKG_MGR versionlock add kubelet kubectl 2>/dev/null || log_warn "versionlock failed for kubelet/kubectl"
}