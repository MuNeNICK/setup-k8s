#!/bin/bash

set -e

# Default values
DISTRO_NAME=""
DISTRO_VERSION=""
DISTRO_FAMILY=""

# Help message
show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --force         Skip confirmation prompt"
    echo "  --preserve-cni  Preserve CNI configurations"
    echo "  --node-type    Specify node type (master/worker) to override auto-detection"
    echo "  --help         Display this help message"
    exit 0
}

# Detect Linux distribution
detect_distribution() {
    echo "Detecting Linux distribution..."
    
    # Check if /etc/os-release exists (most modern distributions)
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_NAME=$ID
        DISTRO_VERSION=$VERSION_ID
        DISTRO_FAMILY=$ID_LIKE
    # Fallback methods
    elif [ -f /etc/debian_version ]; then
        DISTRO_NAME="debian"
        DISTRO_FAMILY="debian"
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
        DISTRO_FAMILY="rhel"
        DISTRO_VERSION=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1)
    elif [ -f /etc/SuSE-release ] || [ -f /etc/SUSE-brand ]; then
        DISTRO_NAME="suse"
        DISTRO_FAMILY="suse"
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            DISTRO_VERSION=$VERSION_ID
        else
            DISTRO_VERSION="unknown"
        fi
    elif [ -f /etc/arch-release ]; then
        DISTRO_NAME="arch"
        DISTRO_FAMILY="arch"
        DISTRO_VERSION="rolling"
    else
        DISTRO_NAME="unknown"
        DISTRO_FAMILY="unknown"
        DISTRO_VERSION="unknown"
    fi
    
    echo "Detected distribution: $DISTRO_NAME $DISTRO_VERSION (family: $DISTRO_FAMILY)"
    
    # Check if distribution is supported
    case "$DISTRO_NAME" in
        ubuntu|debian|centos|rhel|fedora|rocky|almalinux|suse|opensuse*|arch|manjaro)
            echo "Distribution $DISTRO_NAME is supported."
            ;;
        *)
            if [[ "$DISTRO_FAMILY" == *"debian"* ]]; then
                echo "Distribution family 'debian' is supported. Treating as Debian-based."
                DISTRO_FAMILY="debian"
            elif [[ "$DISTRO_FAMILY" == *"rhel"* || "$DISTRO_FAMILY" == *"fedora"* ]]; then
                echo "Distribution family 'rhel/fedora' is supported. Treating as RHEL-based."
                DISTRO_FAMILY="rhel"
            elif [[ "$DISTRO_FAMILY" == *"suse"* ]]; then
                echo "Distribution family 'suse' is supported. Treating as SUSE-based."
                DISTRO_FAMILY="suse"
            elif [[ "$DISTRO_FAMILY" == *"arch"* ]]; then
                echo "Distribution family 'arch' is supported. Treating as Arch-based."
                DISTRO_FAMILY="arch"
            else
                echo "Warning: Unsupported distribution $DISTRO_NAME. The script may not work correctly."
                echo "Attempting to continue, but you may need to manually remove some components."
            fi
            ;;
    esac
}

