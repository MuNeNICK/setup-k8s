#!/bin/sh

# Generic cleanup: remove binaries, configs, and service files placed by the script.
# System packages installed via dependencies.sh are intentionally preserved.

cleanup_generic() {
    log_info "Performing generic distro cleanup..."

    # Remove Kubernetes binaries
    for bin in kubeadm kubectl kubelet; do
        if [ -f "/usr/local/bin/$bin" ]; then
            rm -f "/usr/local/bin/$bin"
            log_info "Removed /usr/local/bin/$bin"
        fi
    done

    # Remove containerd/runc binaries
    for bin in containerd containerd-shim-runc-v2 ctr runc; do
        if [ -f "/usr/local/bin/$bin" ]; then
            rm -f "/usr/local/bin/$bin"
            log_info "Removed /usr/local/bin/$bin"
        fi
    done

    # Remove CRI-O related binaries
    for bin in crio conmon conmonrs crun crictl; do
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
            for unit in kubelet.service containerd.service crio.service; do
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
            for svc in kubelet containerd crio; do
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
