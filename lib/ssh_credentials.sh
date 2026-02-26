#!/bin/sh

# SSH credential management: key validation, auto-discovery, password file.
# Session management -> lib/ssh_session.sh | Transport -> lib/ssh.sh

# --- SSH key permission validation ---

# Validate SSH key file permissions (warn if too permissive)
_validate_ssh_key_permissions() {
    if [ -z "$DEPLOY_SSH_KEY" ] || [ ! -f "$DEPLOY_SSH_KEY" ]; then
        return 0
    fi
    local perms
    perms=$(stat -c '%a' "$DEPLOY_SSH_KEY" 2>/dev/null || stat -f '%Lp' "$DEPLOY_SSH_KEY" 2>/dev/null) || return 0
    case "$perms" in
        600|400) ;;
        *)
            log_warn "SSH key '$DEPLOY_SSH_KEY' has permissions $perms (recommend 600 or 400)"
            ;;
    esac
}

# --- SSH key auto-discovery ---

# Auto-discover SSH private key from the invoking user's ~/.ssh/ directory.
# Searches: id_ed25519, id_rsa, id_ecdsa (in order of preference).
# Only sets DEPLOY_SSH_KEY if not already specified and a key file is found.
_auto_discover_ssh_key() {
    # Skip if already explicitly set
    [ -n "$DEPLOY_SSH_KEY" ] && return 0

    # Determine the home directory of the original (pre-sudo) user
    local ssh_home=""
    if [ -n "${SUDO_USER:-}" ]; then
        ssh_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)" || true
        [ -z "$ssh_home" ] && ssh_home="/home/$SUDO_USER"
    else
        ssh_home="${HOME:-}"
    fi
    [ -z "$ssh_home" ] && return 0

    local key_name
    for key_name in id_ed25519 id_rsa id_ecdsa; do
        if [ -f "${ssh_home}/.ssh/${key_name}" ]; then
            DEPLOY_SSH_KEY="${ssh_home}/.ssh/${key_name}"
            log_info "SSH key auto-discovered: $DEPLOY_SSH_KEY"
            return 0
        fi
    done
}

# --- SSH password file support ---

# Load SSH password from a file (validates permissions).
# Usage: _load_ssh_password_file <path>
_load_ssh_password_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        log_error "SSH password file not found: $path"
        return 1
    fi
    local perms
    perms=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null) || true
    case "$perms" in
        600|400) ;;
        *)
            log_error "SSH password file '$path' has permissions $perms (must be 600 or 400)"
            return 1
            ;;
    esac
    DEPLOY_SSH_PASSWORD=$(cat "$path")
    if [ -z "$DEPLOY_SSH_PASSWORD" ]; then
        log_error "SSH password file '$path' is empty"
        return 1
    fi
}
