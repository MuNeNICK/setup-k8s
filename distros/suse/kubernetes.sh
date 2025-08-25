#!/bin/bash

# Source common variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../common/variables.sh"

# Setup Kubernetes for SUSE
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