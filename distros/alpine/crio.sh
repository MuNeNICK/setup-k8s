#!/bin/bash

# Setup CRI-O for Alpine Linux
setup_crio_alpine() {
    log_info "Installing CRI-O on Alpine Linux..."

    apk add --no-cache cri-o cri-o-openrc

    # Configure CRI-O for cgroupfs (no systemd on Alpine)
    mkdir -p /etc/crio/crio.conf.d
    cat > /etc/crio/crio.conf.d/10-alpine.conf <<EOF
[crio.runtime]
cgroup_manager = "cgroupfs"

[crio.image]
pause_image = "registry.k8s.io/pause:${PAUSE_IMAGE_VERSION}"
EOF

    # Create CNI configuration directory
    mkdir -p /etc/cni/net.d

    _service_enable crio
    _service_start crio

    configure_crictl
}
