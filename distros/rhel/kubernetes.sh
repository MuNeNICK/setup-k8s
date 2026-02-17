#!/bin/bash

# Source common variables (only when not already loaded by the entry script)
if [ -z "${K8S_VERSION+x}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/../../common/variables.sh" 2>/dev/null || true
fi

# Setup Kubernetes for RHEL/CentOS/Fedora
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
        echo "WARNING: Retrying with --nogpgcheck. GPG signature verification will be skipped." >&2
        echo "WARNING: This is less secure. Verify packages manually if possible." >&2
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