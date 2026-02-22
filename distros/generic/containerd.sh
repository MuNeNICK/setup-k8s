#!/bin/bash

# Install containerd + runc via direct binary download for generic distributions.

_install_runc_generic() {
    local arch
    arch=$(_detect_arch)
    local url="https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.${arch}"
    # runc does not provide checksum files
    _download_binary "$url" "/usr/local/bin/runc"
}

_install_containerd_generic() {
    local arch
    arch=$(_detect_arch)
    local version="${CONTAINERD_VERSION}"
    local url="https://github.com/containerd/containerd/releases/download/v${version}/containerd-${version}-linux-${arch}.tar.gz"
    local checksum_url="${url}.sha256sum"
    local tmp="/tmp/containerd.tar.gz"

    _download_with_checksum "$url" "$tmp" "$checksum_url"
    # Extract only the binaries we need into /usr/local/bin/
    tar --strip-components=1 -C /usr/local/bin/ -xzf "$tmp" \
        bin/containerd bin/containerd-shim-runc-v2 bin/ctr
    rm -f "$tmp"
}

_install_containerd_service_generic() {
    case "$(_detect_init_system)" in
        systemd)
            cat > /etc/systemd/system/containerd.service <<'UNIT'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
UNIT
            _service_reload
            _service_enable containerd
            ;;
        openrc)
            cat > /etc/init.d/containerd <<'INITD'
#!/sbin/openrc-run
name="containerd"
description="Containerd container runtime"
command="/usr/local/bin/containerd"
command_background=true
pidfile="/run/containerd.pid"
output_log="/var/log/containerd.log"
error_log="/var/log/containerd.log"
depend() { need net localmount; use cgroups; }
INITD
            chmod +x /etc/init.d/containerd
            _service_enable containerd
            ;;
    esac
}

setup_containerd_generic() {
    log_info "Installing containerd ${CONTAINERD_VERSION} and runc ${RUNC_VERSION} (binary download)..."

    _install_runc_generic
    _install_containerd_generic
    _install_containerd_service_generic

    # Start containerd before configuring (containerd config default needs the binary running)
    _service_start containerd

    configure_containerd_toml
    configure_crictl
}
