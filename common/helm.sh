#!/bin/bash

# Helm package manager installation and setup

# Install Helm
install_helm() {
    log_info "Installing Helm package manager..."

    # Download the official installer to a temporary file for inspection
    local installer
    installer=$(mktemp -t get-helm-3-XXXXXX.sh)
    if ! curl -fsSL --retry 3 --retry-delay 2 https://raw.githubusercontent.com/helm/helm/v3.17.1/scripts/get-helm-3 -o "$installer"; then
        log_error "Failed to download Helm installer"
        rm -f "$installer"
        return 1
    fi

    # Execute the installer
    bash "$installer"
    local rc=$?
    rm -f "$installer"
    return $rc
}

# Main function to setup Helm
setup_helm() {
    if [ "$INSTALL_HELM" != true ]; then
        log_info "Helm installation skipped (disabled by configuration)"
        return 0
    fi

    # Check if helm is already installed
    if command -v helm &> /dev/null; then
        log_info "Helm is already installed: $(helm version --short)"
        log_info "Skipping Helm installation"
    else
        # Install Helm
        if ! install_helm; then
            log_warn "Helm installation failed"
            return 1
        fi
    fi

    return 0
}

# Cleanup functions

# Remove Helm binary and configuration
cleanup_helm() {
    log_info "Removing Helm..."
    rm -f /usr/local/bin/helm

    # Remove Helm config/cache directories for relevant users
    local -a _helm_users=(root)
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        _helm_users+=("$SUDO_USER")
    fi
    for _user in "${_helm_users[@]}"; do
        local _home
        _home=$(get_user_home "$_user")
        rm -rf "$_home/.config/helm" "$_home/.helm" "$_home/.cache/helm"
    done

    log_info "Helm has been removed"
}