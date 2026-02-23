#!/bin/sh
# shellcheck disable=SC2034 # variables are used by sourcing scripts

# Log level: 0=quiet, 1=normal (default), 2=verbose
LOG_LEVEL="${LOG_LEVEL:-1}"

# Dry-run mode
DRY_RUN="${DRY_RUN:-false}"

# Default values for global variables
K8S_VERSION=""
ACTION="${ACTION:-}"  # init or join (set by subcommand)
JOIN_TOKEN=""
JOIN_ADDRESS=""
DISCOVERY_TOKEN_HASH=""
DISTRO_OVERRIDE=""  # Manual distro family override (debian, rhel, suse, arch, generic)
DISTRO_NAME=""
DISTRO_VERSION=""
DISTRO_FAMILY=""
CRI="containerd"  # Container runtime interface (containerd, crio, etc.)
PROXY_MODE="iptables"  # iptables, ipvs, or nftables (nftables requires K8s 1.29+)
SWAP_ENABLED=false  # Keep swap enabled (K8s 1.28+, NodeSwap feature)

# HA cluster support
JOIN_AS_CONTROL_PLANE=false
CERTIFICATE_KEY=""
HA_ENABLED=false
HA_VIP_ADDRESS=""
HA_VIP_INTERFACE=""

# Additional variables for cleanup
FORCE=false
PRESERVE_CNI=false

# Kubeadm configuration (parsed from CLI args)
KUBEADM_POD_CIDR=""
KUBEADM_SERVICE_CIDR=""
KUBEADM_API_ADDR=""
KUBEADM_CP_ENDPOINT=""

# Shell completion variables
ENABLE_COMPLETION=true  # Enable shell completion setup for kubectl, kubeadm, etc.
INSTALL_HELM=false  # Install Helm package manager
COMPLETION_SHELLS="auto"  # auto, bash, zsh, fish, or comma-separated list

# Deploy subcommand
DEPLOY_CONTROL_PLANES=""
DEPLOY_WORKERS=""
DEPLOY_SSH_USER="root"
DEPLOY_SSH_PORT="22"
DEPLOY_SSH_KEY=""
DEPLOY_SSH_PASSWORD="${DEPLOY_SSH_PASSWORD:-}"
DEPLOY_SSH_KNOWN_HOSTS_FILE=""
DEPLOY_SSH_HOST_KEY_CHECK="${DEPLOY_SSH_HOST_KEY_CHECK:-yes}"
DEPLOY_PASSTHROUGH_ARGS=""

# Upgrade subcommand
UPGRADE_TARGET_VERSION=""            # MAJOR.MINOR.PATCH (e.g., 1.33.2)
UPGRADE_FIRST_CONTROL_PLANE=false    # kubeadm upgrade apply (first CP) vs kubeadm upgrade node
UPGRADE_SKIP_DRAIN=false             # Skip drain/uncordon in remote mode
UPGRADE_PASSTHROUGH_ARGS=""          # Arguments to forward to remote nodes

# Remove subcommand
REMOVE_CONTROL_PLANE=""              # remove: CP node (user@ip)
REMOVE_NODES=""                      # remove: target nodes (comma-separated)
REMOVE_PASSTHROUGH_ARGS=""           # remove: args to forward

# Backup/Restore subcommand
ETCD_SNAPSHOT_PATH=""         # snapshot file path (backup: output, restore: input)
ETCD_CONTROL_PLANE=""         # remote mode: target control-plane node (user@ip or ip)
ETCD_PASSTHROUGH_ARGS=""      # arguments to forward to remote nodes

# Status subcommand
STATUS_OUTPUT_FORMAT="text"   # output format: text or wide

# Preflight subcommand
PREFLIGHT_MODE="init"
PREFLIGHT_CRI="containerd"
PREFLIGHT_PROXY_MODE="iptables"

# Version constants (overridable via environment)
KUBE_VIP_VERSION="${KUBE_VIP_VERSION:-v0.8.9}"
PAUSE_IMAGE_VERSION="${PAUSE_IMAGE_VERSION:-3.10}"

# Component version defaults for generic distro (overridable via environment)
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.0.4}"
RUNC_VERSION="${RUNC_VERSION:-1.2.5}"
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-1.6.2}"
CRIO_VERSION="${CRIO_VERSION:-1.32.0}"
# Bundle module list: bootstrap + _COMMON_MODULES (defined in bootstrap.sh)
BUNDLE_COMMON_MODULES="bootstrap ${_COMMON_MODULES:-}"

# Cleanup options
REMOVE_HELM=false  # Remove Helm during cleanup (opt-in via --remove-helm)
