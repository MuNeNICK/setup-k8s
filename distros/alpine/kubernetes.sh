#!/bin/sh

# Setup Kubernetes for Alpine Linux
setup_kubernetes_alpine() {
    log_info "Setting up Kubernetes for Alpine Linux..."

    # Try installing from the current community repo first
    if ! apk add --no-cache \
        "kubeadm=~${K8S_VERSION}" \
        "kubelet=~${K8S_VERSION}" \
        "kubectl=~${K8S_VERSION}" \
        kubelet-openrc 2>/dev/null; then

        # Fall back to edge/community for newer versions
        log_info "Packages not found in current repo, trying edge/community..."
        apk add --no-cache \
            --repository "https://dl-cdn.alpinelinux.org/alpine/edge/community" \
            "kubeadm=~${K8S_VERSION}" \
            "kubelet=~${K8S_VERSION}" \
            "kubectl=~${K8S_VERSION}" \
            kubelet-openrc
    fi

    _enable_and_start_kubelet
}

# Upgrade kubeadm to a specific MAJOR.MINOR.PATCH version
upgrade_kubeadm_alpine() {
    local target="$1"
    local minor
    minor=$(_k8s_minor_version "$target")

    log_info "Upgrading kubeadm to v${target}..."
    if ! apk add --no-cache "kubeadm=~${minor}" 2>/dev/null; then
        apk add --no-cache \
            --repository "https://dl-cdn.alpinelinux.org/alpine/edge/community" \
            "kubeadm=~${minor}"
    fi
}

# Upgrade kubelet and kubectl to a specific MAJOR.MINOR.PATCH version
upgrade_kubelet_kubectl_alpine() {
    local target="$1"
    local minor
    minor=$(_k8s_minor_version "$target")

    log_info "Upgrading kubelet and kubectl to v${target}..."
    if ! apk add --no-cache \
        "kubelet=~${minor}" \
        "kubectl=~${minor}" 2>/dev/null; then
        apk add --no-cache \
            --repository "https://dl-cdn.alpinelinux.org/alpine/edge/community" \
            "kubelet=~${minor}" \
            "kubectl=~${minor}"
    fi
}
