#!/bin/bash

set -e

# Default values
DISTRO_NAME=""
DISTRO_VERSION=""

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
    
    # Check if distribution is supported
    case "$DISTRO_NAME" in
        ubuntu|debian|centos|rhel|fedora|rocky|almalinux|suse|opensuse*|arch|manjaro)
            echo "Distribution $DISTRO_NAME is supported."
            ;;
        *)
            echo "Warning: Unsupported distribution $DISTRO_NAME. The script may not work correctly."
            echo "Attempting to continue, but you may need to manually remove some components."
            ;;
    esac
}

# Common cleanup functions for all distributions
common_cleanup() {
    # Check if Docker is installed and warn about containerd
    if command -v docker &> /dev/null; then
        echo "WARNING: Docker is installed on this system."
        echo "This cleanup script will reset containerd configuration but will NOT remove containerd."
        echo "Docker should continue to work normally after cleanup."
    fi
    
    # Stop services first
    echo "Stopping Kubernetes services..."
    systemctl stop kubelet || true
    systemctl disable kubelet || true

    # Reset kubeadm if present to clean cluster state
    if command -v kubeadm &> /dev/null; then
        echo "Resetting kubeadm cluster state..."
        kubeadm reset -f || true
    fi
    
    # Remove configuration files
    echo "Removing common configuration files..."
    rm -f /etc/default/kubelet
    rm -rf /etc/kubernetes
    rm -rf /etc/systemd/system/kubelet.service.d
    
    # Disable and clean up zram swap (especially for Fedora and Arch)
    echo "Checking and disabling zram swap if present..."
    if grep -q zram /proc/swaps || [ "$DISTRO_NAME" = "fedora" ] || [ "$DISTRO_NAME" = "arch" ] || [ "$DISTRO_NAME" = "manjaro" ]; then
        echo "zram swap detected or Fedora/Arch system, disabling..."
        
        # Stop and disable all potential zram swap services
        for service in zram-swap.service systemd-zram-setup@zram0.service dev-zram0.swap; do
            if systemctl is-active $service &>/dev/null; then
                echo "Stopping and disabling $service..."
                systemctl stop $service
                systemctl disable $service
            fi
            # Unmask the service during cleanup to restore normal system state
            echo "Unmasking $service if it was masked..."
            systemctl unmask $service 2>/dev/null || true
        done
        
        # Remove any zram-generator custom configuration
        if [ -d /etc/systemd/zram-generator.conf.d ]; then
            echo "Removing zram swap configuration..."
            rm -rf /etc/systemd/zram-generator.conf.d
        fi
        
        # Unload zram kernel module if loaded
        if lsmod | grep -q zram; then
            echo "Unloading zram kernel module..."
            swapoff -a  # Make sure all swap is off before unloading
            modprobe -r zram || true
        fi
        
        # Make sure all swap is disabled
        echo "Making sure all swap is disabled..."
        swapoff -a
        
        # Find and disable all swap entries
        echo "Checking for any remaining active swap..."
        if [ -n "$(swapon --show 2>/dev/null)" ]; then
            echo "Additional swap devices found, disabling them individually:"
            swapon --show
            for swap_device in $(swapon --show=NAME --noheadings 2>/dev/null); do
                echo "Disabling swap on $swap_device"
                swapoff "$swap_device" || true
            done
        fi
        
        # Verify swap is truly off
        if [ -n "$(swapon --show 2>/dev/null)" ]; then
            echo "WARNING: Some swap devices could not be disabled:"
            swapon --show
        else
            echo "All swap has been successfully disabled."
        fi
    fi
    
    # Clean up CNI configurations if not preserving
    if [ "$PRESERVE_CNI" = false ]; then
        echo "Removing CNI configurations..."
        rm -rf /etc/cni/net.d/* || true
        rm -rf /var/lib/cni/ || true
    else
        echo "Preserving CNI configurations as requested."
    fi

    # Remove kernel modules and sysctl configurations added by setup
    echo "Removing Kubernetes kernel module and sysctl configurations..."
    rm -f /etc/modules-load.d/k8s.conf || true
    rm -f /etc/sysctl.d/k8s.conf || true
    
    # Clean up .kube directory
    if [ -n "$SUDO_USER" ]; then
        USER_HOME="/home/$SUDO_USER"
        echo "Cleanup: Removing .kube directory and config for user $SUDO_USER"
        rm -rf "$USER_HOME/.kube" || true
        rm -f "$USER_HOME/.kube/config" || true
    fi

    # Clean up root's .kube directory
    ROOT_HOME=$(eval echo ~root)
    echo "Cleanup: Removing .kube directory and config for root user at $ROOT_HOME"
    rm -rf "$ROOT_HOME/.kube" || true
    rm -f "$ROOT_HOME/.kube/config" || true
    
    # Clean up all users' .kube/config files
    for user_home in /home/*; do
        if [ -d "$user_home" ]; then
            echo "Cleanup: Removing .kube directory and config for user directory $user_home"
            rm -rf "$user_home/.kube" || true
            rm -f "$user_home/.kube/config" || true
        fi
    done
    
    # Reset iptables rules
    echo "Resetting iptables rules..."
    if command -v iptables &> /dev/null; then
        iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X || true
    else
        echo "Warning: iptables command not found, skipping iptables reset"
    fi
    
    # Reset containerd configuration (but don't remove containerd)
    if [ -f /etc/containerd/config.toml ]; then
        echo "Resetting containerd configuration to default..."
        if command -v containerd &> /dev/null; then
            # Backup current config
            cp /etc/containerd/config.toml /etc/containerd/config.toml.bak.$(date +%Y%m%d%H%M%S)
            # Generate default config
            containerd config default > /etc/containerd/config.toml
            # Restart containerd if it's running
            if systemctl is-active containerd &>/dev/null; then
                echo "Restarting containerd with default configuration..."
                systemctl restart containerd
            fi
        fi
    fi
    
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
    
    echo "Using package manager: $PKG_MGR"
    
    # Check for iptables
    if ! command -v iptables &> /dev/null; then
        echo "Warning: iptables command not found, some cleanup steps may be skipped"
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
    
    # Check for iptables
    if ! command -v iptables &> /dev/null; then
        echo "Warning: iptables command not found, some cleanup steps may be skipped"
    fi
    
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
    
    # Check for iptables
    if ! command -v iptables &> /dev/null; then
        echo "Warning: iptables command not found, some cleanup steps may be skipped"
    fi
    
    # Remove AUR packages (with -bin suffix)
    echo "Removing Kubernetes packages from AUR..."
    for pkg in kubeadm-bin kubectl-bin kubelet-bin kubeadm kubectl kubelet; do
        if pacman -Qi $pkg &>/dev/null; then
            echo "Removing $pkg..."
            pacman -Rns --noconfirm $pkg || true
        fi
    done
    
    # Remove binaries from /usr/local/bin if they exist
    echo "Removing Kubernetes binaries from /usr/local/bin..."
    for binary in kubeadm kubectl kubelet; do
        if [ -f "/usr/local/bin/$binary" ]; then
            echo "Removing /usr/local/bin/$binary..."
            rm -f "/usr/local/bin/$binary"
        fi
    done
    
    # Remove systemd service files if they were manually created
    if [ -f "/etc/systemd/system/kubelet.service" ]; then
        echo "Removing manually created kubelet service file..."
        rm -f "/etc/systemd/system/kubelet.service"
        rm -rf "/etc/systemd/system/kubelet.service.d"
        systemctl daemon-reload
    fi
    
    # Clean up dependencies
    echo "Removing unnecessary dependencies..."
    pacman -Sc --noconfirm
    
    # Disable zram swap specifically for Arch
    echo "Disabling zram swap on Arch Linux..."
    for service in systemd-zram-setup@zram0.service dev-zram0.swap; do
        if systemctl is-active "$service" &>/dev/null; then
            echo "Stopping $service..."
            systemctl stop "$service"
        fi
        if systemctl is-enabled "$service" &>/dev/null; then
            echo "Disabling $service..."
            systemctl disable "$service"
        fi
        echo "Unmasking $service if it was masked..."
        systemctl unmask "$service" 2>/dev/null || true
    done
    
    # Turn off all swap devices
    swapoff -a
    
    # Remove zram module if loaded
    if lsmod | grep -q zram; then
        echo "Removing zram kernel module..."
        modprobe -r zram || true
    fi
    
    # Verify cleanup
    echo -e "\nVerifying cleanup..."
    remaining_files=0
    
    # Check for remaining packages
    if pacman -Qs kubeadm kubectl kubelet | grep -E "kube|kubernetes" > /dev/null; then
        echo "Warning: Some Kubernetes packages still remain:"
        pacman -Qs kubeadm kubectl kubelet | grep -E "kube|kubernetes"
        remaining_files=1
    fi
    
    # Check for remaining binaries
    for binary in kubeadm kubectl kubelet; do
        if [ -f "/usr/local/bin/$binary" ] || command -v $binary &>/dev/null; then
            echo "Warning: $binary still exists in PATH"
            remaining_files=1
        fi
    done
    
    # Check for remaining files
    for file in "/etc/default/kubelet" "/etc/systemd/system/kubelet.service"; do
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
    
    # Check for iptables
    if ! command -v iptables &> /dev/null; then
        echo "Warning: iptables command not found, some cleanup steps may be skipped"
    fi
    
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
case "$DISTRO_NAME" in
    debian|ubuntu)
        cleanup_debian
        ;;
    centos|rhel|fedora|rocky|almalinux)
        echo "Cleaning up RHEL/Fedora based distribution..."
        cleanup_rhel
        ;;
    suse|opensuse*)
        cleanup_suse
        ;;
    arch|manjaro)
        cleanup_arch
        ;;
    *)
        echo "Warning: Unsupported distribution. Using generic cleanup methods."
        cleanup_generic
        ;;
esac

echo "Cleanup complete! Please reboot the system for all changes to take effect."
