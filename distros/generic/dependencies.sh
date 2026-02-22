#!/bin/bash

# Detect available package manager for generic/unsupported distributions.
# Also used by generic/cleanup.sh.
_detect_generic_pkg_mgr() {
    if command -v apt-get &>/dev/null; then echo "apt-get"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v zypper &>/dev/null; then echo "zypper"
    elif command -v pacman &>/dev/null; then echo "pacman"
    elif command -v apk &>/dev/null; then echo "apk"
    fi
}

# Generic: install system dependencies via auto-detected package manager.
# If no package manager is found, check required commands and error if missing.
install_dependencies_generic() {
    local pkg_mgr
    pkg_mgr=$(_detect_generic_pkg_mgr)

    if [ -z "$pkg_mgr" ]; then
        log_warn "No package manager found. Checking required commands..."
        local missing=()
        for cmd in curl socat conntrack; do
            command -v "$cmd" &>/dev/null || missing+=("$cmd")
        done
        if [ ${#missing[@]} -gt 0 ]; then
            log_error "Missing required commands: ${missing[*]}"
            log_error "Install them manually before proceeding."
            exit 1
        fi
        return 0
    fi

    log_info "Installing system dependencies via $pkg_mgr..."
    case "$pkg_mgr" in
        apt-get) apt-get update && apt-get install -y curl socat conntrack ipset kmod ;;
        dnf|yum) $pkg_mgr install -y curl socat conntrack-tools ipset kmod ;;
        zypper)  zypper --non-interactive install curl socat conntrack-tools ipset kmod ;;
        pacman)  pacman -S --noconfirm --needed curl socat conntrack-tools ipset kmod ;;
        apk)     apk add --no-cache curl socat conntrack-tools ipset kmod gcompat ;;
    esac || log_warn "Some packages failed to install"

    # Ensure cgroups are mounted (required by kubelet)
    if [ ! -e /sys/fs/cgroup/cpu ] && [ ! -e /sys/fs/cgroup/cgroup.controllers ]; then
        log_info "Cgroups not mounted — setting up cgroup filesystem..."
        case "$pkg_mgr" in
            apk)
                apk add --no-cache cgroup-tools || true
                if [ -x /etc/init.d/cgroups ]; then
                    rc-service cgroups start || true
                    rc-update add cgroups boot 2>/dev/null || true
                fi
                ;;
        esac
        # Fallback: manual mount if still not available
        if [ ! -e /sys/fs/cgroup/cpu ] && [ ! -e /sys/fs/cgroup/cgroup.controllers ]; then
            mount -t tmpfs cgroup_root /sys/fs/cgroup 2>/dev/null || true
            for subsys in cpu cpuacct memory devices freezer blkio pids; do
                mkdir -p "/sys/fs/cgroup/${subsys}"
                mount -t cgroup -o "${subsys}" "cgroup_${subsys}" "/sys/fs/cgroup/${subsys}" 2>/dev/null || true
            done
        fi
    fi

    # Install proxy-mode-specific packages (best effort)
    case "$pkg_mgr" in
        apt-get) install_proxy_mode_packages apt-get install -y ;;
        dnf|yum) install_proxy_mode_packages "$pkg_mgr" install -y ;;
        zypper)  install_proxy_mode_packages zypper --non-interactive install ;;
        pacman)  install_proxy_mode_packages pacman -S --noconfirm --needed ;;
        apk)     install_proxy_mode_packages apk add --no-cache ;;
    esac 2>/dev/null || true
}
