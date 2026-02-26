#!/bin/sh

# Setup containerd for Arch Linux
setup_containerd_arch() {
    log_info "Setting up containerd for Arch-based distribution..."
    
    # Install containerd
    pacman -S --noconfirm containerd
    
    # Configure containerd
    _finalize_containerd_setup
}