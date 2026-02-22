#!/bin/bash

# Alpine Linux specific cleanup
cleanup_alpine() {
    log_info "Performing Alpine Linux specific cleanup..."

    # Remove Kubernetes packages
    log_info "Removing Kubernetes packages..."
    for pkg in kubeadm kubelet kubectl; do
        if apk info -e "$pkg" &>/dev/null; then
            log_info "Removing $pkg..."
            apk del "$pkg" || log_warn "Failed to remove $pkg"
        fi
    done

    # Remove CRI-O packages if installed
    for pkg in cri-o cri-o-openrc; do
        if apk info -e "$pkg" &>/dev/null; then
            log_info "Removing $pkg..."
            apk del "$pkg" || log_warn "Failed to remove $pkg"
        fi
    done

    # Remove shared mount propagation startup script
    if [ -f /etc/local.d/k8s-shared-mount.start ]; then
        log_info "Removing k8s shared mount startup script..."
        rm -f /etc/local.d/k8s-shared-mount.start
    fi

    # Clear bash command cache before verification
    hash -r

    # Verify cleanup
    local remaining=0
    for pkg in kubeadm kubelet kubectl cri-o; do
        if apk info -e "$pkg" &>/dev/null; then
            log_warn "Package still installed: $pkg"
            remaining=1
        fi
    done
    _verify_cleanup $remaining \
        "/etc/default/kubelet" \
        "/etc/local.d/k8s-shared-mount.start"
}
