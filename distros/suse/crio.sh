#!/bin/bash

# Source common helpers and variables (only when not already loaded by the entry script)
if ! type -t configure_crictl &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/../../common/helpers.sh" 2>/dev/null || true
    source "${SCRIPT_DIR}/../../common/variables.sh" 2>/dev/null || true
fi

# SUSE Leap compatibility helpers for CRI-O vs Kubernetes
get_suse_leap_supported_k8s_minor() {
    local detected_minor=""
    if command -v zypper &>/dev/null; then
        detected_minor=$(zypper -q se -s 'kubernetes1.*-kubeadm' 2>/dev/null \
            | grep -oE 'kubernetes1\.[0-9]+-kubeadm' \
            | sed -E 's/.*kubernetes1\.([0-9]+)-kubeadm/\1/' \
            | sort -nr | head -1 || true)
    fi
    if [ -z "$detected_minor" ]; then
        local crio_minor=""
        if rpm -q cri-o &>/dev/null; then
            crio_minor=$(rpm -q --qf '%{VERSION}\n' cri-o 2>/dev/null | awk -F. '{print $2}' | head -1)
        else
            crio_minor=$(zypper -q info -s cri-o 2>/dev/null \
                | awk '/Version/ {print $3}' \
                | awk -F. '{print $2}' | head -1)
        fi
        detected_minor="$crio_minor"
    fi
    echo -n "$detected_minor"
}

warn_and_fail_if_suse_leap_crio_incompatible() {
    if [ "$CRI" != "crio" ]; then return 0; fi
    if [ "$DISTRO_NAME" != "suse" ]; then return 0; fi
    case "$DISTRO_VERSION" in
        15* ) : ;;
        * ) return 0 ;;
    esac
    local requested_minor="${K8S_VERSION#*.}"
    local supported_minor
    supported_minor=$(get_suse_leap_supported_k8s_minor)
    if [ -z "$supported_minor" ]; then
        echo "WARNING: Could not determine latest Kubernetes minor supported on openSUSE Leap ${DISTRO_VERSION} with CRI-O."
        echo "WARNING: Consider using containerd or switching to Tumbleweed/MicroOS for latest CRI-O."
        return 1
    fi
    if [ -n "$requested_minor" ] && [ "$requested_minor" -gt "$supported_minor" ] 2>/dev/null; then
        echo "WARNING: Requested Kubernetes v1.${requested_minor} exceeds openSUSE Leap ${DISTRO_VERSION} support with CRI-O."
        echo "WARNING: Latest supported on Leap appears to be Kubernetes v1.${supported_minor}."
        echo "WARNING: Setup will fail by design to avoid incompatible installation."
        return 1
    fi
    return 0
}

# Setup CRI-O for SUSE
setup_crio_suse() {
    if ! warn_and_fail_if_suse_leap_crio_incompatible; then
        exit 1
    fi
    echo "CRI-O selected. Attempting installation..."
    zypper refresh
    zypper install -y cri-o || echo "CRI-O may require specific repositories on your SUSE version."
    systemctl enable --now crio || true
    configure_crictl crio
}