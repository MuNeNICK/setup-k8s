#!/bin/sh

# Setup containerd for SUSE
setup_containerd_suse() {
    log_info "Setting up containerd for SUSE-based distribution..."
    
    # Prefer official repositories and avoid Docker CE to reduce conflicts
    log_info "Installing containerd from SUSE official repositories..."
    zypper --non-interactive refresh
    if ! zypper --non-interactive install -y containerd; then
        log_error "Failed to install containerd from SUSE repositories"
        return 1
    fi

    # Configure containerd
    configure_containerd_toml
    configure_crictl
}