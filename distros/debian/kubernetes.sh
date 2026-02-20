#!/bin/bash

# Setup Kubernetes for Debian/Ubuntu
setup_kubernetes_debian() {
    log_info "Setting up Kubernetes for Debian-based distribution..."
    
    # Create keyrings directory if it doesn't exist
    mkdir -p /etc/apt/keyrings
    
    # Add Kubernetes repository GPG key (always refresh to pick up key rotation)
    curl -fsSL --retry 3 --retry-delay 2 "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
    
    apt-get update
    
    # Find available version (avoid pipe to prevent SIGPIPE under pipefail)
    local madison_out
    madison_out=$(apt-cache madison kubeadm)
    local VERSION_STRING
    VERSION_STRING=$(echo "$madison_out" | awk -v ver="${K8S_VERSION}." 'index($0, ver) {print $3; exit}')
    if [ -z "$VERSION_STRING" ]; then
        log_error "Specified version ${K8S_VERSION} not found"
        return 1
    fi
    
    # Install Kubernetes components
    apt-get install -y --allow-change-held-packages kubelet="${VERSION_STRING}" kubeadm="${VERSION_STRING}" kubectl="${VERSION_STRING}"
    apt-mark hold kubelet kubeadm kubectl

    # Enable and start kubelet (consistent with other distros)
    systemctl enable --now kubelet
}