# Common cleanup functions for all distributions
common_cleanup() {
    # Stop services first
    echo "Stopping Kubernetes services..."
    systemctl stop kubelet || true
    systemctl disable kubelet || true
    
    # Remove configuration files
    echo "Removing common configuration files..."
    rm -f /etc/default/kubelet
    rm -rf /etc/kubernetes
    rm -rf /etc/systemd/system/kubelet.service.d
    
    # Clean up CNI configurations if not preserving
    if [ "$PRESERVE_CNI" = false ]; then
        echo "Removing CNI configurations..."
        rm -rf /etc/cni/net.d/* || true
        rm -rf /var/lib/cni/ || true
    else
        echo "Preserving CNI configurations as requested."
    fi
    
    # Clean up .kube directory
    if [ -n "$SUDO_USER" ]; then
        USER_HOME="/home/$SUDO_USER"
        echo "Cleanup: Removing .kube directory for user $SUDO_USER"
        rm -rf "$USER_HOME/.kube" || true
    else
        echo "Cleanup: Removing .kube directory for root user"
        rm -rf $HOME/.kube/ || true
    fi
    
    # Reset iptables rules
    echo "Resetting iptables rules..."
    iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X || true
    
    # Reload systemd
    systemctl daemon-reload
}

# Debian/Ubuntu specific cleanup
cleanup_debian() {
    echo "Performing Debian/Ubuntu specific cleanup..."
    
    # Remove package holds
    echo "Removing package holds..."
    for pkg in kubeadm kubectl kubelet kubernetes-cni; do
        apt-mark unhold $pkg 2>/dev/null || true
    done
    
    # First round: Remove packages normally
    echo "Removing packages (first round)..."
    apt-get remove -y kubeadm kubectl kubelet kubernetes-cni || true
    
    # Second round: Purge packages
    echo "Purging packages (second round)..."
    apt-get purge -y kubeadm kubectl kubelet kubernetes-cni || true
    
    # Third round: Force purge with dpkg
    echo "Force purging packages (third round)..."
    for pkg in kubeadm kubectl kubelet kubernetes-cni; do
        dpkg --force-all --purge $pkg 2>/dev/null || true
    done
    
    # Fourth round: Clean up any remaining configuration packages
    echo "Cleaning up remaining configurations..."
    dpkg -l | awk '/^rc.*kube|kubernetes/ {print $2}' | xargs -r dpkg --force-all --purge
    
    # Clean up dependencies
    echo "Removing unnecessary dependencies..."
    apt-get autoremove -y || true
    
    # Remove repository files
    echo "Removing Kubernetes repository files..."
    rm -f /etc/apt/sources.list.d/kubernetes.list
    rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.gpg
    
    # Remove dpkg info files
    rm -f /var/lib/dpkg/info/kubelet.* || true
    
    # Update package lists
    echo "Updating package lists..."
    apt-get update || true
    
    # Final cleanup
    echo "Performing final cleanup..."
    apt-get clean
    apt-get autoremove -y || true
    
    # Verify cleanup
    echo -e "\nVerifying cleanup..."
    remaining_files=0
    
    # Check for remaining packages
    if dpkg -l | grep -E "kube|kubernetes" > /dev/null; then
        echo "Warning: Some Kubernetes packages still remain:"
        dpkg -l | grep -E "kube|kubernetes"
        remaining_files=1
    fi
    
    # Check for remaining files
    for file in "/etc/apt/sources.list.d/kubernetes.list" \
               "/etc/apt/keyrings/kubernetes-apt-keyring.gpg" \
               "/etc/default/kubelet"; do
        if [ -f "$file" ]; then
            echo "Warning: File still exists: $file"
            remaining_files=1
        fi
    done
    
    if [ $remaining_files -eq 1 ]; then
        echo -e "\nSome files or packages could not be removed. You may want to remove them manually."
    else
        echo -e "\nAll specified components have been successfully removed."
    fi
}

# RHEL/CentOS/Fedora specific cleanup
cleanup_rhel() {
    echo "Performing RHEL/CentOS/Fedora specific cleanup..."
    
    # Determine package manager (dnf or yum)
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
        VERSIONLOCK="versionlock"
    else
        PKG_MGR="yum"
        VERSIONLOCK="versionlock"
    fi
    
    # Remove version locks
    echo "Removing version locks..."
    $PKG_MGR $VERSIONLOCK delete kubeadm kubectl kubelet || true
    
    # Remove packages
    echo "Removing Kubernetes packages..."
    $PKG_MGR remove -y kubeadm kubectl kubelet kubernetes-cni || true
    
    # Clean up dependencies
    echo "Removing unnecessary dependencies..."
    $PKG_MGR autoremove -y || true
    
    # Remove repository files
    echo "Removing Kubernetes repository files..."
    rm -f /etc/yum.repos.d/kubernetes.repo
    
    # Clean up Docker repository if it exists
    if [ -f /etc/yum.repos.d/docker-ce.repo ]; then
        echo "Removing Docker repository..."
        rm -f /etc/yum.repos.d/docker-ce.repo
    fi
    
    # Final cleanup
    echo "Performing final cleanup..."
    $PKG_MGR clean all
    
    # Verify cleanup
    echo -e "\nVerifying cleanup..."
    remaining_files=0
    
    # Check for remaining packages
    if $PKG_MGR list installed | grep -E "kube|kubernetes" > /dev/null; then
        echo "Warning: Some Kubernetes packages still remain:"
        $PKG_MGR list installed | grep -E "kube|kubernetes"
        remaining_files=1
    fi
    
    # Check for remaining files
    for file in "/etc/yum.repos.d/kubernetes.repo" \
               "/etc/default/kubelet"; do
        if [ -f "$file" ]; then
            echo "Warning: File still exists: $file"
            remaining_files=1
        fi
    done
    
    if [ $remaining_files -eq 1 ]; then
        echo -e "\nSome files or packages could not be removed. You may want to remove them manually."
    else
        echo -e "\nAll specified components have been successfully removed."
    fi
}

# SUSE specific cleanup
cleanup_suse() {
    echo "Performing SUSE specific cleanup..."
    
    # Remove packages
    echo "Removing Kubernetes packages..."
    zypper remove -y kubeadm kubectl kubelet kubernetes-cni || true
    
    # Clean up dependencies
    echo "Removing unnecessary dependencies..."
    zypper clean
    
    # Remove repository
    echo "Removing Kubernetes repository..."
    zypper removerepo kubernetes || true
    
    # Remove Docker repository if it exists
    zypper removerepo docker-ce || true
    
    # Verify cleanup
    echo -e "\nVerifying cleanup..."
    remaining_files=0
    
    # Check for remaining packages
    if zypper search -i | grep -E "kube|kubernetes" > /dev/null; then
        echo "Warning: Some Kubernetes packages still remain:"
        zypper search -i | grep -E "kube|kubernetes"
        remaining_files=1
    fi
    
    # Check for remaining files
    for file in "/etc/default/kubelet"; do
        if [ -f "$file" ]; then
            echo "Warning: File still exists: $file"
            remaining_files=1
        fi
    done
    
    if [ $remaining_files -eq 1 ]; then
        echo -e "\nSome files or packages could not be removed. You may want to remove them manually."
    else
        echo -e "\nAll specified components have been successfully removed."
    fi
}

# Arch Linux specific cleanup
cleanup_arch() {
    echo "Performing Arch Linux specific cleanup..."
    
    # Remove packages
    echo "Removing Kubernetes packages..."
    pacman -Rns --noconfirm kubeadm kubectl kubelet || true
    
    # Clean up dependencies
    echo "Removing unnecessary dependencies..."
    pacman -Sc --noconfirm
    
    # Verify cleanup
    echo -e "\nVerifying cleanup..."
    remaining_files=0
    
    # Check for remaining packages
    if pacman -Qs kubeadm kubectl kubelet | grep -E "kube|kubernetes" > /dev/null; then
        echo "Warning: Some Kubernetes packages still remain:"
        pacman -Qs kubeadm kubectl kubelet | grep -E "kube|kubernetes"
        remaining_files=1
    fi
    
    # Check for remaining files
    for file in "/etc/default/kubelet"; do
        if [ -f "$file" ]; then
            echo "Warning: File still exists: $file"
            remaining_files=1
        fi
    done
    
    if [ $remaining_files -eq 1 ]; then
        echo -e "\nSome files or packages could not be removed. You may want to remove them manually."
    else
        echo -e "\nAll specified components have been successfully removed."
    fi
}

# Generic cleanup for unsupported distributions
cleanup_generic() {
    echo "Warning: Using generic cleanup method for unsupported distribution."
    echo "This may not completely remove all Kubernetes components."
    
    # Try to remove packages using common package managers
    if command -v apt-get &> /dev/null; then
        echo "Attempting to remove packages with apt-get..."
        apt-get remove -y kubeadm kubectl kubelet kubernetes-cni || true
        apt-get purge -y kubeadm kubectl kubelet kubernetes-cni || true
        apt-get autoremove -y || true
    elif command -v dnf &> /dev/null; then
        echo "Attempting to remove packages with dnf..."
        dnf remove -y kubeadm kubectl kubelet kubernetes-cni || true
        dnf autoremove -y || true
    elif command -v yum &> /dev/null; then
        echo "Attempting to remove packages with yum..."
        yum remove -y kubeadm kubectl kubelet kubernetes-cni || true
        yum autoremove -y || true
    elif command -v zypper &> /dev/null; then
        echo "Attempting to remove packages with zypper..."
        zypper remove -y kubeadm kubectl kubelet kubernetes-cni || true
    elif command -v pacman &> /dev/null; then
        echo "Attempting to remove packages with pacman..."
        pacman -Rns --noconfirm kubeadm kubectl kubelet || true
    else
        echo "No supported package manager found. Please remove Kubernetes packages manually."
    fi
    
    echo "Note: You may need to manually remove some components."
}

# Parse command line arguments
FORCE=false
PRESERVE_CNI=false
NODE_TYPE=""
while [[ $# -gt 0 ]]; do 
    case $1 in
        --help)
            show_help
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --preserve-cni)
            PRESERVE_CNI=true
            shift
            ;;
        --node-type)
            NODE_TYPE=$2
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

# Check root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with root privileges"
   exit 1
fi

# Confirmation prompt unless --force is used
if [ "$FORCE" = false ]; then
    echo "WARNING: This script will remove Kubernetes configurations."
    echo "Are you sure you want to continue? (y/N)"
    if [ -t 0 ]; then
        read -r response
    else
        read -r response < /dev/tty
    fi
    if [[ ! "$response" =~ ^[yY]$ ]]; then
        echo "Operation cancelled."
        exit 0
    fi
fi

echo "Starting Kubernetes cleanup..."

# Detect distribution
detect_distribution

# Perform common cleanup tasks
common_cleanup

# Perform distribution-specific cleanup
case "$DISTRO_FAMILY" in
    debian)
        cleanup_debian
        ;;
    rhel|fedora)
        cleanup_rhel
        ;;
    suse)
        cleanup_suse
        ;;
    arch)
        cleanup_arch
        ;;
    *)
        cleanup_generic
        ;;
esac

echo "Cleanup complete! Please reboot the system for all changes to take effect."
