#!/bin/sh

# AUR helper infrastructure for Arch Linux.
# Provides: _ensure_aur_helper, _aur_install_packages
# Used by: distros/arch/kubernetes.sh

# Module-level state for AUR builder cleanup (must survive function scope for EXIT trap)
_AUR_BUILDER_USER=""
_AUR_BUILDER_DIR=""
_cleanup_aur_builder() {
    [ -n "$_AUR_BUILDER_USER" ] && { userdel -r "$_AUR_BUILDER_USER" 2>/dev/null || true; }
    [ -n "$_AUR_BUILDER_DIR" ] && { rm -rf "$_AUR_BUILDER_DIR" 2>/dev/null || true; }
    _AUR_BUILDER_USER=""
    _AUR_BUILDER_DIR=""
}

# Install AUR packages via a temporary unprivileged user with scoped sudo.
# Requires AUR_HELPER to be set (see _ensure_aur_helper below).
# Usage: _aur_install_packages <package...>
_AUR_INSTALLER_USER=""
_AUR_INSTALLER_SUDOERS=""
_cleanup_aur_installer() {
    [ -n "$_AUR_INSTALLER_SUDOERS" ] && rm -f "$_AUR_INSTALLER_SUDOERS"
    [ -n "$_AUR_INSTALLER_USER" ] && { userdel -r "$_AUR_INSTALLER_USER" 2>/dev/null || true; }
    _AUR_INSTALLER_USER=""
    _AUR_INSTALLER_SUDOERS=""
}

_aur_install_packages() {
    _AUR_INSTALLER_USER="aur_installer_$$"
    _AUR_INSTALLER_SUDOERS="/etc/sudoers.d/99-${_AUR_INSTALLER_USER}"
    local tmp_user="$_AUR_INSTALLER_USER"
    local sudoers_file="$_AUR_INSTALLER_SUDOERS"
    _push_cleanup _cleanup_aur_installer
    useradd -m -s /bin/bash "$tmp_user"

    local rc=0

    # Build sudoers: -S rule for direct install, -U rule with cache globs for built packages
    cat > "$sudoers_file" <<SUDOERS_EOF
Defaults:$tmp_user secure_path="/usr/bin:/usr/sbin"
$tmp_user ALL=(ALL) NOPASSWD: /usr/bin/pacman *
SUDOERS_EOF
    chmod 0440 "$sudoers_file"
    local _visudo_err
    if ! _visudo_err=$(visudo -cf "$sudoers_file" 2>&1); then
        log_error "Generated sudoers file is invalid: $_visudo_err"
        rc=1
    fi

    # Disable debug package generation (default in modern makepkg) to avoid
    # install failures when yay tries to batch-install main + debug packages
    su - "$tmp_user" -c 'echo "OPTIONS+=(!debug)" >> ~/.makepkg.conf'

    if [ "$rc" -eq 0 ]; then
        log_info "Installing AUR packages: $*..."
        if ! su - "$tmp_user" -c "$AUR_HELPER -S --noconfirm --needed $*"; then
            log_error "AUR installation failed for: $*"
            rc=1
        fi
    fi

    _cleanup_aur_installer
    _pop_cleanup
    return "$rc"
}

# Ensure an AUR helper (yay) is available, with retry logic
# Sets AUR_HELPER variable on success
_ensure_aur_helper() {
    AUR_HELPER=""
    if command -v yay >/dev/null 2>&1; then
        AUR_HELPER="yay"
        return 0
    elif command -v paru >/dev/null 2>&1; then
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
        cd $YAY_BUILD_DIR
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

    local pkg_file=""
    if [ "$YAY_BUILD_SUCCESS" = true ]; then
        pkg_file=$(ls "${YAY_BUILD_DIR}"/yay-bin/yay-bin-*.pkg.tar.* 2>/dev/null | head -1)
    fi
    if [ "$YAY_BUILD_SUCCESS" = true ] && [ -n "$pkg_file" ]; then
        if ! pacman -Qp "$pkg_file" >/dev/null 2>&1; then
            log_warn "Built package failed validation"
            YAY_BUILD_SUCCESS=false
        else
            pacman -U --noconfirm "$pkg_file" || YAY_BUILD_SUCCESS=false
        fi
    fi

    _cleanup_aur_builder
    _pop_cleanup

    if [ "$YAY_BUILD_SUCCESS" = false ] || ! command -v yay >/dev/null 2>&1; then
        log_error "yay installation failed."
        AUR_HELPER=""
        return 1
    fi
    AUR_HELPER="yay"
    log_info "yay installed successfully."
}
