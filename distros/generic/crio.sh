#!/bin/bash

# Install CRI-O via tarball download for generic distributions.
# The tarball bundles: crio, conmon, conmonrs, runc, crun, crictl, CNI plugins.

_install_crio_generic() {
    local arch
    arch=$(_detect_arch)
    local version="${CRIO_VERSION}"
    local url="https://storage.googleapis.com/cri-o/artifacts/cri-o.${arch}.v${version}.tar.gz"
    local checksum_url="${url}.sha256sum"
    local tmp="/tmp/cri-o.tar.gz"
    local extract_dir="/tmp/cri-o-extract"

    _download_with_checksum "$url" "$tmp" "$checksum_url"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xzf "$tmp" -C "$extract_dir"
    rm -f "$tmp"

    # Find the extracted directory (usually cri-o/)
    local crio_dir
    crio_dir=$(find "$extract_dir" -maxdepth 1 -type d -name 'cri-o' | head -1)
    if [ -z "$crio_dir" ]; then
        crio_dir="$extract_dir"
    fi

    # Install binaries to /usr/local/bin/
    local binaries=(crio conmon conmonrs runc crun crictl)
    for bin in "${binaries[@]}"; do
        local src
        src=$(find "$crio_dir" -name "$bin" -type f 2>/dev/null | head -1)
        if [ -n "$src" ]; then
            install -m 0755 "$src" "/usr/local/bin/$bin"
            log_info "  Installed $bin to /usr/local/bin/"
        fi
    done

    # Install CNI plugins
    mkdir -p /opt/cni/bin
    local cni_dir
    cni_dir=$(find "$crio_dir" -type d -name 'cni-plugins' 2>/dev/null | head -1)
    if [ -n "$cni_dir" ]; then
        install -m 0755 "$cni_dir"/* /opt/cni/bin/ 2>/dev/null || true
        log_info "  Installed CNI plugins to /opt/cni/bin/"
    fi

    # Install CRI-O configuration
    mkdir -p /etc/crio/crio.conf.d
    mkdir -p /etc/containers
    local etc_dir
    etc_dir=$(find "$crio_dir" -type d -name 'etc' 2>/dev/null | head -1)
    if [ -n "$etc_dir" ]; then
        find "$etc_dir" -name '*.conf' -exec cp {} /etc/crio/crio.conf.d/ \; 2>/dev/null || true
        [ -f "$etc_dir/containers/policy.json" ] && cp "$etc_dir/containers/policy.json" /etc/containers/ 2>/dev/null || true
    fi

    rm -rf "$extract_dir"
}

_install_crio_service_generic() {
    case "$(_detect_init_system)" in
        systemd)
            cat > /etc/systemd/system/crio.service <<'UNIT'
[Unit]
Description=Container Runtime Interface for OCI (CRI-O)
Documentation=https://github.com/cri-o/cri-o
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/crio
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Restart=always
RestartSec=5
LimitNOFILE=65536
LimitNPROC=infinity
LimitCORE=infinity
OOMScoreAdjust=-999
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT
            _service_reload
            ;;
        openrc)
            cat > /etc/init.d/crio <<'INITD'
#!/sbin/openrc-run
name="crio"
description="Container Runtime Interface for OCI"
command="/usr/local/bin/crio"
command_background=true
pidfile="/run/crio.pid"
output_log="/var/log/crio.log"
error_log="/var/log/crio.log"
depend() { need net localmount; use cgroups; }
INITD
            chmod +x /etc/init.d/crio
            ;;
    esac
}

setup_crio_generic() {
    log_info "Installing CRI-O ${CRIO_VERSION} (tarball download)..."

    _install_crio_generic
    _install_crio_service_generic

    _service_enable crio
    _service_start crio
    configure_crictl
}
