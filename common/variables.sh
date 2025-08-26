#!/bin/bash

# Default values for global variables
K8S_VERSION=""
K8S_VERSION_USER_SET="false"
NODE_TYPE="master"  # Default is master node
JOIN_TOKEN=""
JOIN_ADDRESS=""
DISCOVERY_TOKEN_HASH=""
DISTRO_NAME=""
DISTRO_VERSION=""
DISTRO_FAMILY=""
CRI="containerd"  # Container runtime interface (containerd, crio, etc.)
PROXY_MODE="iptables"  # iptables or ipvs

# Additional variables for cleanup
FORCE=false
PRESERVE_CNI=false

# Arguments that will be passed to kubeadm
KUBEADM_ARGS=""