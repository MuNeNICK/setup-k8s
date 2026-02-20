#!/bin/bash

# Arch: setup CRI-O from official extra repository
setup_crio_arch() {
    log_info "Installing CRI-O on Arch..."

    # cri-o is available in official extra repo — no AUR helper needed
    if ! pacman -S --noconfirm cri-o; then
        log_error "Failed to install cri-o from official repositories"
        return 1
    fi

    # Configure CRI-O before starting
    log_info "Configuring CRI-O..."
    mkdir -p /etc/crio /etc/crio/crio.conf.d

    # Generate default configuration if not exists
    if [ ! -f /etc/crio/crio.conf ]; then
        if ! crio config > /etc/crio/crio.conf; then
            log_warn "Failed to generate CRI-O default config"
        fi
    fi

    # Create CNI configuration directory
    mkdir -p /etc/cni/net.d

    # Enable and start CRI-O
    systemctl daemon-reload
    systemctl enable --now crio || {
        log_error "Failed to start CRI-O service"
        systemctl status crio --no-pager || true
        return 1
    }

    configure_crictl
}
