#!/bin/bash

# Source common variables (only when not already loaded by the entry script)
if [ -z "${K8S_VERSION+x}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/../../common/variables.sh" 2>/dev/null || true
fi

# Setup Kubernetes for Debian/Ubuntu
setup_kubernetes_debian() {
    echo "Setting up Kubernetes for Debian-based distribution..."
    
    # Create keyrings directory if it doesn't exist
    mkdir -p /etc/apt/keyrings
    
    # Add Kubernetes repository GPG key (skip if already present for this version)
    if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
        curl -fsSL --retry 3 --retry-delay 2 "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    fi
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
    
    apt-get update
    
    # Find available version (avoid pipe to prevent SIGPIPE under pipefail)
    local madison_out
    madison_out=$(apt-cache madison kubeadm)
    VERSION_STRING=$(echo "$madison_out" | awk -v ver="${K8S_VERSION}" '$0 ~ ver {print $3; exit}')
    if [ -z "$VERSION_STRING" ]; then
        echo "Specified version ${K8S_VERSION} not found"
        exit 1
    fi
    
    # Install Kubernetes components
    apt-get install -y --allow-change-held-packages kubelet=${VERSION_STRING} kubeadm=${VERSION_STRING} kubectl=${VERSION_STRING}
    apt-mark hold kubelet kubeadm kubectl
}