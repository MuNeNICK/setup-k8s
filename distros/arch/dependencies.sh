#!/bin/bash

# Install AUR packages via a temporary unprivileged user with scoped sudo.
# Requires AUR_HELPER to be set (see _ensure_aur_helper in kubernetes.sh).
# Usage: _aur_install_packages [--yay-flags "FLAGS"] <package...>
_AUR_INSTALLER_USER=""
_AUR_INSTALLER_SUDOERS=""
_cleanup_aur_installer() {
    [ -n "$_AUR_INSTALLER_SUDOERS" ] && rm -f "$_AUR_INSTALLER_SUDOERS"
    [ -n "$_AUR_INSTALLER_USER" ] && { userdel -r "$_AUR_INSTALLER_USER" 2>/dev/null || true; }
    _AUR_INSTALLER_USER=""
    _AUR_INSTALLER_SUDOERS=""
}

_aur_install_packages() {
    local yay_extra_flags=""
    if [ "${1:-}" = "--yay-flags" ]; then
        yay_extra_flags="$2"; shift 2
    fi
    local -a packages=("$@")

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
    if ! visudo -cf "$sudoers_file" >/dev/null 2>&1; then
        log_error "Generated sudoers file is invalid"
        rc=1
    fi

    # Disable debug package generation (default in modern makepkg) to avoid
    # install failures when yay tries to batch-install main + debug packages
    su - "$tmp_user" -c 'echo "OPTIONS+=(!debug)" >> ~/.makepkg.conf'

    if [ "$rc" -eq 0 ]; then
        log_info "Installing AUR packages: ${packages[*]}..."
        if ! su - "$tmp_user" -c "$AUR_HELPER -S --noconfirm --needed $yay_extra_flags ${packages[*]}"; then
            log_error "AUR installation failed for: ${packages[*]}"
            rc=1
        fi
    fi

    _cleanup_aur_installer
    _pop_cleanup
    return "$rc"
}

# Arch Linux specific: Install dependencies
install_dependencies_arch() {
    log_info "Installing dependencies for Arch-based distribution..."

    # Full system upgrade to avoid partial upgrades (pacman -Sy alone is dangerous)
    log_info "Performing full system upgrade (required to avoid partial upgrades on Arch)..."
    pacman -Syu --noconfirm

    # Install common base dependencies
    pacman -S --noconfirm curl sudo conntrack-tools socat ethtool iproute2 crictl

    # Handle iptables variant selection
    if pacman -Qi iptables-nft &>/dev/null; then
        log_info "iptables-nft already installed (uses nftables backend)"
    elif [ "$CRI" = "crio" ]; then
        # CRI-O requires iptables-nft; pacman handles conflict resolution atomically
        log_info "Installing iptables-nft for CRI-O compatibility..."
        pacman -S --noconfirm iptables-nft
    else
        pacman -S --noconfirm iptables
    fi

    install_proxy_mode_packages pacman -S --noconfirm
}
