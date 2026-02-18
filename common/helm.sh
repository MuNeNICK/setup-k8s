#!/bin/bash

# Helm package manager installation and setup

# Install Helm
install_helm() {
    echo "Installing Helm package manager..."

    # Download the official installer to a temporary file for inspection
    local installer
    installer=$(mktemp -t get-helm-3-XXXXXX.sh)
    if ! curl -fsSL --retry 3 --retry-delay 2 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$installer"; then
        echo "Error: Failed to download Helm installer" >&2
        rm -f "$installer"
        return 1
    fi

    # Basic validation: ensure it looks like a shell script
    if ! head -1 "$installer" | grep -q '^#!/'; then
        echo "Error: Downloaded Helm installer does not appear to be a valid shell script" >&2
        rm -f "$installer"
        return 1
    fi

    # Execute the verified installer
    bash "$installer"
    local rc=$?
    rm -f "$installer"
    return $rc
}

# Setup Helm for a specific user
setup_helm_for_user() {
    local user="$1"
    local user_home="$2"
    
    if [ -z "$user" ] || [ -z "$user_home" ]; then
        return 1
    fi
    
    # Create .helm directory for the user
    local helm_dir="$user_home/.config/helm"
    if [ ! -d "$helm_dir" ]; then
        mkdir -p "$helm_dir"
        chown -R "$user:$(id -gn "$user")" "$user_home/.config"
    fi
    
    # Initialize helm for the user (if needed)
    # Modern Helm 3 doesn't require init, but we can set up config
    
    echo "Helm setup completed for user $user"
    return 0
}

# Main function to setup Helm
setup_helm() {
    if [ "$INSTALL_HELM" != true ]; then
        echo "Helm installation skipped (disabled by configuration)"
        return 0
    fi
    
    # Check if helm is already installed
    if command -v helm &> /dev/null; then
        echo "Helm is already installed: $(helm version --short)"
        echo "Skipping Helm installation"
    else
        # Install Helm
        if ! install_helm; then
            echo "Warning: Helm installation failed"
            return 1
        fi
    fi
    
    # Setup for non-root user if running with sudo
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        local user_home="/home/$SUDO_USER"
        setup_helm_for_user "$SUDO_USER" "$user_home"
    fi
    
    # Setup for root user
    setup_helm_for_user "root" "/root"
    
    return 0
}

# Cleanup functions

# Remove Helm binary and configuration
cleanup_helm() {
    echo "Removing Helm..."
    
    # Check if Helm is installed
    if ! command -v helm &> /dev/null; then
        echo "Helm is not installed, skipping cleanup"
        return 0
    fi
    
    # Remove Helm binary
    if [ -f /usr/local/bin/helm ]; then
        echo "Removing Helm binary from /usr/local/bin/helm"
        rm -f /usr/local/bin/helm
    fi
    
    # Remove Helm config directories for users
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        local user_home="/home/$SUDO_USER"
        
        # Remove Helm config directory
        if [ -d "$user_home/.config/helm" ]; then
            echo "Removing Helm config for user $SUDO_USER"
            rm -rf "$user_home/.config/helm"
        fi
        
        # Remove legacy .helm directory if exists
        if [ -d "$user_home/.helm" ]; then
            echo "Removing legacy Helm directory for user $SUDO_USER"
            rm -rf "$user_home/.helm"
        fi
        
        # Remove Helm cache
        if [ -d "$user_home/.cache/helm" ]; then
            echo "Removing Helm cache for user $SUDO_USER"
            rm -rf "$user_home/.cache/helm"
        fi
    fi
    
    # Remove root's Helm directories
    if [ -d "/root/.config/helm" ]; then
        echo "Removing Helm config for root user"
        rm -rf /root/.config/helm
    fi
    
    if [ -d "/root/.helm" ]; then
        echo "Removing legacy Helm directory for root user"
        rm -rf /root/.helm
    fi
    
    if [ -d "/root/.cache/helm" ]; then
        echo "Removing Helm cache for root user"
        rm -rf /root/.cache/helm
    fi
    
    echo "Helm has been removed"
    return 0
}