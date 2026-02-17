#!/bin/bash

# Detect Linux distribution
detect_distribution() {
    echo "Detecting Linux distribution..."
    
    # Check if /etc/os-release exists (most modern distributions)
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_NAME=$ID
        DISTRO_VERSION=$VERSION_ID
    # Fallback methods
    elif [ -f /etc/debian_version ]; then
        DISTRO_NAME="debian"
        DISTRO_VERSION=$(cat /etc/debian_version)
    elif [ -f /etc/redhat-release ]; then
        if grep -q "CentOS" /etc/redhat-release; then
            DISTRO_NAME="centos"
        elif grep -q "Red Hat" /etc/redhat-release; then
            DISTRO_NAME="rhel"
        elif grep -q "Fedora" /etc/redhat-release; then
            DISTRO_NAME="fedora"
        else
            DISTRO_NAME="rhel"  # Default to RHEL for other Red Hat-based distros
        fi
        DISTRO_VERSION=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1)
    elif [ -f /etc/SuSE-release ] || [ -f /etc/SUSE-brand ]; then
        DISTRO_NAME="suse"
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            DISTRO_VERSION=$VERSION_ID
        else
            DISTRO_VERSION="unknown"
        fi
    elif [ -f /etc/arch-release ]; then
        DISTRO_NAME="arch"
        DISTRO_VERSION="rolling"
    else
        DISTRO_NAME="unknown"
        DISTRO_VERSION="unknown"
    fi
    
    echo "Detected distribution: $DISTRO_NAME $DISTRO_VERSION"
    
    # Set distribution family for easier handling
    case "$DISTRO_NAME" in
        ubuntu|debian)
            DISTRO_FAMILY="debian"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            DISTRO_FAMILY="rhel"
            ;;
        suse|opensuse*)
            DISTRO_FAMILY="suse"
            ;;
        arch|manjaro)
            DISTRO_FAMILY="arch"
            ;;
        *)
            DISTRO_FAMILY="unknown"
            ;;
    esac
    
    # Check if distribution is supported
    case "$DISTRO_FAMILY" in
        debian|rhel|suse|arch)
            echo "Distribution $DISTRO_NAME (family: $DISTRO_FAMILY) is supported."
            ;;
        *)
            echo "Warning: Unsupported distribution $DISTRO_NAME. The script may not work correctly."
            echo "Attempting to continue with generic methods, but you may need to manually install some components."
            DISTRO_FAMILY="generic"
            ;;
    esac
}

# Determine the latest stable Kubernetes version
determine_k8s_version() {
    if [ -z "$K8S_VERSION" ]; then
        echo "Determining latest stable Kubernetes minor version..."
        STABLE_VER=$(curl -fsSL --retry 3 --retry-delay 2 https://dl.k8s.io/release/stable.txt 2>/dev/null || true)
        if echo "$STABLE_VER" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
            K8S_VERSION=$(echo "$STABLE_VER" | sed -E 's/^v([0-9]+\.[0-9]+)\..*/\1/')
            echo "Using detected stable Kubernetes minor: ${K8S_VERSION}"
        else
            K8S_VERSION="${K8S_VERSION_FALLBACK:-1.32}"
            echo "Warning: Could not detect stable version; falling back to ${K8S_VERSION}"
            echo "Hint: Set K8S_VERSION_FALLBACK or use --kubernetes-version to override."
        fi
    fi
}