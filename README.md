# Kubernetes Cluster Management Scripts

A comprehensive set of scripts for managing Kubernetes clusters on various Linux distributions, including installation, configuration, and cleanup operations.

## Table of Contents
- [Overview](#overview)
- [Supported Distributions](#supported-distributions)
- [Prerequisites](#prerequisites)
- [Installation Guide](#installation-guide)
- [Cleanup Guide](#cleanup-guide)
- [Post-Installation Configuration](#post-installation-configuration)
- [Distribution-Specific Notes](#distribution-specific-notes)
- [Troubleshooting](#troubleshooting)
- [Support](#support)
- [Distribution Test Results](#distribution-test-results)

## Overview

This repository provides two main scripts:
- `setup-k8s.sh`: For installing and configuring Kubernetes nodes
- `cleanup-k8s.sh`: For safely removing Kubernetes components from nodes

Both scripts automatically detect your Linux distribution and use the appropriate package manager and configuration methods.

Blog and additional information: https://www.munenick.me/blog/k8s-setup-script

## Supported Distributions

The scripts support the following Linux distribution families:

- **Debian-based**:
  - Ubuntu
  - Debian

- **Red Hat-based**:
  - RHEL (Red Hat Enterprise Linux)
  - CentOS
  - Fedora
  - Rocky Linux
  - AlmaLinux

- **SUSE-based**:
  - openSUSE
  - SLES (SUSE Linux Enterprise Server)

- **Arch-based**:
  - Arch Linux
  - Manjaro

For unsupported distributions, the scripts will attempt to use generic methods but may require manual intervention.

## Prerequisites

### System Requirements
- One of the supported Linux distributions
- 2 CPUs or more
- 2GB of RAM per machine
- Full network connectivity between cluster machines

### Access Requirements
- Root privileges or sudo access
- Internet connectivity
- Open required ports for Kubernetes communication

## Installation Guide

### Quick Start

Download and run the installation script:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | sudo bash -s -- [options]
```

Manual download and inspection:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/setup-k8s.sh -o setup-k8s.sh
less setup-k8s.sh
chmod +x setup-k8s.sh
sudo ./setup-k8s.sh [options]
```

### Master Node Installation

Basic setup with default containerd:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | sudo bash -s -- --node-type master
```

Setup with CRI-O runtime:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | sudo bash -s -- \
  --node-type master \
  --cri crio
```

Advanced setup:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | sudo bash -s -- \
  --node-type master \
  --kubernetes-version 1.29 \
  --cri containerd \
  --pod-network-cidr 192.168.0.0/16 \
  --apiserver-advertise-address 192.168.1.10 \
  --service-cidr 10.96.0.0/12
```

### Worker Node Installation

Obtain join information from master node:
```bash
# Run on master node
kubeadm token create --print-join-command
```

Join worker node:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | sudo bash -s -- \
  --node-type worker \
  --cri containerd \
  --join-token <token> \
  --join-address <address> \
  --discovery-token-hash <hash>
```

Note: The worker node must use the same CRI as the master node.

### Installation Options Reference

| Option | Description | Example |
|--------|-------------|---------|
| --node-type | Type of node (master/worker) | --node-type master |
| --kubernetes-version | Kubernetes version (1.28, 1.29, 1.30, 1.31, 1.32) | --kubernetes-version 1.28 |
| --pod-network-cidr | Pod network CIDR | --pod-network-cidr 192.168.0.0/16 |
| --apiserver-advertise-address | API server address | --apiserver-advertise-address 192.168.1.10 |
| --control-plane-endpoint | Control plane endpoint | --control-plane-endpoint cluster.example.com |
| --service-cidr | Service CIDR | --service-cidr 10.96.0.0/12 |
| --cri | Container runtime (containerd or crio) | --cri containerd |
| --join-token | Worker join token | --join-token abcdef.1234567890abcdef |
| --join-address | Master address | --join-address 192.168.1.10:6443 |
| --discovery-token-hash | Discovery token hash | --discovery-token-hash sha256:abc... |

## Cleanup Guide

### Quick Start

Execute the cleanup script:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/cleanup-k8s.sh | sudo bash -s -- [options]
```

### Worker Node Cleanup

1. Drain the node (run on master):
```bash
kubectl drain <worker-node-name> --ignore-daemonsets
kubectl delete node <worker-node-name>
```

2. Run cleanup on worker:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/cleanup-k8s.sh | sudo bash -s -- --node-type worker
```

### Master Node Cleanup

**Warning**: This will destroy your entire cluster.

1. Ensure all worker nodes are removed first
2. Run cleanup:
```bash
curl -fsSL https://raw.github.com/MuNeNICK/setup-k8s/main/cleanup-k8s.sh | sudo bash -s -- --node-type master
```

### Cleanup Options Reference

| Option | Description | Example |
|--------|-------------|---------|
| --node-type | Type of node (master/worker) | --node-type master |
| --force | Skip confirmation prompts | --force |
| --preserve-cni | Keep CNI configurations | --preserve-cni |
| --help | Show help message | --help |

## Post-Installation Configuration

### CNI Setup
Install a Container Network Interface (CNI) plugin:
```bash
# Example: Installing Calico
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

### Single-Node Cluster Configuration
Remove control-plane taint for single-node clusters:
```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

### Verification Steps
Check cluster status:
```bash
kubectl get nodes
kubectl get pods --all-namespaces
```

## Distribution-Specific Notes

### Debian/Ubuntu
- The scripts use apt/apt-get for package management
- Packages are held using apt-mark to prevent automatic updates
- Both containerd and CRI-O are fully supported

### RHEL/CentOS/Fedora
- The scripts automatically detect and use dnf or yum as appropriate
- For RHEL, you may need to enable additional repositories
- Package version locking is handled via versionlock
- CRI-O support requires appropriate repository configuration

### SUSE
- The scripts use zypper for package management
- For SLES, you may need a subscription for some repositories
- Container runtime support varies by SUSE version

### Arch Linux
- The scripts use pacman for package management
- Kubernetes packages may need to be installed from the AUR on some systems
- For AUR packages, you may need to manually install an AUR helper like yay or paru
- CRI-O installation may require AUR helper

## Troubleshooting

### Installation Issues
- Check kubelet logs:
```bash
journalctl -xeu kubelet
```
- Verify system requirements
- Confirm network connectivity
- Check distribution-specific logs for package management issues

### Worker Node Join Issues
- Verify network connectivity
- Check token expiration (24-hour default)
- Confirm firewall settings

### Cleanup Issues
- Ensure proper node drainage
- Verify permissions
- Check system logs:
```bash
journalctl -xe
```

### Distribution Detection Issues
If the script fails to detect your distribution correctly:
- Check if `/etc/os-release` exists and contains valid information
- You may need to manually specify some steps for unsupported distributions

## Support
- Issues and feature requests: Open an issue in the repository
- Additional assistance: Contact the maintainer
- Documentation updates: Submit a pull request

## Distribution Test Results

| Distribution | Version | Test Date | Status | Notes |
|-------------|---------|-----------|---------|-------|
| Ubuntu | 24.04 LTS | 2025-08-25 | ✅ Tested | |
| Ubuntu | 22.04 LTS | 2025-08-25 | ✅ Tested | |
| Ubuntu | 20.04 LTS | 2025-08-25 | ✅ Tested | |
| Debian | 12 (Bookworm) | 2025-08-25 | ✅ Tested | |
| Debian | 11 (Bullseye) | 2025-08-25 | ✅ Tested | |
| RHEL | 9 | 2025-08-25 | 🚫 Untested | Subscription required |
| RHEL | 8 | 2025-08-25 | 🚫 Untested | Subscription required |
| CentOS | 7 | 2025-08-25 | 🚫 Untested | EOL |
| CentOS Stream | 9 | 2025-08-25 | ✅ Tested | |
| CentOS Stream | 8 | 2025-08-25 | 🚫 Untested | EOL |
| Rocky Linux | 9 | 2025-08-25 | ✅ Tested | |
| Rocky Linux | 8 | 2025-08-25 | ⚠️ Partial | Kernel 4.18 - K8s 1.28 only¹ |
| AlmaLinux | 9 | 2025-08-25 | ✅ Tested | |
| AlmaLinux | 8 | 2025-08-25 | ⚠️ Partial | Kernel 4.18 - K8s 1.28 only¹ |
| Fedora | 41 | 2025-08-25 | ✅ Tested | |
| Fedora | 39 | 2025-08-25 | 🚫 Untested | EOL |
| openSUSE | Leap 15.5 | 2025-08-25 | ✅ Tested | |
| SLES | 15 SP5 | 2025-08-25 | 🚫 Untested | Subscription required |
| Arch Linux | Rolling | 2025-08-25 | ✅ Tested | |
| Manjaro | Rolling | 2025-08-25 | 🚫 Untested | No cloud image |

Status Legend:
- ✅ Tested: Fully tested and working
- ⚠️ Partial: Works with some limitations or manual steps
- ❌ Failed: Not working or major issues
- 🚫 Untested: Not yet tested

Notes:
¹ Rocky Linux 8 and AlmaLinux 8 have kernel 4.18 which is not supported by Kubernetes 1.29+. Use `--kubernetes-version 1.28` or upgrade kernel.

Note: Test dates and results should be updated regularly. Please submit your test results via issues or pull requests.
