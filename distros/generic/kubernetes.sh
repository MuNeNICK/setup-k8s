#!/bin/bash

# Setup Kubernetes via direct binary download for generic distributions.

# Resolve full patch version from MAJOR.MINOR (e.g. 1.32 -> 1.32.3)
_resolve_k8s_patch_version() {
    local minor="$1"
    curl -fsSL --retry 3 --retry-delay 2 "https://dl.k8s.io/release/stable-${minor}.txt" | tr -d 'v'
}

# Download and install a single K8s binary with checksum verification
_install_k8s_binary() {
    local binary="$1" version="$2"
    local arch
    arch=$(_detect_arch)
    local url="https://dl.k8s.io/release/v${version}/bin/linux/${arch}/${binary}"
    local dest="/usr/local/bin/${binary}"
    _download_with_checksum "$url" "$dest" "${url}.sha256"
}

# Install CNI plugins
_install_cni_plugins_generic() {
    local version="${CNI_PLUGINS_VERSION}"
    local arch
    arch=$(_detect_arch)
    local url="https://github.com/containernetworking/plugins/releases/download/v${version}/cni-plugins-linux-${arch}-v${version}.tgz"
    local checksum_url="${url}.sha256"
    local tmp="/tmp/cni-plugins.tgz"
    _download_with_checksum "$url" "$tmp" "$checksum_url"
    mkdir -p /opt/cni/bin
    tar -xzf "$tmp" -C /opt/cni/bin/
    rm -f "$tmp"
    log_info "CNI plugins v${version} installed to /opt/cni/bin/"
}

# Install kubelet service file (systemd unit or OpenRC init script)
_install_kubelet_service() {
    case "$(_detect_init_system)" in
        systemd)
            cat > /etc/systemd/system/kubelet.service <<'UNIT'
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
            mkdir -p /etc/systemd/system/kubelet.service.d
            cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<'DROPIN'
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
DROPIN
            _service_reload
            _service_enable kubelet
            ;;
        openrc)
            cat > /etc/init.d/kubelet <<'INITD'
#!/sbin/openrc-run
name="kubelet"
description="Kubernetes Node Agent"
command="/usr/local/bin/kubelet"
command_args="--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
  --kubeconfig=/etc/kubernetes/kubelet.conf \
  --config=/var/lib/kubelet/config.yaml"
command_background=true
pidfile="/run/kubelet.pid"
output_log="/var/log/kubelet.log"
error_log="/var/log/kubelet.log"

depend() {
    need net localmount
    use cgroups
    after containerd crio
}

start_pre() {
    if [ -f /var/lib/kubelet/kubeadm-flags.env ]; then
        . /var/lib/kubelet/kubeadm-flags.env
        command_args="$command_args $KUBELET_KUBEADM_ARGS"
    fi
    if [ -f /etc/default/kubelet ]; then
        . /etc/default/kubelet
        command_args="$command_args $KUBELET_EXTRA_ARGS"
    fi
}
INITD
            chmod +x /etc/init.d/kubelet
            _service_enable kubelet
            ;;
    esac
}

# Main setup function
setup_kubernetes_generic() {
    log_info "Setting up Kubernetes via binary download (generic distro)..."

    # Resolve full patch version
    local patch_version
    patch_version=$(_resolve_k8s_patch_version "$K8S_VERSION")
    if [ -z "$patch_version" ]; then
        log_error "Failed to resolve patch version for K8s ${K8S_VERSION}"
        return 1
    fi
    log_info "Resolved Kubernetes version: v${patch_version}"

    # Install CNI plugins (unless CRI-O was used, which bundles its own)
    if [ "$CRI" != "crio" ]; then
        _install_cni_plugins_generic
    fi

    # Download K8s binaries
    log_info "Downloading Kubernetes binaries v${patch_version}..."
    _install_k8s_binary kubeadm "$patch_version"
    _install_k8s_binary kubelet "$patch_version"
    _install_k8s_binary kubectl "$patch_version"

    # Install kubelet service
    _install_kubelet_service

    log_info "Kubernetes v${patch_version} binaries installed to /usr/local/bin/"
}

# Upgrade kubeadm for generic distributions
upgrade_kubeadm_generic() {
    local target="$1"
    log_info "Upgrading kubeadm to v${target}..."
    _install_k8s_binary kubeadm "$target"
}

# Upgrade kubelet and kubectl for generic distributions
upgrade_kubelet_kubectl_generic() {
    local target="$1"
    log_info "Upgrading kubelet and kubectl to v${target}..."
    _install_k8s_binary kubelet "$target"
    _install_k8s_binary kubectl "$target"
}
