#!/bin/sh

# Cached RHEL package manager detection (shared across all distros/rhel/*.sh)
_rhel_pkg_mgr() { echo "${_RHEL_PKG_MGR:=$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum)}"; }

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
    case "$DISTRO_VERSION" in
        9*)
            if [ "$DISTRO_NAME" = "centos" ]; then
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
            ;;
    esac

    # Install base dependencies
    if ! $PKG_MGR install -y curl gnupg2 iptables iptables-services ethtool iproute conntrack-tools socat ebtables; then
        log_error "Failed to install base dependencies"
        return 1
    fi

    # RHEL-based cloud images (Rocky, AlmaLinux, etc.) ship only kernel-core and
    # kernel-modules-core to minimise image size.  br_netfilter, which Kubernetes
    # requires, is packaged in kernel-modules-extra and therefore absent by default.
    # Install the matching version for the running kernel so that modprobe succeeds.
    if ! modprobe -n br_netfilter >/dev/null 2>&1; then
        local _running_kernel
        _running_kernel=$(uname -r)
        log_info "br_netfilter not available — installing kernel-modules-extra for running kernel ($_running_kernel)..."
        if ! $PKG_MGR install -y "kernel-modules-extra-${_running_kernel}"; then
            log_error "Failed to install kernel-modules-extra-${_running_kernel}"
            return 1
        fi
    fi

    install_proxy_mode_packages "$PKG_MGR" install -y
}