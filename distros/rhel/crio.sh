#!/bin/bash

# Setup CRI-O for RHEL/CentOS/Rocky/Alma/Fedora
setup_crio_rhel() {
    log_info "Setting up CRI-O for RHEL-based distribution..."
    # Determine K8s minor series (e.g., 1.32)
    local crio_series
    crio_series=$(echo "$K8S_VERSION" | awk -F. '{print $1"."$2}')

    local PKG_MGR
    PKG_MGR=$(_rhel_pkg_mgr)

    # Clean previous repo
    rm -f /etc/yum.repos.d/cri-o.repo

    # Add CRI-O repository for the requested version
    log_info "Adding CRI-O v${crio_series} repository from pkgs.k8s.io..."
    local pkgs_key="https://pkgs.k8s.io/addons:/cri-o:/stable:/v${crio_series}/rpm/repodata/repomd.xml.key"
    cat > /etc/yum.repos.d/cri-o.repo <<EOF
[cri-o]
name=CRI-O v${crio_series}
baseurl=https://pkgs.k8s.io/addons:/cri-o:/stable:/v${crio_series}/rpm/
enabled=1
gpgcheck=1
gpgkey=$pkgs_key
EOF

    # Install CRI-O
    if ! $PKG_MGR makecache -y; then
        log_error "Failed to refresh package metadata. Check repository configuration."
        return 1
    fi
    $PKG_MGR install -y cri-o || {
        log_error "Failed to install cri-o from configured repository"
        return 1
    }

    # Ensure CRI-O runs and configure crictl
    systemctl daemon-reload
    systemctl enable --now crio || {
        log_error "Failed to enable and start CRI-O service"
        systemctl status crio --no-pager || true
        return 1
    }
    configure_crictl
}
