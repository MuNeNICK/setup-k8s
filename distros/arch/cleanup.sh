#!/bin/bash

# Arch Linux specific cleanup
cleanup_arch() {
    log_info "Performing Arch Linux specific cleanup..."

    # Remove AUR packages — use -R (not -Rns) to avoid dependency resolution
    # failures when shared deps exist. Orphan cleanup is handled separately.
    log_info "Removing Kubernetes packages from AUR..."
    for pkg in kubeadm-bin kubectl-bin kubelet-bin kubeadm kubectl kubelet; do
        if pacman -Qi "$pkg" &>/dev/null; then
            log_info "Removing $pkg..."
            pacman -Rdd --noconfirm "$pkg" ||
                log_warn "Failed to remove $pkg"
        fi
    done

    # Remove CRI-O package if installed
    if pacman -Qi cri-o &>/dev/null; then
        log_info "Removing cri-o..."
        pacman -Rdd --noconfirm cri-o ||
            log_warn "Failed to remove cri-o"
    fi

    # Remove binaries from /usr/local/bin if they exist
    log_info "Removing Kubernetes binaries from /usr/local/bin..."
    for binary in kubeadm kubectl kubelet; do
        if [ -f "/usr/local/bin/$binary" ]; then
            log_info "Removing /usr/local/bin/$binary..."
            rm -f "/usr/local/bin/$binary"
        fi
    done

    # Remove systemd service files if they were manually created
    if [ -f "/etc/systemd/system/kubelet.service" ]; then
        log_info "Removing manually created kubelet service file..."
        rm -f "/etc/systemd/system/kubelet.service"
        rm -rf "/etc/systemd/system/kubelet.service.d"
        systemctl daemon-reload || true
    fi

    # Clean package cache
    log_info "Cleaning package cache..."
    pacman -Sc --noconfirm || true

    # Clear bash command cache before verification
    hash -r

    # Verify cleanup
    local remaining=0
    for pkg in kubeadm-bin kubeadm kubelet-bin kubelet kubectl-bin kubectl cri-o; do
        if pacman -Qi "$pkg" &>/dev/null; then
            log_warn "Package still installed: $pkg"
            remaining=1
        fi
    done
    for binary in kubeadm kubectl kubelet; do
        if [ -f "/usr/local/bin/$binary" ] || command -v "$binary" &>/dev/null; then
            log_warn "$binary still exists in PATH"
            remaining=1
        fi
    done
    _verify_cleanup $remaining \
        "/etc/default/kubelet" \
        "/etc/systemd/system/kubelet.service"
}
