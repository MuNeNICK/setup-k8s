#!/bin/bash

# Helm package manager installation and setup

# Install Helm
install_helm() {
    echo "Installing Helm package manager..."
    
    # Detect architecture
    local arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="arm" ;;
        *) 
            echo "Unsupported architecture for Helm: $arch"
            return 1
            ;;
    esac
    
    # Get latest version
    echo "Fetching latest Helm version..."
    local helm_version=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | grep tag_name | cut -d '"' -f 4)
    
    if [ -z "$helm_version" ]; then
        echo "Failed to fetch Helm version, using default"
        helm_version="v3.13.0"  # Fallback version
    fi
    
    local download_url="https://get.helm.sh/helm-${helm_version}-linux-${arch}.tar.gz"
    echo "Downloading Helm ${helm_version} for ${arch}..."
    echo "Download URL: $download_url"
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Download and extract
    if curl -fsSL -o helm.tar.gz "$download_url"; then
        tar -zxf helm.tar.gz
        if [ -f "linux-${arch}/helm" ]; then
            mv "linux-${arch}/helm" /usr/local/bin/helm
            chmod +x /usr/local/bin/helm
            echo "Helm installed successfully to /usr/local/bin/helm"
        else
            echo "Error: Helm binary not found in archive"
            cd - > /dev/null
            rm -rf "$temp_dir"
            return 1
        fi
    else
        echo "Error: Failed to download Helm"
        cd - > /dev/null
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Cleanup
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    # Verify installation
    if helm version --short &>/dev/null; then
        echo "Helm version: $(helm version --short)"
        
        # Add stable repo
        echo "Adding Helm stable repository..."
        helm repo add stable https://charts.helm.sh/stable 2>/dev/null || true
        helm repo update 2>/dev/null || true
        
        return 0
    else
        echo "Error: Helm installation verification failed"
        return 1
    fi
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
        chown -R "$user:$(id -gn $user)" "$user_home/.config"
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
    
    # Remove all users' Helm directories
    for user_home in /home/*; do
        if [ -d "$user_home" ]; then
            local username=$(basename "$user_home")
            
            if [ -d "$user_home/.config/helm" ]; then
                echo "Removing Helm config for user $username"
                rm -rf "$user_home/.config/helm"
            fi
            
            if [ -d "$user_home/.helm" ]; then
                echo "Removing legacy Helm directory for user $username"
                rm -rf "$user_home/.helm"
            fi
            
            if [ -d "$user_home/.cache/helm" ]; then
                echo "Removing Helm cache for user $username"
                rm -rf "$user_home/.cache/helm"
            fi
        fi
    done
    
    echo "Helm has been removed"
    return 0
}