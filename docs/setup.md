# Installation Guide

## Quick Start

Download and run the installation script:
```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | sudo bash -s -- [options]
```

Manual download and inspection:
```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/setup-k8s.sh -o setup-k8s.sh
less setup-k8s.sh
chmod +x setup-k8s.sh
sudo ./setup-k8s.sh [options]
```

## Web Installer (--gui)

Prefer configuring from a browser? Launch the lightweight web UI:

```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | \
  sudo bash -s -- --gui
```

This starts a local HTTP server (default: `http://127.0.0.1:8080`) that mirrors the CLI
options. Once you submit the form, the script continues in the terminal with the selected
configuration and the browser tab automatically pivots to a `/progress` page that streams
the same log output. That means you can watch the installation either from the terminal or
right from your browser without switching contexts.

Pass the bind address (optionally with a port) right after `--gui`, e.g. `--gui 0.0.0.0` or
`--gui 0.0.0.0:9000`. You can also feed values via the `GUI_BIND_ADDRESS` / `GUI_PORT`
environment variables. Ensure `python3` is installed for the web UI to run.

Example exposing the installer on all interfaces and a different port:

```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | \
  sudo bash -s -- --gui 0.0.0.0:9000
```

## Master Node Installation

Basic setup with default containerd:
```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | sudo bash -s -- --node-type master
```

Setup with CRI-O runtime:
```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | sudo bash -s -- \
  --node-type master \
  --cri crio
```

Advanced setup:
```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | sudo bash -s -- \
  --node-type master \
  --kubernetes-version 1.29 \
  --cri containerd \
  --pod-network-cidr 192.168.0.0/16 \
  --apiserver-advertise-address 192.168.1.10 \
  --service-cidr 10.96.0.0/12
```

Setup with IPVS mode for better performance:
```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | sudo bash -s -- \
  --node-type master \
  --proxy-mode ipvs \
  --pod-network-cidr 192.168.0.0/16
```

Setup with nftables mode (requires K8s 1.29+):
```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | sudo bash -s -- \
  --node-type master \
  --proxy-mode nftables \
  --kubernetes-version 1.31 \
  --pod-network-cidr 192.168.0.0/16
```

## Worker Node Installation

Obtain join information from master node:
```bash
# Run on master node
kubeadm token create --print-join-command
```

Join worker node:
```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/setup-k8s.sh | sudo bash -s -- \
  --node-type worker \
  --cri containerd \
  --join-token <token> \
  --join-address <address> \
  --discovery-token-hash <hash>
```

Note: The worker node must use the same CRI as the master node.

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
