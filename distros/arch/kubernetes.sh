#!/bin/sh

# Kubernetes setup/upgrade for Arch Linux.
# AUR helper infrastructure → distros/arch/aur.sh

# Source AUR helper infrastructure (guarded for bundle mode where it's already inlined)
if ! type _ensure_aur_helper >/dev/null 2>&1; then
    if [ -f "${SCRIPT_DIR:-}/distros/arch/aur.sh" ]; then
        . "${SCRIPT_DIR}/distros/arch/aur.sh"
    fi
fi

# Setup Kubernetes for Arch Linux
setup_kubernetes_arch() {
    log_info "Setting up Kubernetes for Arch-based distribution..."

    log_info "Note: Arch AUR packages always install the latest Kubernetes version."

    log_info "Setting up AUR helper for Kubernetes installation..."
    _ensure_aur_helper || return 1

    log_info "Using AUR helper: $AUR_HELPER"
    _aur_install_packages kubeadm-bin kubelet-bin kubectl-bin || return 1

    # Enable and start kubelet
    _enable_and_start_kubelet
}

# Upgrade kubeadm to a specific MAJOR.MINOR.PATCH version
upgrade_kubeadm_arch() {
    local target="$1"
    log_warn "Arch AUR packages always install the latest version. Cannot pin to ${target}."
    log_warn "Ensure the AUR packages match or exceed v${target}."

    _ensure_aur_helper || return 1
    _aur_install_packages kubeadm-bin || return 1
}

# Upgrade kubelet and kubectl to a specific MAJOR.MINOR.PATCH version
upgrade_kubelet_kubectl_arch() {
    local target="$1"
    log_warn "Arch AUR packages always install the latest version. Cannot pin to ${target}."

    _ensure_aur_helper || return 1
    _aur_install_packages kubelet-bin kubectl-bin || return 1
}
