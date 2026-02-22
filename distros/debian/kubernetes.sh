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
    _service_enable kubelet
    _service_start kubelet
}

# Upgrade kubeadm to a specific MAJOR.MINOR.PATCH version
upgrade_kubeadm_debian() {
    local target="$1"
    local minor
    minor=$(_version_minor "$target")

    log_info "Updating Kubernetes apt repository to v${minor}..."
    curl -fsSL --retry 3 --retry-delay 2 "https://pkgs.k8s.io/core:/stable:/v${minor}/deb/Release.key" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${minor}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
    apt-get update

    # Find exact version string
    local madison_out VERSION_STRING
    madison_out=$(apt-cache madison kubeadm)
    VERSION_STRING=$(echo "$madison_out" | awk -v ver="${target}-" 'index($0, ver) {print $3; exit}')
    if [ -z "$VERSION_STRING" ]; then
        # Fallback: try with minor version prefix
        VERSION_STRING=$(echo "$madison_out" | awk -v ver="${minor}." 'index($0, ver) {print $3; exit}')
    fi
    if [ -z "$VERSION_STRING" ]; then
        log_error "kubeadm version ${target} not found in apt repository"
        return 1
    fi

    apt-mark unhold kubeadm
    apt-get install -y --allow-change-held-packages kubeadm="${VERSION_STRING}"
    apt-mark hold kubeadm
}

# Upgrade kubelet and kubectl to a specific MAJOR.MINOR.PATCH version
upgrade_kubelet_kubectl_debian() {
    local target="$1"

    local madison_out VERSION_STRING
    madison_out=$(apt-cache madison kubelet)
    VERSION_STRING=$(echo "$madison_out" | awk -v ver="${target}-" 'index($0, ver) {print $3; exit}')
    if [ -z "$VERSION_STRING" ]; then
        local minor
        minor=$(_version_minor "$target")
        VERSION_STRING=$(echo "$madison_out" | awk -v ver="${minor}." 'index($0, ver) {print $3; exit}')
    fi
    if [ -z "$VERSION_STRING" ]; then
        log_error "kubelet version ${target} not found in apt repository"
        return 1
    fi

    apt-mark unhold kubelet kubectl
    apt-get install -y --allow-change-held-packages kubelet="${VERSION_STRING}" kubectl="${VERSION_STRING}"
    apt-mark hold kubelet kubectl
}