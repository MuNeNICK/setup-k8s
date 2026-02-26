#!/bin/sh

# Setup CRI-O for SUSE
setup_crio_suse() {
    log_info "Setting up CRI-O for SUSE..."

    # Determine CRI-O version series matching K8s (e.g., 1.32)
    local crio_series
    crio_series=$(_k8s_minor_version "$K8S_VERSION")

    # Add CRI-O repository (same pkgs.k8s.io RPM endpoint used by RHEL)
    log_info "Adding CRI-O v${crio_series} repository..."
    rpm --import "https://pkgs.k8s.io/addons:/cri-o:/stable:/v${crio_series}/rpm/repodata/repomd.xml.key"
    zypper removerepo cri-o 2>/dev/null || true
    zypper addrepo --gpgcheck "https://pkgs.k8s.io/addons:/cri-o:/stable:/v${crio_series}/rpm/" cri-o

    zypper --non-interactive refresh
    if ! zypper --non-interactive install -y --replacefiles --allow-vendor-change cri-o; then
        log_error "CRI-O installation failed. It may require specific repositories on your SUSE version."
        return 1
    fi
    _finalize_crio_setup
}
