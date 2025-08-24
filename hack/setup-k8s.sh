#!/bin/bash

set -e

# Default values
K8S_VERSION="1.32"
NODE_TYPE="master"  # Default is master node
JOIN_TOKEN=""
JOIN_ADDRESS=""
DISCOVERY_TOKEN_HASH=""
DISTRO_NAME=""
DISTRO_VERSION=""
DISTRO_FAMILY=""

# Helper: Get Debian/Ubuntu codename without lsb_release
get_debian_codename() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ -n "$VERSION_CODENAME" ]; then
            echo "$VERSION_CODENAME"
            return 0
        fi
        if [ -n "$UBUNTU_CODENAME" ]; then
            echo "$UBUNTU_CODENAME"
            return 0
        fi
        # Fallback mapping for some well-known VERSION_ID values
        case "$ID:$VERSION_ID" in
            ubuntu:24.04) echo "noble" ; return 0 ;;
            ubuntu:22.04) echo "jammy" ; return 0 ;;
            ubuntu:20.04) echo "focal" ; return 0 ;;
            debian:12) echo "bookworm" ; return 0 ;;
            debian:11) echo "bullseye" ; return 0 ;;
        esac
    fi
    # Last resort
    echo "stable"
}

# Help message
show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --node-type    Node type (master or worker)"
    echo "  --pod-network-cidr   Pod network CIDR (e.g., 192.168.0.0/16)"
    echo "  --apiserver-advertise-address   API server advertise address"
    echo "  --control-plane-endpoint   Control plane endpoint"
    echo "  --service-cidr    Service CIDR (e.g., 10.96.0.0/12)"
    echo "  --kubernetes-version   Kubernetes version (e.g., 1.29, 1.28)"
    echo "  --join-token    Join token for worker nodes"
    echo "  --join-address  Master node address for worker nodes"
    echo "  --discovery-token-hash  Discovery token hash for worker nodes"
    echo "  --help            Display this help message"
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
            echo "Attempting to continue, but you may need to manually install some components."
            ;;
    esac
}

# Debian/Ubuntu specific functions
install_dependencies_debian() {
    echo "Installing dependencies for Debian-based distribution..."
    apt-get update
    apt-get install -y \
        apt-transport-https ca-certificates curl gnupg \
        software-properties-common \
        conntrack socat ethtool iproute2 iptables \
        ebtables || apt-get install -y arptables || true
}

