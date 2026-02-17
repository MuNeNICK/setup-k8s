#!/bin/bash

# Source common variables (only when not already loaded by the entry script)
if [ -z "${K8S_VERSION+x}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/../../common/variables.sh" 2>/dev/null || true
fi

# Setup Kubernetes for SUSE
setup_kubernetes_suse() {
    echo "Setting up Kubernetes for SUSE-based distribution..."
    
    # Import GPG key for Kubernetes repository
    rpm --import https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
    
    # Add Kubernetes repository with GPG check enabled
    zypper addrepo --gpgcheck https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/ kubernetes
    
    # Install Kubernetes components (non-interactive mode)
    zypper --non-interactive refresh
    zypper --non-interactive install -y kubelet kubeadm kubectl
    
    # Enable and start kubelet
    systemctl enable --now kubelet
}