#!/bin/bash

# Detect available package manager for generic/unsupported distributions.
# Also used by generic/cleanup.sh.
_detect_generic_pkg_mgr() {
    if command -v apt-get &>/dev/null; then echo "apt-get"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v zypper &>/dev/null; then echo "zypper"
    elif command -v pacman &>/dev/null; then echo "pacman"
    fi
}

# Generic functions for unsupported distributions
install_dependencies_generic() {
    log_warn "Using generic method to install dependencies."
    log_warn "This may not work correctly on your distribution."

    local PKG_MGR
    PKG_MGR=$(_detect_generic_pkg_mgr)

    if [ -z "$PKG_MGR" ]; then
        log_warn "No supported package manager found. Please install dependencies manually."
        return 0
    fi

    log_info "Using package manager: $PKG_MGR"

    # Install core dependencies (best effort for generic/unsupported distros)
    case "$PKG_MGR" in
        apt-get)
            if ! { apt-get update && apt-get install -y iptables conntrack socat ethtool iproute2; }; then
                log_warn "Some packages failed to install"
            fi ;;
        dnf|yum)
            if ! $PKG_MGR install -y iptables conntrack-tools socat ethtool iproute; then
                log_warn "Some packages failed to install"
            fi ;;
        zypper)
            if ! zypper --non-interactive install -y iptables conntrack-tools socat ethtool iproute2; then
                log_warn "Some packages failed to install"
            fi ;;
        pacman)
            if ! pacman -S --noconfirm iptables conntrack-tools socat ethtool iproute2 crictl; then
                log_warn "Some packages failed to install"
            fi ;;
    esac

    # Install proxy-mode-specific packages (best effort for generic/unsupported distros)
    case "$PKG_MGR" in
        apt-get) install_proxy_mode_packages apt-get install -y || log_warn "Proxy-mode package install failed" ;;
        dnf|yum) install_proxy_mode_packages "$PKG_MGR" install -y || log_warn "Proxy-mode package install failed" ;;
        zypper)  install_proxy_mode_packages zypper --non-interactive install -y || log_warn "Proxy-mode package install failed" ;;
        pacman)  install_proxy_mode_packages pacman -S --noconfirm || log_warn "Proxy-mode package install failed" ;;
    esac
}