setup_containerd_debian() {
    echo "Setting up containerd for Debian-based distribution..."
    
    # Create keyrings directory if it doesn't exist
    mkdir -p /etc/apt/keyrings
    
    # Add Docker repository (for containerd) without using lsb_release
    CODENAME=$(get_debian_codename)
    if [ "$DISTRO_NAME" = "ubuntu" ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list
    else
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list
    fi
    
    # Install containerd
    apt-get update
    apt-get install -y containerd.io
    
    # Configure containerd
    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    systemctl restart containerd
    systemctl enable containerd
}

setup_kubernetes_debian() {
    echo "Setting up Kubernetes for Debian-based distribution..."
    
    # Create keyrings directory if it doesn't exist
    mkdir -p /etc/apt/keyrings
    
    # Add Kubernetes repository
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
    
    apt-get update
    
    # Find available version
    VERSION_STRING=$(apt-cache madison kubeadm | grep ${K8S_VERSION} | head -1 | awk '{print $3}')
    if [ -z "$VERSION_STRING" ]; then
        echo "Specified version ${K8S_VERSION} not found"
        exit 1
    fi
    
    # Install Kubernetes components
    apt-get install -y --allow-change-held-packages kubelet=${VERSION_STRING} kubeadm=${VERSION_STRING} kubectl=${VERSION_STRING}
    apt-mark hold kubelet kubeadm kubectl
}

cleanup_debian() {
    echo "Cleaning up existing cluster configuration..."
    kubeadm reset -f || true
    rm -rf /etc/cni/net.d/* || true
    rm -rf /var/lib/cni/ || true
    
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
    if command -v iptables &> /dev/null; then
        iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
    else
        echo "Warning: iptables command not found, skipping iptables reset"
    fi
}

# RHEL/CentOS/Fedora specific functions
install_dependencies_rhel() {
    echo "Installing dependencies for RHEL-based distribution..."
    
    # Determine package manager (dnf or yum)
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi
    
    echo "Using package manager: $PKG_MGR"
    
    # Install essential packages including iptables and networking tools
    echo "Installing essential packages..."
    if [ "$PKG_MGR" = "dnf" ]; then
        $PKG_MGR install -y dnf-plugins-core || true
    fi
    $PKG_MGR install -y curl gnupg2 iptables iptables-services ethtool iproute conntrack-tools socat ebtables || true
    
    # Check if iptables was installed successfully
    if ! command -v iptables &> /dev/null; then
        echo "Warning: iptables installation failed. Trying alternative package..."
        $PKG_MGR install -y iptables-legacy || $PKG_MGR install -y iptables-services || true
    fi
    
    # For CentOS 9 Stream, we need to enable additional repositories
    if [ "$DISTRO_NAME" = "centos" ] && [[ "$DISTRO_VERSION" == "9"* ]]; then
        echo "Detected CentOS 9 Stream, enabling additional repositories..."
        $PKG_MGR install -y epel-release || true
        $PKG_MGR config-manager --set-enabled crb || $PKG_MGR config-manager --set-enabled powertools || true
    fi
}

setup_containerd_rhel() {
    echo "Setting up containerd for RHEL-based distribution..."
    
    # Determine package manager (dnf or yum)
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi
    
    echo "Using package manager: $PKG_MGR"
    
    # Install required packages for repository management
    echo "Installing repository management tools..."
    if [ "$PKG_MGR" = "dnf" ]; then
        $PKG_MGR install -y dnf-plugins-core device-mapper-persistent-data lvm2 || true
    else
        $PKG_MGR install -y yum-utils device-mapper-persistent-data lvm2 || true
    fi
    
    # Add Docker repository (for containerd)
    echo "Adding Docker repository..."
    if [ "$DISTRO_NAME" = "fedora" ]; then
        # Check Fedora version for correct config-manager syntax
        if [[ "$DISTRO_VERSION" -ge 41 ]]; then
            # Fedora 41+ uses new syntax - download repo file directly
            echo "Using direct repo file download for Fedora 41+"
            curl -fsSL https://download.docker.com/linux/fedora/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
        else
            $PKG_MGR config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        fi
    else
        # For CentOS/RHEL
        $PKG_MGR config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    
    # Install containerd
    echo "Installing containerd.io package..."
    # Prefer containerd.io, allow nobest fallback for dependency resolution
    if [ "$PKG_MGR" = "dnf" ]; then
        $PKG_MGR install -y --setopt=install_weak_deps=False containerd.io || $PKG_MGR install -y --nobest containerd.io || true
    else
        $PKG_MGR install -y containerd.io || true
    fi
    
    # Check if containerd was installed successfully
    if ! command -v containerd &> /dev/null; then
        echo "Error: containerd installation failed. Trying alternative approach..."
        # Try installing docker-ce as it includes containerd
        $PKG_MGR install -y docker-ce docker-ce-cli containerd.io || true
        
        # If still not installed, try installing from CentOS 8 repository for CentOS 9
        if ! command -v containerd &> /dev/null && [ "$DISTRO_NAME" = "centos" ] && [[ "$DISTRO_VERSION" == "9"* ]]; then
            echo "Trying to install containerd from CentOS 8 repository..."
            $PKG_MGR install -y --releasever=8 containerd.io || true
        fi
    fi
    
    # Configure containerd
    if command -v containerd &> /dev/null; then
        echo "Configuring containerd..."
        mkdir -p /etc/containerd
        containerd config default | tee /etc/containerd/config.toml
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        systemctl restart containerd
        systemctl enable containerd
        echo "Containerd configured and restarted."
    else
        echo "Error: containerd is not installed. Kubernetes setup may fail."
    fi
}

setup_kubernetes_rhel() {
    echo "Setting up Kubernetes for RHEL-based distribution..."
    
    # Determine package manager (dnf or yum)
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi
    
    echo "Using package manager: $PKG_MGR"
    
    # Add Kubernetes repository
    echo "Adding Kubernetes repository for version ${K8S_VERSION}..."
    cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF
    
    # Install Kubernetes components
    echo "Installing Kubernetes components..."
    $PKG_MGR install -y kubelet kubeadm kubectl
    
    # Check if installation was successful
    if ! command -v kubeadm &> /dev/null; then
        echo "Error: kubeadm installation failed. Trying alternative approach..."
        # Try installing with different options
        if [ "$PKG_MGR" = "dnf" ]; then
            $PKG_MGR install -y --nogpgcheck --nobest kubelet kubeadm kubectl || true
        else
            $PKG_MGR install -y --nogpgcheck kubelet kubeadm kubectl || true
        fi
        
        # If still not installed, try installing from CentOS 8 repository for CentOS 9
        if ! command -v kubeadm &> /dev/null && [ "$DISTRO_NAME" = "centos" ] && [[ "$DISTRO_VERSION" == "9"* ]]; then
            echo "Trying to install Kubernetes components from CentOS 8 repository..."
            $PKG_MGR install -y --releasever=8 kubelet kubeadm kubectl || true
        fi
    fi
    
    # Hold packages (prevent automatic updates)
    echo "Preventing automatic updates of Kubernetes packages..."
    if command -v dnf &> /dev/null; then
        dnf install -y 'dnf-command(versionlock)' python3-dnf-plugin-versionlock || true
        dnf versionlock add kubelet kubeadm kubectl || echo "Warning: versionlock not available, skipping"
    else
        yum install -y yum-plugin-versionlock || true
        yum versionlock add kubelet kubeadm kubectl || echo "Warning: versionlock not available, skipping"
    fi
    
    # Enable and start kubelet
    echo "Enabling and starting kubelet service..."
    systemctl enable kubelet
    systemctl start kubelet
}

cleanup_rhel() {
    echo "Cleaning up existing cluster configuration..."
    kubeadm reset -f || true
    rm -rf /etc/cni/net.d/* || true
    rm -rf /var/lib/cni/ || true
    
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
    if command -v iptables &> /dev/null; then
        iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
    else
        echo "Warning: iptables command not found, skipping iptables reset"
    fi
}

# SUSE specific functions
install_dependencies_suse() {
    echo "Installing dependencies for SUSE-based distribution..."
    zypper refresh
    zypper install -y curl iptables iproute2 ethtool conntrack-tools socat || true
}

setup_containerd_suse() {
    echo "Setting up containerd for SUSE-based distribution..."
    
    # Prefer official repositories and avoid Docker CE to reduce conflicts
    echo "Installing containerd from SUSE official repositories..."
    zypper refresh
    zypper install -y containerd || true
    
    # Configure containerd if it was installed
    if command -v containerd &> /dev/null; then
        echo "Configuring containerd..."
        mkdir -p /etc/containerd
        containerd config default | tee /etc/containerd/config.toml
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        systemctl restart containerd
        systemctl enable containerd
    else
        echo "Error: containerd installation failed"
        return 1
    fi
}

setup_kubernetes_suse() {
    echo "Setting up Kubernetes for SUSE-based distribution..."
    
    # Add Kubernetes repository (without GPG check to avoid interactive prompts)
    zypper addrepo --no-gpgcheck https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/ kubernetes
    
    # Install Kubernetes components (non-interactive mode with auto-import GPG keys)
    zypper --non-interactive --gpg-auto-import-keys refresh
    zypper --non-interactive install -y kubelet kubeadm kubectl
    
    # Enable and start kubelet
    systemctl enable --now kubelet
}

cleanup_suse() {
    echo "Cleaning up existing cluster configuration..."
    kubeadm reset -f || true
    rm -rf /etc/cni/net.d/* || true
    rm -rf /var/lib/cni/ || true
    
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
    if command -v iptables &> /dev/null; then
        iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
    else
        echo "Warning: iptables command not found, skipping iptables reset"
    fi
}

# Arch Linux specific functions
install_dependencies_arch() {
    echo "Installing dependencies for Arch-based distribution..."
    pacman -Sy --noconfirm curl conntrack-tools socat ethtool iproute2 iptables || true
}

setup_containerd_arch() {
    echo "Setting up containerd for Arch-based distribution..."
    
    # Install containerd
    pacman -Sy --noconfirm containerd
    
    # Configure containerd
    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml
    
    # For containerd v2, SystemdCgroup is in a different location
    # Check containerd version and apply correct configuration
    CONTAINERD_VERSION=$(containerd --version | grep -oP 'v\d+' | sed 's/v//')
    
    if [ "$CONTAINERD_VERSION" -ge 2 ]; then
        echo "Detected containerd v2, applying v2 configuration..."
        # For containerd v2, add SystemdCgroup to runc options
        sed -i '/\[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options\]/a\            SystemdCgroup = true' /etc/containerd/config.toml
    else
        # For containerd v1.x
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    fi
    
    systemctl restart containerd
    systemctl enable containerd
}

setup_kubernetes_arch() {
    echo "Setting up Kubernetes for Arch-based distribution..."
    
    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        # If running as root, we need to handle AUR installation differently
        echo "Running as root. Setting up AUR helper for Kubernetes installation..."
        
        # Check if an AUR helper is already installed
        AUR_HELPER=""
        if command -v yay &> /dev/null; then
            AUR_HELPER="yay"
        elif command -v paru &> /dev/null; then
            AUR_HELPER="paru"
        else
            echo "No AUR helper found. Installing yay..."
            
            # Create a temporary user for building AUR packages
            TEMP_USER="aur_builder_$$"
            useradd -m -s /bin/bash "$TEMP_USER"
            
            # Install base-devel and git if not present
            pacman -Sy --needed --noconfirm base-devel git
            
            # Clone and build yay as the temporary user
            su - "$TEMP_USER" -c "
                cd /tmp
                git clone https://aur.archlinux.org/yay-bin.git
                cd yay-bin
                makepkg --noconfirm
            "
            
            # Install the built package as root
            pacman -U --noconfirm /tmp/yay-bin/yay-bin-*.pkg.tar.* || {
                echo "Failed to install yay package"
                userdel -r "$TEMP_USER"
                exit 1
            }
            
            # Clean up temporary user
            userdel -r "$TEMP_USER"
            
            if command -v yay &> /dev/null; then
                AUR_HELPER="yay"
                echo "yay installed successfully."
            else
                echo "Failed to install yay. Please install Kubernetes components manually."
                exit 1
            fi
        fi
        
        echo "Using AUR helper: $AUR_HELPER"
        
        # Create another temporary user for installing Kubernetes packages
        KUBE_USER="kube_installer_$$"
        useradd -m -s /bin/bash "$KUBE_USER"
        
        # Give the temporary user sudo privileges without password for pacman
        echo "$KUBE_USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" >> /etc/sudoers
        
        # Install Kubernetes components as the temporary user
        echo "Installing Kubernetes components from AUR..."
        su - "$KUBE_USER" -c "
            $AUR_HELPER -S --noconfirm --needed kubeadm-bin kubelet-bin kubectl-bin
        "
        
        # Remove sudo privileges and clean up
        sed -i "/$KUBE_USER/d" /etc/sudoers
        userdel -r "$KUBE_USER"
        
    else
        # If not running as root (should not happen since we check at the beginning of the script)
        echo "This script must be run as root. Exiting."
        exit 1
    fi
    
    # Verify installation
    if command -v kubeadm &> /dev/null && command -v kubelet &> /dev/null && command -v kubectl &> /dev/null; then
        echo "Kubernetes components installed successfully."
    else
        # Try alternative approach: directly downloading binaries
        echo "AUR installation failed. Trying direct binary download..."
        
        # Get the latest stable version
        KUBE_VERSION=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
        echo "Downloading Kubernetes version: $KUBE_VERSION"

        # Detect architecture mapping for Kubernetes binaries
        UNAME_ARCH=$(uname -m)
        case "$UNAME_ARCH" in
            x86_64) KARCH="amd64" ;;
            aarch64) KARCH="arm64" ;;
            armv7l) KARCH="arm" ;;
            ppc64le) KARCH="ppc64le" ;;
            s390x) KARCH="s390x" ;;
            *) KARCH="amd64" ; echo "Unknown arch $UNAME_ARCH, defaulting to amd64" ;;
        esac

        # Download and install binaries
        for binary in kubeadm kubelet kubectl; do
            echo "Downloading $binary for arch $KARCH..."
            curl -Lo /usr/local/bin/$binary "https://storage.googleapis.com/kubernetes-release/release/${KUBE_VERSION}/bin/linux/${KARCH}/$binary"
            chmod +x /usr/local/bin/$binary
        done
        
        # Create kubelet service file if it doesn't exist
        if [ ! -f /etc/systemd/system/kubelet.service ]; then
            cat > /etc/systemd/system/kubelet.service <<'KUBELET_SERVICE'
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
KUBELET_SERVICE
        fi
        
        # Create kubelet service drop-in directory
        mkdir -p /etc/systemd/system/kubelet.service.d
        
        # Create kubeadm config for kubelet
        cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<'KUBEADM_CONF'
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
KUBEADM_CONF
        
        # Reload systemd
        systemctl daemon-reload
    fi
    
    # Enable and start kubelet
    systemctl enable kubelet
    systemctl start kubelet
    
    echo "Kubernetes setup completed for Arch Linux."
}

cleanup_arch() {
    echo "Cleaning up existing cluster configuration..."
    kubeadm reset -f || true
    rm -rf /etc/cni/net.d/* || true
    rm -rf /var/lib/cni/ || true
    
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
    if command -v iptables &> /dev/null; then
        iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
    else
        echo "Warning: iptables command not found, skipping iptables reset"
    fi
    
    # Arch Linux specific: Disable zram swap completely
    echo "Disabling zram swap on Arch Linux..."
    
    # Stop and disable all zram-related services
    for service in systemd-zram-setup@zram0.service dev-zram0.swap; do
        if systemctl is-active "$service" &>/dev/null; then
            echo "Stopping $service..."
            systemctl stop "$service"
        fi
        if systemctl is-enabled "$service" &>/dev/null; then
            echo "Disabling $service..."
            systemctl disable "$service"
        fi
        echo "Masking $service to prevent activation..."
        systemctl mask "$service" 2>/dev/null || true
    done
    
    # Turn off all swap devices
    echo "Turning off all swap devices..."
    swapoff -a
    
    # Remove zram module if loaded
    if lsmod | grep -q zram; then
        echo "Removing zram kernel module..."
        modprobe -r zram || true
    fi
    
    # Verify swap is disabled
    if [ -n "$(swapon --show 2>/dev/null)" ]; then
        echo "Warning: Some swap devices are still active:"
        swapon --show
    else
        echo "All swap has been successfully disabled."
    fi
}

# Generic functions for unsupported distributions
install_dependencies_generic() {
    echo "Warning: Using generic method to install dependencies."
    echo "This may not work correctly on your distribution."
    echo "Please install the following packages manually if needed:"
    echo "- curl"
    echo "- containerd"
    echo "- kubeadm, kubelet, kubectl"
    echo "- iptables, conntrack, socat, ethtool, iproute2"
    
    # Try to install iptables if not present
    if ! command -v iptables &> /dev/null; then
        echo "Attempting to install iptables..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y iptables
        elif command -v dnf &> /dev/null; then
            dnf install -y iptables
        elif command -v yum &> /dev/null; then
            yum install -y iptables
        elif command -v zypper &> /dev/null; then
            zypper install -y iptables
        elif command -v pacman &> /dev/null; then
            pacman -Sy --noconfirm iptables
        fi
    fi

    # Try to install other useful dependencies if package manager is available
    if command -v apt-get &> /dev/null; then
        apt-get install -y conntrack socat ethtool iproute2 || true
    elif command -v dnf &> /dev/null; then
        dnf install -y conntrack-tools socat ethtool iproute || true
    elif command -v yum &> /dev/null; then
        yum install -y conntrack-tools socat ethtool iproute || true
    elif command -v zypper &> /dev/null; then
        zypper install -y conntrack-tools socat ethtool iproute2 || true
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm conntrack-tools socat ethtool iproute2 || true
    fi
}

setup_containerd_generic() {
    echo "Warning: Using generic method to set up containerd."
    echo "This may not work correctly on your distribution."
    echo "Please install containerd manually if needed."
    
    # Try to configure containerd if it's installed
    if command -v containerd &> /dev/null; then
        mkdir -p /etc/containerd
        containerd config default | tee /etc/containerd/config.toml
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        systemctl restart containerd
    else
        echo "containerd not found. Please install it manually."
    fi
}

setup_kubernetes_generic() {
    echo "Warning: Using generic method to set up Kubernetes."
    echo "This may not work correctly on your distribution."
    echo "Please install kubeadm, kubelet, and kubectl manually if needed."
}

cleanup_generic() {
    echo "Cleaning up existing cluster configuration..."
    if command -v kubeadm &> /dev/null; then
        kubeadm reset -f || true
    fi
    rm -rf /etc/cni/net.d/* || true
    rm -rf /var/lib/cni/ || true
    
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
    if command -v iptables &> /dev/null; then
        iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
    else
        echo "Warning: iptables command not found, skipping iptables reset"
    fi
}

# Parse command line arguments
KUBEADM_ARGS=""
while [[ $# -gt 0 ]]; do 
    case $1 in
        --help)
            show_help
            ;;
        --node-type)
            NODE_TYPE=$2
            shift 2
            ;;
        --kubernetes-version)
            K8S_VERSION=$2
            shift 2
            ;;
        --join-token)
            JOIN_TOKEN=$2
            shift 2
            ;;
        --join-address)
            JOIN_ADDRESS=$2
            shift 2
            ;;
        --discovery-token-hash)
            DISCOVERY_TOKEN_HASH=$2
            shift 2
            ;;
        --pod-network-cidr|--apiserver-advertise-address|--control-plane-endpoint|--service-cidr)
            KUBEADM_ARGS="$KUBEADM_ARGS $1 $2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

# Validate node type
if [[ "$NODE_TYPE" != "master" && "$NODE_TYPE" != "worker" ]]; then
    echo "Error: Node type must be either 'master' or 'worker'"
    exit 1
fi

# Check required arguments for worker nodes
if [[ "$NODE_TYPE" == "worker" ]]; then
    if [[ -z "$JOIN_TOKEN" || -z "$JOIN_ADDRESS" || -z "$DISCOVERY_TOKEN_HASH" ]]; then
        echo "Error: Worker nodes require --join-token, --join-address, and --discovery-token-hash"
        exit 1
    fi
fi

# Check root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with root privileges"
   exit 1
fi

echo "Starting Kubernetes initialization script..."
echo "Node type: ${NODE_TYPE}"
echo "Kubernetes Version: ${K8S_VERSION}"

# Detect distribution
detect_distribution

# Disable swap (common for all distributions)
echo "Disabling swap..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Disable zram swap (especially for Fedora and Arch)
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
        # Mask the service to prevent it from being started again
        echo "Masking $service to prevent automatic activation..."
        systemctl mask $service 2>/dev/null || true
    done
    
    # Handle zram-generator configuration
    if [ -f /usr/lib/systemd/zram-generator.conf ] || [ -d /etc/systemd/zram-generator.conf.d ]; then
        echo "Disabling zram swap configuration..."
        # Remove any existing configuration directory and recreate it
        if [ -d /etc/systemd/zram-generator.conf.d ]; then
            rm -rf /etc/systemd/zram-generator.conf.d
        fi
        mkdir -p /etc/systemd/zram-generator.conf.d
        
        # Create configuration to disable zram
        cat > /etc/systemd/zram-generator.conf.d/disable.conf <<EOF
[zram0]
zram-fraction=0
max-zram-size=0
EOF
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
        echo "You may need to disable swap manually or set --fail-swap-on=false in kubelet configuration."
    else
        echo "All swap has been successfully disabled."
    fi
fi

# Enable kernel modules (common for all distributions)
echo "Enabling required kernel modules..."
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Network settings (common for all distributions)
echo "Adjusting network settings..."
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# Install and configure based on distribution
case "$DISTRO_NAME" in
    debian|ubuntu)
        install_dependencies_debian
        setup_containerd_debian
        setup_kubernetes_debian
        cleanup_debian
        ;;
    centos|rhel|fedora|rocky|almalinux)
        echo "Setting up RHEL/Fedora based distribution..."
        install_dependencies_rhel
        setup_containerd_rhel
        setup_kubernetes_rhel
        cleanup_rhel
        ;;
    suse|opensuse*)
        install_dependencies_suse
        setup_containerd_suse
        setup_kubernetes_suse
        cleanup_suse
        ;;
    arch|manjaro)
        install_dependencies_arch
        setup_containerd_arch
        setup_kubernetes_arch
        cleanup_arch
        ;;
    *)
        echo "Warning: Unsupported distribution. Using generic methods."
        install_dependencies_generic
        setup_containerd_generic
        setup_kubernetes_generic
        cleanup_generic
        ;;
esac

if [[ "$NODE_TYPE" == "master" ]]; then
    # Initialize master node
    echo "Initializing master node..."
    echo "Using kubeadm init arguments: $KUBEADM_ARGS"
    kubeadm init $KUBEADM_ARGS

    # Configure kubectl
    echo "Configuring kubectl..."
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        # If run with sudo by a non-root user
        USER_HOME="/home/$SUDO_USER"
        mkdir -p "$USER_HOME/.kube"
        cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
        chown -R "$SUDO_USER:$(id -gn $SUDO_USER)" "$USER_HOME/.kube"
        echo "Created kubectl configuration for user $SUDO_USER"
    else
        # If run directly as root 
        mkdir -p /root/.kube
        cp -f /etc/kubernetes/admin.conf /root/.kube/config
        echo "Created kubectl configuration for root user at /root/.kube/config"
    fi

    # Display join command
    echo "Displaying join command for worker nodes..."
    kubeadm token create --print-join-command

    echo "Master node initialization complete!"
    echo "Next steps:"
    echo "1. Install a CNI plugin"
    echo "2. For single-node clusters, remove the taint with:"
    echo "   kubectl taint nodes --all node-role.kubernetes.io/control-plane-"

else
    # Join worker node
    echo "Joining worker node to cluster..."
    kubeadm join ${JOIN_ADDRESS} --token ${JOIN_TOKEN} --discovery-token-ca-cert-hash ${DISCOVERY_TOKEN_HASH}
    
    echo "Worker node has joined the cluster!"
fi

echo "Installed versions:"
kubectl version --client
kubeadm version
