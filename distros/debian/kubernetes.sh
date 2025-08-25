#!/bin/bash

# Source common variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../common/variables.sh"

# Setup Kubernetes for Debian/Ubuntu
setup_kubernetes_debian() {
    echo "Setting up Kubernetes for Debian-based distribution..."
    
    # Create keyrings directory if it doesn't exist
    mkdir -p /etc/apt/keyrings
    
    # Add Kubernetes repository
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
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