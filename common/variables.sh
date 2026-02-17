#!/bin/bash

# Log level: 0=quiet, 1=normal (default), 2=verbose
LOG_LEVEL="${LOG_LEVEL:-1}"

# Dry-run mode
DRY_RUN=false

# Default values for global variables
K8S_VERSION=""
K8S_VERSION_USER_SET="false"
K8S_VERSION_FALLBACK="${K8S_VERSION_FALLBACK:-1.32}"
NODE_TYPE="master"  # Default is master node
JOIN_TOKEN=""
JOIN_ADDRESS=""
DISCOVERY_TOKEN_HASH=""
DISTRO_NAME=""
DISTRO_VERSION=""
DISTRO_FAMILY=""
CRI="containerd"  # Container runtime interface (containerd, crio, etc.)
PROXY_MODE="iptables"  # iptables, ipvs, or nftables (nftables requires K8s 1.29+)

# HA cluster support
JOIN_AS_CONTROL_PLANE=false
CERTIFICATE_KEY=""

# Additional variables for cleanup
FORCE=false
PRESERVE_CNI=false

# Arguments that will be passed to kubeadm (as array)
declare -a KUBEADM_ARGS=()

# Shell completion variables
ENABLE_COMPLETION=true  # Enable shell completion setup for kubectl, kubeadm, etc.
INSTALL_HELM=false  # Install Helm package manager
COMPLETION_SHELLS="auto"  # auto, bash, zsh, fish, or comma-separated list
