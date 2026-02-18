#!/bin/bash

# Log level: 0=quiet, 1=normal (default), 2=verbose
export LOG_LEVEL="${LOG_LEVEL:-1}"

# Dry-run mode
export DRY_RUN="${DRY_RUN:-false}"

# Default values for global variables
export K8S_VERSION=""
export K8S_VERSION_FALLBACK="${K8S_VERSION_FALLBACK:-1.32}"
export ACTION=""  # init or join (set by subcommand)
export JOIN_TOKEN=""
export JOIN_ADDRESS=""
export DISCOVERY_TOKEN_HASH=""
export DISTRO_NAME=""
export DISTRO_VERSION=""
export DISTRO_FAMILY=""
export CRI="containerd"  # Container runtime interface (containerd, crio, etc.)
export PROXY_MODE="iptables"  # iptables, ipvs, or nftables (nftables requires K8s 1.29+)

# HA cluster support
export JOIN_AS_CONTROL_PLANE=false
export CERTIFICATE_KEY=""
export HA_ENABLED=false
export HA_VIP_ADDRESS=""
export HA_VIP_INTERFACE=""

# Additional variables for cleanup
export FORCE=false
export PRESERVE_CNI=false

# Arguments that will be passed to kubeadm (as array)
KUBEADM_ARGS=()
export KUBEADM_ARGS

# Shell completion variables
export ENABLE_COMPLETION=true  # Enable shell completion setup for kubectl, kubeadm, etc.
export INSTALL_HELM=false  # Install Helm package manager
export COMPLETION_SHELLS="auto"  # auto, bash, zsh, fish, or comma-separated list
