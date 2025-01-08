# Kubernetes Installation Script

This script automates the installation and configuration of a Kubernetes cluster on Ubuntu systems. It supports both master and worker node setup with customizable configuration options.

## Prerequisites

- Ubuntu operating system (tested only on Ubuntu 22.04 LTS)
- Root privileges or sudo access
- Internet connectivity
- Minimum system requirements:
  - 2 CPUs or more
  - 2GB of RAM per machine
  - Full network connectivity between all machines in the cluster

## How to Use

Download and run the installation script in one command:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/hack/setup-k8s.sh | sudo bash -s -- [options]
```

Or if you want to inspect the script before running:
```bash
# First download
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/hack/setup-k8s.sh -o setup-k8s.sh

# Inspect the script
less setup-k8s.sh

# Make executable and run
chmod +x setup-k8s.sh
sudo ./setup-k8s.sh [options]
```

## Usage Options

### Setting up a Master Node

Basic master node setup with default settings:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/hack/setup-k8s.sh | sudo bash -s -- --node-type master
```

Advanced master node setup with custom configuration:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/hack/setup-k8s.sh | sudo bash -s -- \
  --node-type master \
  --kubernetes-version 1.29 \
  --pod-network-cidr 192.168.0.0/16 \
  --apiserver-advertise-address 192.168.1.10 \
  --service-cidr 10.96.0.0/12
```

### Setting up a Worker Node

To join a worker node to the cluster, you'll need three pieces of information from the master node:
- Join token
- Join address
- Discovery token hash

These can be obtained by running `kubeadm token create --print-join-command` on the master node.

Example worker node setup:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/hack/setup-k8s.sh | sudo bash -s -- \
  --node-type worker \
  --join-token abcdef.1234567890abcdef \
  --join-address 192.168.1.10:6443 \
  --discovery-token-hash sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
```

## Available Options

| Option | Description | Example |
|--------|-------------|---------|
| --node-type | Type of node (master/worker) | --node-type master |
| --kubernetes-version | Kubernetes version to install | --kubernetes-version 1.29 |
| --pod-network-cidr | CIDR for pod network | --pod-network-cidr 192.168.0.0/16 |
| --apiserver-advertise-address | API server advertise address | --apiserver-advertise-address 192.168.1.10 |
| --control-plane-endpoint | Control plane endpoint | --control-plane-endpoint cluster.example.com |
| --service-cidr | CIDR for services | --service-cidr 10.96.0.0/12 |
| --join-token | Token for joining worker nodes | --join-token abcdef.1234567890abcdef |
| --join-address | Master node address for workers | --join-address 192.168.1.10:6443 |
| --discovery-token-hash | Discovery token hash for workers | --discovery-token-hash sha256:abc... |
| --help | Display help message | --help |

## Post-Installation Steps

### For Master Node

1. Install a CNI (Container Network Interface) plugin. For example, to install Calico:
```bash
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

2. For single-node clusters, remove the control-plane taint:
```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

3. Verify the installation:
```bash
kubectl get nodes
```

### For Worker Node

1. Verify that the node has joined the cluster by running on the master node:
```bash
kubectl get nodes
```

## Troubleshooting

1. If the installation fails, check the logs for error messages:
```bash
journalctl -xeu kubelet
```

2. If a worker node fails to join:
- Verify network connectivity between master and worker nodes
- Ensure the join token hasn't expired (tokens expire after 24 hours by default)
- Check firewall rules allow necessary Kubernetes ports

3. To reset a node and start over:
```bash
sudo ./k8s-install.sh [options]  # The script automatically performs cleanup
```

## Support

For issues and feature requests, please open an issue in the repository or contact the maintainer.
