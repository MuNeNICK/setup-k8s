#!/bin/bash

# Module-level state for AUR builder cleanup (must survive function scope for EXIT trap)
_AUR_BUILDER_USER=""
_AUR_BUILDER_DIR=""
_cleanup_aur_builder() {
    [ -n "$_AUR_BUILDER_USER" ] && { userdel -r "$_AUR_BUILDER_USER" 2>/dev/null || true; }
    [ -n "$_AUR_BUILDER_DIR" ] && { rm -rf "$_AUR_BUILDER_DIR" 2>/dev/null || true; }
    _AUR_BUILDER_USER=""
    _AUR_BUILDER_DIR=""
}

# Ensure an AUR helper (yay) is available, with retry logic
# Sets AUR_HELPER variable on success
_ensure_aur_helper() {
    AUR_HELPER=""
    if command -v yay &> /dev/null; then
        AUR_HELPER="yay"
        return 0
    elif command -v paru &> /dev/null; then
        AUR_HELPER="paru"
        return 0
    fi

    log_info "No AUR helper found. Installing yay..."

    _AUR_BUILDER_USER="aur_builder_$$"
    _AUR_BUILDER_DIR=$(mktemp -d /tmp/yay-bin.XXXXXX)
    local TEMP_USER="$_AUR_BUILDER_USER"
    local YAY_BUILD_DIR="$_AUR_BUILDER_DIR"
    _push_cleanup _cleanup_aur_builder
    useradd -m -s /bin/bash "$TEMP_USER"
    chown "$TEMP_USER" "$YAY_BUILD_DIR"

    pacman -S --needed --noconfirm base-devel git

    local YAY_BUILD_SUCCESS=false
    su - "$TEMP_USER" -c "
        cd $(printf '%q' "$YAY_BUILD_DIR")
        for attempt in 1 2 3; do
            rm -rf yay-bin
            if git clone https://aur.archlinux.org/yay-bin.git; then
                cd yay-bin
                if makepkg --noconfirm; then
                    exit 0
                fi
                cd ..
            fi
            echo \"Attempt \$attempt failed. Retrying in 5 seconds...\"
            sleep 5
        done
        exit 1
    " && YAY_BUILD_SUCCESS=true

    if [ "$YAY_BUILD_SUCCESS" = true ] && compgen -G "${YAY_BUILD_DIR}/yay-bin/yay-bin-*.pkg.tar.*" >/dev/null; then
        local pkg_file
        pkg_file=$(compgen -G "${YAY_BUILD_DIR}/yay-bin/yay-bin-*.pkg.tar.*" | head -1)
        if ! pacman -Qp "$pkg_file" >/dev/null 2>&1; then
            log_warn "Built package failed validation"
            YAY_BUILD_SUCCESS=false
        else
            pacman -U --noconfirm "$pkg_file" || YAY_BUILD_SUCCESS=false
        fi
    fi

    _cleanup_aur_builder
    _pop_cleanup

    if [ "$YAY_BUILD_SUCCESS" = false ] || ! command -v yay &>/dev/null; then
        log_error "yay installation failed."
        AUR_HELPER=""
        return 1
    fi
    AUR_HELPER="yay"
    log_info "yay installed successfully."
}

# Setup Kubernetes for Arch Linux
setup_kubernetes_arch() {
    log_info "Setting up Kubernetes for Arch-based distribution..."

    log_info "Note: Arch AUR packages always install the latest Kubernetes version."

    log_info "Setting up AUR helper for Kubernetes installation..."
    _ensure_aur_helper || return 1

    log_info "Using AUR helper: $AUR_HELPER"
    _aur_install_packages kubeadm-bin kubelet-bin kubectl-bin || return 1

    # Enable and start kubelet
    systemctl enable --now kubelet
}
