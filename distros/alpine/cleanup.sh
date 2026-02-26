#!/bin/sh

# Alpine Linux specific cleanup
cleanup_alpine() {
    log_info "Performing Alpine Linux specific cleanup..."

    # Remove Kubernetes packages
    log_info "Removing Kubernetes packages..."
    for pkg in kubeadm kubelet kubectl; do
        if apk info -e "$pkg" >/dev/null 2>&1; then
            log_info "Removing $pkg..."
            apk del "$pkg" || log_warn "Failed to remove $pkg"
        fi
    done

    # Remove CRI-O packages if installed
    for pkg in cri-o cri-o-openrc; do
        if apk info -e "$pkg" >/dev/null 2>&1; then
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
    local remaining
    remaining=$(_verify_packages_removed "apk info -e" kubeadm kubelet kubectl cri-o)
    _verify_cleanup $remaining \
        "/etc/default/kubelet" \
        "/etc/local.d/k8s-shared-mount.start"
}
