#!/bin/bash

# Detect available package manager (also defined in dependencies.sh)
_detect_generic_pkg_mgr() {
    if command -v apt-get &>/dev/null; then echo "apt-get"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v zypper &>/dev/null; then echo "zypper"
    elif command -v pacman &>/dev/null; then echo "pacman"
    fi
}

# Generic cleanup for unsupported distributions
cleanup_generic() {
    log_warn "Using generic cleanup method for unsupported distribution."

    local pkg_mgr
    pkg_mgr=$(_detect_generic_pkg_mgr)

    if [ -z "$pkg_mgr" ]; then
        log_warn "No supported package manager found. Please remove Kubernetes packages manually."
        return 0
    fi

    log_info "Attempting to remove packages with $pkg_mgr..."
    case "$pkg_mgr" in
        apt-get)
            apt-get purge -y kubeadm kubectl kubelet kubernetes-cni ||
                log_warn "Package purge had errors"
            apt-get purge -y cri-o cri-o-runc ||
                log_warn "CRI-O removal had errors (may not be installed)"
            apt-get autoremove -y || true
            ;;
        dnf|yum)
            $pkg_mgr remove -y kubeadm kubectl kubelet kubernetes-cni ||
                log_warn "Package removal had errors"
            $pkg_mgr remove -y cri-o ||
                log_warn "CRI-O removal had errors (may not be installed)"
            $pkg_mgr autoremove -y || true
            ;;
        zypper)
            zypper --non-interactive remove -y kubeadm kubectl kubelet kubernetes-cni ||
                log_warn "Package removal had errors"
            zypper --non-interactive remove -y cri-o ||
                log_warn "CRI-O removal had errors (may not be installed)"
            ;;
        pacman)
            pacman -Rns --noconfirm kubeadm kubectl kubelet ||
                log_warn "Package removal had errors"
            pacman -Rns --noconfirm cri-o ||
                log_warn "CRI-O removal had errors (may not be installed)"
            ;;
    esac
}
