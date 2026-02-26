#!/bin/sh

# _rhel_pkg_mgr is defined in dependencies.sh (loaded before this module)

# Setup containerd for RHEL/CentOS/Fedora
setup_containerd_rhel() {
    log_info "Setting up containerd for RHEL-based distribution..."

    local PKG_MGR
    PKG_MGR=$(_rhel_pkg_mgr)
    log_info "Using package manager: $PKG_MGR"
    
    # Install required packages for repository management
    # Note: dnf-plugins-core / yum-utils are already installed in install_dependencies_rhel
    log_info "Installing storage driver dependencies..."
    if ! $PKG_MGR install -y device-mapper-persistent-data lvm2; then
        log_warn "Some storage driver dependencies failed to install, continuing..."
    fi
    
    # Add Docker repository (for containerd)
    log_info "Adding Docker repository..."
    if [ "$DISTRO_NAME" = "fedora" ]; then
        # Check Fedora version for correct config-manager syntax
        if echo "${DISTRO_VERSION%%.*}" | grep -qE '^[0-9]+$' && [ "${DISTRO_VERSION%%.*}" -ge 41 ]; then
            # Fedora 41+ uses new syntax - download repo file directly
            log_info "Using direct repo file download for Fedora 41+"
            if ! curl -fsSL --retry 3 --retry-delay 2 https://download.docker.com/linux/fedora/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo; then
                log_error "Failed to download Docker repository"
                return 1
            fi
        else
            if ! $PKG_MGR config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo; then
                log_error "Failed to add Docker repository"
                return 1
            fi
        fi
    else
        # For CentOS/RHEL — use distro-specific Docker repo URL
        local docker_repo_distro="centos"
        [ "$DISTRO_NAME" = "rhel" ] && docker_repo_distro="rhel"
        local docker_repo_url="https://download.docker.com/linux/${docker_repo_distro}/docker-ce.repo"
        if [ "$PKG_MGR" = "yum" ]; then
            if ! yum-config-manager --add-repo "$docker_repo_url"; then
                log_error "Failed to add Docker repository"
                return 1
            fi
        else
            if ! $PKG_MGR config-manager --add-repo "$docker_repo_url"; then
                log_error "Failed to add Docker repository"
                return 1
            fi
        fi
    fi
    
    # Install containerd
    log_info "Installing containerd.io package..."
    if [ "$PKG_MGR" = "dnf" ]; then
        if ! $PKG_MGR install -y --setopt=install_weak_deps=False containerd.io; then
            if ! $PKG_MGR install -y --nobest containerd.io; then
                log_error "Failed to install containerd.io. Check that the Docker repository is accessible."
                return 1
            fi
        fi
    else
        if ! $PKG_MGR install -y containerd.io; then
            log_error "Failed to install containerd.io. Check that the Docker repository is accessible."
            return 1
        fi
    fi
    
    # Configure containerd
    _finalize_containerd_setup
}
