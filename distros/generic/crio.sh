#!/bin/bash

# Setup CRI-O for generic distributions
setup_crio_generic() {
    log_warn "Using generic method to set up CRI-O."
    log_warn "This may not work correctly on your distribution."
    log_info "Please install CRI-O manually if needed."
    
    # Try to configure CRI-O if it's installed
    if command -v crio &> /dev/null; then
        log_info "CRI-O found. Attempting basic configuration..."
        systemctl enable --now crio || {
            log_error "Failed to enable and start CRI-O service"
            systemctl status crio --no-pager || true
            return 1
        }
        configure_crictl
    else
        log_warn "CRI-O not found. Please install it manually from:"
        log_info "https://github.com/cri-o/cri-o/blob/main/install.md"
    fi
}