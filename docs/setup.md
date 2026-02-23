# Installation Guide

## Quick Start

Download and run the installation script:
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- init
```

Manual download and inspection:
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh -o setup-k8s.sh
less setup-k8s.sh
chmod +x setup-k8s.sh
sudo ./setup-k8s.sh init
```

## Cluster Initialization

Basic setup with default containerd:
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- init
```

Setup with CRI-O runtime:
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --cri crio
```

Advanced setup:
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --kubernetes-version 1.29 \
  --cri containerd \
  --pod-network-cidr 192.168.0.0/16 \
  --apiserver-advertise-address 192.168.1.10 \
  --service-cidr 10.96.0.0/12
```

Setup with IPVS mode for better performance:
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --proxy-mode ipvs \
  --pod-network-cidr 192.168.0.0/16
```

Setup with nftables mode (requires K8s 1.29+):
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --proxy-mode nftables \
  --kubernetes-version 1.31 \
  --pod-network-cidr 192.168.0.0/16
```

## Joining a Cluster

Obtain join information from the control-plane node:
```bash
# Run on control-plane node
kubeadm token create --print-join-command
```

Join as a worker node:
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  join \
  --cri containerd \
  --join-token <token> \
  --join-address <address> \
  --discovery-token-hash <hash>
```

Join as a control-plane node (HA cluster):
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  join \
  --control-plane \
  --certificate-key <key> \
  --join-token <token> \
  --join-address <address> \
  --discovery-token-hash <hash>
```

Note: The joining node must use the same CRI as the existing cluster.

## Prerequisites

### System Requirements
- One of the [supported distributions](../README.md#distribution-test-results)
- 2 CPUs or more
- 2GB of RAM per machine
- Full network connectivity between cluster machines

### Access Requirements
- Root privileges or sudo access
- Internet connectivity
- Open required ports for Kubernetes communication
