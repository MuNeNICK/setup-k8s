#!/bin/sh

# Setup containerd for Alpine Linux
setup_containerd_alpine() {
    log_info "Setting up containerd for Alpine Linux..."

    apk add --no-cache containerd containerd-openrc

    _service_enable containerd
    _service_start containerd

    _finalize_containerd_setup
}
