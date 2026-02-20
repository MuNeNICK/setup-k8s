#!/bin/bash

# Cached RHEL package manager detection (shared across all distros/rhel/*.sh)
_rhel_pkg_mgr() { echo "${_RHEL_PKG_MGR:=$(command -v dnf &>/dev/null && echo dnf || echo yum)}"; }

# RHEL/CentOS/Fedora specific: Install dependencies
install_dependencies_rhel() {
    log_info "Installing dependencies for RHEL-based distribution..."

    local PKG_MGR
    PKG_MGR=$(_rhel_pkg_mgr)
    log_info "Using package manager: $PKG_MGR"

    # Install essential packages including iptables and networking tools
    log_info "Installing essential packages..."
    if [ "$PKG_MGR" = "dnf" ]; then
        if ! $PKG_MGR install -y dnf-plugins-core; then
            log_error "Failed to install dnf-plugins-core"
            return 1
        fi
    else
        if ! $PKG_MGR install -y yum-utils; then
            log_error "Failed to install yum-utils"
            return 1
        fi
    fi

    # For CentOS 9 Stream, enable additional repositories before installing packages
    if [ "$DISTRO_NAME" = "centos" ] && [[ "$DISTRO_VERSION" == "9"* ]]; then
        log_info "Detected CentOS 9 Stream, enabling additional repositories..."
        if ! $PKG_MGR install -y epel-release; then
            log_error "Failed to install epel-release"
            return 1
        fi
        if ! $PKG_MGR config-manager --set-enabled crb && ! $PKG_MGR config-manager --set-enabled powertools; then
            log_error "Failed to enable crb or powertools repository"
            return 1
        fi
    fi

    # Install base dependencies
    if ! $PKG_MGR install -y curl gnupg2 iptables iptables-services ethtool iproute conntrack-tools socat ebtables; then
        log_error "Failed to install base dependencies"
        return 1
    fi

    install_proxy_mode_packages "$PKG_MGR" install -y
}