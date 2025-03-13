#!/bin/bash

set -e

# Default values
K8S_VERSION="1.32"
NODE_TYPE="master"  # Default is master node
JOIN_TOKEN=""
JOIN_ADDRESS=""
DISCOVERY_TOKEN_HASH=""

# Help message
show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --node-type    Node type (master, worker, or only-setup)"
    echo "  --pod-network-cidr   Pod network CIDR (e.g., 192.168.0.0/16)"
    echo "  --apiserver-advertise-address   API server advertise address"
    echo "  --control-plane-endpoint   Control plane endpoint"
    echo "  --service-cidr    Service CIDR (e.g., 10.96.0.0/12)"
    echo "  --kubernetes-version   Kubernetes version (e.g., 1.29, 1.28)"
    echo "  --join-token    Join token for worker nodes"
    echo "  --join-address  Master node address for worker nodes"
    echo "  --discovery-token-hash  Discovery token hash for worker nodes"
    echo "  --help            Display this help message"
    exit 0
}

# Parse command line arguments
KUBEADM_ARGS=""
while [[ $# -gt 0 ]]; do 
    case $1 in
        --help)
            show_help
            ;;
        --node-type)
            NODE_TYPE=$2
            shift 2
            ;;
        --kubernetes-version)
            K8S_VERSION=$2
            shift 2
            ;;
        --join-token)
            JOIN_TOKEN=$2
            shift 2
            ;;
        --join-address)
            JOIN_ADDRESS=$2
            shift 2
            ;;
        --discovery-token-hash)
            DISCOVERY_TOKEN_HASH=$2
            shift 2
            ;;
        --pod-network-cidr|--apiserver-advertise-address|--control-plane-endpoint|--service-cidr)
            KUBEADM_ARGS="$KUBEADM_ARGS $1 $2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

# Validate node type
if [[ "$NODE_TYPE" != "master" && "$NODE_TYPE" != "worker" && "$NODE_TYPE" != "only-setup" ]]; then
    echo "Error: Node type must be either 'master', 'worker', or 'only-setup'"
    exit 1
fi

# Check required arguments for worker nodes
if [[ "$NODE_TYPE" == "worker" ]]; then
    if [[ -z "$JOIN_TOKEN" || -z "$JOIN_ADDRESS" || -z "$DISCOVERY_TOKEN_HASH" ]]; then
        echo "Error: Worker nodes require --join-token, --join-address, and --discovery-token-hash"
        exit 1
    fi
fi

# Check root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with root privileges"
   exit 1
fi

echo "Starting Kubernetes initialization script..."
echo "Node type: ${NODE_TYPE}"
echo "Kubernetes Version: ${K8S_VERSION}"

# Disable swap
echo "Disabling swap..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Enable kernel modules
echo "Enabling required kernel modules..."
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Network settings
echo "Adjusting network settings..."
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# Install containerd
echo "Installing containerd..."
apt-get update
apt-get install -y apt-transport-https ca-certificates curl software-properties-common

# Add containerd repository
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list

# Install and configure containerd
apt-get update
apt-get install -y containerd.io

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd

# Install kubeadm
echo "Installing kubeadm, kubelet, kubectl... (version: ${K8S_VERSION})"
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update

# Install specific version
VERSION_STRING=$(apt-cache madison kubeadm | grep ${K8S_VERSION} | head -1 | awk '{print $3}')
if [ -z "$VERSION_STRING" ]; then
    echo "Specified version ${K8S_VERSION} not found"
    exit 1
fi

apt-get install -y --allow-change-held-packages kubelet=${VERSION_STRING} kubeadm=${VERSION_STRING} kubectl=${VERSION_STRING}
apt-mark hold kubelet kubeadm kubectl

# If only-setup is specified, exit here
if [[ "$NODE_TYPE" == "only-setup" ]]; then
    echo "Setup completed successfully!"
    echo "Kubernetes components have been installed, but no cluster has been initialized or joined."
    echo ""
    echo "To initialize a master node later, run:"
    echo "  $0 --node-type master [other options]"
    echo ""
    echo "To join as a worker node later, run:"
    echo "  $0 --node-type worker --join-token TOKEN --join-address ADDRESS --discovery-token-hash HASH"
    echo ""
    echo "Installed versions:"
    kubectl version --client
    kubeadm version
    exit 0
fi

# Reset existing cluster configuration
echo "Cleaning up existing cluster configuration..."
kubeadm reset -f || true
rm -rf /etc/cni/net.d/* || true
rm -rf /var/lib/cni/ || true

# Clean up .kube directory
if [ -n "$SUDO_USER" ]; then
    USER_HOME="/home/$SUDO_USER"
    echo "Cleanup: Removing .kube directory for user $SUDO_USER"
    rm -rf "$USER_HOME/.kube" || true
else
    echo "Cleanup: Removing .kube directory for root user"
    rm -rf $HOME/.kube/ || true
fi

# Reset iptables rules
echo "Resetting iptables rules..."
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X

if [[ "$NODE_TYPE" == "master" ]]; then
    # Initialize master node
    echo "Initializing master node..."
    echo "Using kubeadm init arguments: $KUBEADM_ARGS"
    kubeadm init $KUBEADM_ARGS

    # Configure kubectl
    echo "Configuring kubectl..."
    if [ -n "$SUDO_USER" ]; then
        USER_HOME="/home/$SUDO_USER"
        mkdir -p "$USER_HOME/.kube"
        cp -i /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
        chown -R "$SUDO_USER:$(id -gn $SUDO_USER)" "$USER_HOME/.kube"
        echo "Created kubectl configuration for user $SUDO_USER"
    else
        # If run directly as root
        mkdir -p $HOME/.kube
        cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        echo "Created kubectl configuration for root user"
    fi

    # Display join command
    echo "Displaying join command for worker nodes..."
    kubeadm token create --print-join-command

    echo "Master node initialization complete!"
    echo "Next steps:"
    echo "1. Install a CNI plugin"
    echo "2. For single-node clusters, remove the taint with:"
    echo "   kubectl taint nodes --all node-role.kubernetes.io/control-plane-"

else
    # Join worker node
    echo "Joining worker node to cluster..."
    kubeadm join ${JOIN_ADDRESS} --token ${JOIN_TOKEN} --discovery-token-ca-cert-hash ${DISCOVERY_TOKEN_HASH}
    
    echo "Worker node has joined the cluster!"
fi

echo "Installed versions:"
kubectl version --client
kubeadm version