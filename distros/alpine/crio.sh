#!/bin/sh

# Setup CRI-O for Alpine Linux
setup_crio_alpine() {
    log_info "Installing CRI-O on Alpine Linux..."

    apk add --no-cache cri-o cri-o-openrc

    # Configure CRI-O for cgroupfs (no systemd on Alpine)
    _write_crio_config "10-alpine.conf" "cgroupfs"

    # Create CNI configuration directory
    mkdir -p /etc/cni/net.d

    _finalize_crio_setup
}
