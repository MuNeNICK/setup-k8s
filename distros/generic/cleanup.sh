#!/bin/bash

# Generic cleanup: remove binaries, configs, and service files placed by the script.
# System packages installed via dependencies.sh are intentionally preserved.

cleanup_generic() {
    log_info "Performing generic distro cleanup..."

    # Remove Kubernetes binaries
    local k8s_bins=(kubeadm kubectl kubelet)
    for bin in "${k8s_bins[@]}"; do
        if [ -f "/usr/local/bin/$bin" ]; then
            rm -f "/usr/local/bin/$bin"
            log_info "Removed /usr/local/bin/$bin"
        fi
    done

    # Remove containerd/runc binaries
    local cri_bins=(containerd containerd-shim-runc-v2 ctr runc)
    for bin in "${cri_bins[@]}"; do
        if [ -f "/usr/local/bin/$bin" ]; then
            rm -f "/usr/local/bin/$bin"
            log_info "Removed /usr/local/bin/$bin"
        fi
    done

    # Remove CRI-O related binaries
    local crio_bins=(crio conmon conmonrs crun crictl)
    for bin in "${crio_bins[@]}"; do
        if [ -f "/usr/local/bin/$bin" ]; then
            rm -f "/usr/local/bin/$bin"
            log_info "Removed /usr/local/bin/$bin"
        fi
    done

    # Remove CNI plugins (unless --preserve-cni)
    if [ "${PRESERVE_CNI:-false}" = false ]; then
        if [ -d /opt/cni/bin ]; then
            rm -rf /opt/cni/bin
            log_info "Removed /opt/cni/bin/"
        fi
    else
        log_info "Preserving CNI plugins as requested."
    fi

    # Remove CRI-O configuration directories
    for dir in /etc/crio /etc/containers; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            log_info "Removed $dir/"
        fi
    done

    # Remove service files based on init system
    case "$(_detect_init_system)" in
        systemd)
            local units=(kubelet.service containerd.service crio.service)
            for unit in "${units[@]}"; do
                if [ -f "/etc/systemd/system/$unit" ]; then
                    rm -f "/etc/systemd/system/$unit"
                    log_info "Removed /etc/systemd/system/$unit"
                fi
            done
            if [ -d /etc/systemd/system/kubelet.service.d ]; then
                rm -rf /etc/systemd/system/kubelet.service.d
                log_info "Removed /etc/systemd/system/kubelet.service.d/"
            fi
            _service_reload
            ;;
        openrc)
            local initscripts=(kubelet containerd crio)
            for svc in "${initscripts[@]}"; do
                rc-update del "$svc" default 2>/dev/null || true
                if [ -f "/etc/init.d/$svc" ]; then
                    rm -f "/etc/init.d/$svc"
                    log_info "Removed /etc/init.d/$svc"
                fi
            done
            ;;
    esac

    log_info "Generic distro cleanup complete."
}
