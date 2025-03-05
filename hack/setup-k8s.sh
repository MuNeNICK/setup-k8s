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
                echo "Attempting to continue, but you may need to manually install some components."
            fi
            ;;
    esac
}

# Debian/Ubuntu specific functions
install_dependencies_debian() {
    echo "Installing dependencies for Debian-based distribution..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg
}

setup_containerd_debian() {
    echo "Setting up containerd for Debian-based distribution..."
    
    # Create keyrings directory if it doesn't exist
    mkdir -p /etc/apt/keyrings
    
    # Add Docker repository (for containerd)
    if [ "$DISTRO_NAME" = "ubuntu" ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list
    else
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list
    fi
    
    # Install containerd
    apt-get update
    apt-get install -y containerd.io
    
    # Configure containerd
    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    systemctl restart containerd
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
    
    # Install essential packages including iptables
    echo "Installing essential packages..."
    $PKG_MGR install -y curl gnupg2 iptables iptables-services
    
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
    $PKG_MGR install -y yum-utils device-mapper-persistent-data lvm2
    
    # Add Docker repository (for containerd)
    echo "Adding Docker repository..."
    if [ "$DISTRO_NAME" = "fedora" ]; then
        $PKG_MGR config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    else
        # For CentOS/RHEL
        $PKG_MGR config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    
    # Install containerd
    echo "Installing containerd.io package..."
    $PKG_MGR install -y containerd.io
    
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
    $PKG_MGR install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
    
    # Check if installation was successful
    if ! command -v kubeadm &> /dev/null; then
        echo "Error: kubeadm installation failed. Trying alternative approach..."
        # Try installing with different options
        $PKG_MGR install -y --nogpgcheck kubelet kubeadm kubectl || true
        
        # If still not installed, try installing from CentOS 8 repository for CentOS 9
        if ! command -v kubeadm &> /dev/null && [ "$DISTRO_NAME" = "centos" ] && [[ "$DISTRO_VERSION" == "9"* ]]; then
            echo "Trying to install Kubernetes components from CentOS 8 repository..."
            $PKG_MGR install -y --releasever=8 kubelet kubeadm kubectl || true
        fi
    fi
    
    # Hold packages (prevent automatic updates)
    echo "Preventing automatic updates of Kubernetes packages..."
    if command -v dnf &> /dev/null; then
        dnf versionlock add kubelet kubeadm kubectl || echo "Warning: versionlock not available, skipping"
    else
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
    zypper install -y curl
}

setup_containerd_suse() {
    echo "Setting up containerd for SUSE-based distribution..."
    
    # Add Docker repository (for containerd)
    zypper addrepo https://download.docker.com/linux/sles/docker-ce.repo
    
    # Install containerd
    zypper refresh
    zypper install -y containerd.io
    
    # Configure containerd
    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    systemctl restart containerd
}

setup_kubernetes_suse() {
    echo "Setting up Kubernetes for SUSE-based distribution..."
    
    # Add Kubernetes repository
    zypper addrepo --gpgcheck-allow-unsigned-repo https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/ kubernetes
    
    # Install Kubernetes components
    zypper refresh
    zypper install -y kubelet kubeadm kubectl
    
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
    pacman -Sy --noconfirm curl
}

setup_containerd_arch() {
    echo "Setting up containerd for Arch-based distribution..."
    
    # Install containerd
    pacman -Sy --noconfirm containerd
    
    # Configure containerd
    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    systemctl restart containerd
}

setup_kubernetes_arch() {
    echo "Setting up Kubernetes for Arch-based distribution..."
    
    # Install Kubernetes components from AUR or community repo
    # Note: This is a simplified approach. In practice, you might need to use an AUR helper or manually build packages
    if pacman -Ss kubeadm | grep -q "^community/kubeadm"; then
        pacman -Sy --noconfirm kubeadm kubelet kubectl
    else
        echo "Kubernetes packages not found in official repositories."
        echo "Please install kubeadm, kubelet, and kubectl manually from the AUR."
        echo "You can use an AUR helper like 'yay' or 'paru'."
        exit 1
    fi
    
    # Enable and start kubelet
    systemctl enable --now kubelet
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
}

# Generic functions for unsupported distributions
install_dependencies_generic() {
    echo "Warning: Using generic method to install dependencies."
    echo "This may not work correctly on your distribution."
    echo "Please install the following packages manually if needed:"
    echo "- curl"
    echo "- containerd"
    echo "- kubeadm, kubelet, kubectl"
    echo "- iptables"
    
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
# For CentOS, directly use RHEL functions regardless of DISTRO_FAMILY
if [ "$DISTRO_NAME" = "centos" ]; then
    echo "Setting up CentOS based distribution..."
    install_dependencies_rhel
    setup_containerd_rhel
    setup_kubernetes_rhel
    cleanup_rhel
else
    # For other distributions, check the family
    case "$DISTRO_FAMILY" in
        *debian*)
            install_dependencies_debian
            setup_containerd_debian
            setup_kubernetes_debian
            cleanup_debian
            ;;
        *rhel*|*fedora*)
            echo "Setting up RHEL/Fedora based distribution..."
            install_dependencies_rhel
            setup_containerd_rhel
            setup_kubernetes_rhel
            cleanup_rhel
            ;;
        *suse*)
            install_dependencies_suse
            setup_containerd_suse
            setup_kubernetes_suse
            cleanup_suse
            ;;
        *arch*)
            install_dependencies_arch
            setup_containerd_arch
            setup_kubernetes_arch
            cleanup_arch
            ;;
        *)
            echo "Warning: Unsupported distribution family. Using generic methods."
            install_dependencies_generic
            setup_containerd_generic
            setup_kubernetes_generic
            cleanup_generic
            ;;
    esac
fi

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
