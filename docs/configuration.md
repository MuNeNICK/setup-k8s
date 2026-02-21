# Post-Installation Configuration

## Proxy Mode

The script supports three kube-proxy modes:

### iptables (default)
- Default mode that uses iptables for service proxy
- Works on all Kubernetes versions
- Lower CPU usage for small to medium clusters
- Most compatible with existing network plugins

### IPVS
- High-performance mode using IP Virtual Server
- Better for large clusters (1000+ services)
- Provides multiple load balancing algorithms
- Works on all Kubernetes versions
- Requires kernel modules: ip_vs, ip_vs_rr, ip_vs_wrr, ip_vs_sh
- Requires packages: ipvsadm, ipset

### nftables (K8s 1.29+)
- Next-generation packet filtering framework
- **Best performance** for large clusters (5000+ services)
- Significantly faster rule updates than iptables
- More efficient packet processing in kernel
- Alpha in K8s 1.29-1.30, Beta in K8s 1.31+
- Requires kernel >= 3.13 (>= 4.14 recommended)
- Requires packages: nftables
- **Note**: NodePort services only accessible on default IPs (security improvement)

#### Performance Comparison
In clusters with 5000-10000 services:
- nftables p50 latency matches iptables p01 latency
- nftables processes rule changes 10x faster than iptables

#### Usage Examples

IPVS mode:
```bash
./setup-k8s.sh init --proxy-mode ipvs
```

nftables mode (requires K8s 1.29+):
```bash
./setup-k8s.sh init --proxy-mode nftables --kubernetes-version 1.31
```

**Note**: If prerequisites are not met, the script will exit with an error. Ensure all required packages and kernel modules are available before selecting IPVS or nftables mode.

## Swap Support (K8s 1.28+)

By default, `setup-k8s` disables swap entirely (`swapoff -a`, comments out fstab entries, disables zram). This is required for Kubernetes versions before 1.28.

Starting with Kubernetes 1.28, the `NodeSwap` feature gate is stable and allows nodes to run with swap enabled. Use the `--swap-enabled` flag to keep swap active and configure kubelet accordingly.

When `--swap-enabled` is used, the script:
1. **Skips swap disable** — swap remains active as configured by the OS
2. **Configures kubelet** — sets `failSwapOn: false` and `memorySwap.swapBehavior: LimitedSwap` via KubeletConfiguration

### LimitedSwap Behavior

With `LimitedSwap`, Kubernetes limits swap usage to pods that have memory limits set. Pods without memory limits will not use swap. This prevents unbounded swap usage while allowing workloads that benefit from swap to use it in a controlled manner.

### Usage

```bash
# Initialize a cluster with swap enabled
sudo ./setup-k8s.sh init --swap-enabled --kubernetes-version 1.32

# Deploy across nodes with swap enabled
./setup-k8s.sh deploy --control-planes 10.0.0.1 --workers 10.0.0.2 --swap-enabled
```

### Requirements

- Kubernetes 1.28 or higher (the script will error if used with older versions)
- Swap must be configured at the OS level (the script does not enable swap, it simply preserves existing swap configuration)

## HA Cluster with kube-vip

The script supports deploying a highly available control plane using [kube-vip](https://kube-vip.io/) for Virtual IP (VIP) management. kube-vip runs as a static pod on each control-plane node and provides a floating VIP using ARP-based leader election.

### How It Works

1. During `init`, the script deploys a kube-vip static pod manifest to `/etc/kubernetes/manifests/kube-vip.yaml` **before** running `kubeadm init`.
2. The `--control-plane-endpoint` is automatically set to `<VIP>:6443` (unless manually overridden).
3. After init, the script uploads certificates and displays the join command for additional control-plane nodes.
4. Additional control-plane nodes join using `setup-k8s.sh join --control-plane --certificate-key <key> ...`.

### Flags

| Flag | Description | Required |
|------|-------------|----------|
| `--ha` | Enable HA mode (init only) | Yes |
| `--ha-vip ADDRESS` | The Virtual IP address | Yes (when --ha) |
| `--ha-interface IFACE` | Network interface to bind the VIP | No (auto-detected) |

### Example: Initialize an HA Cluster

```bash
# On the first control-plane node
sudo ./setup-k8s.sh init \
  --ha \
  --ha-vip 192.168.1.100 \
  --pod-network-cidr 192.168.0.0/16
```

The script will output the certificate key and join command for additional control-plane nodes.

### Example: Join Additional Control-Plane Nodes

```bash
# On each additional control-plane node
sudo ./setup-k8s.sh join \
  --control-plane \
  --certificate-key <certificate-key> \
  --ha-vip 192.168.1.100 \
  --join-token <token> \
  --join-address 192.168.1.100:6443 \
  --discovery-token-hash <hash>
```

**Note:** `--ha-vip` deploys a kube-vip static pod on each control-plane node, enabling VIP failover if the initial node goes down.

### Example: Join Worker Nodes

```bash
# On each worker node
sudo ./setup-k8s.sh join \
  --join-token <token> \
  --join-address 192.168.1.100:6443 \
  --discovery-token-hash <hash>
```

### Requirements

- The VIP address must be an unused IP on the same subnet as the control-plane nodes.
- The network interface is auto-detected from the default route if `--ha-interface` is omitted.
- Both containerd and CRI-O are supported as container runtimes.

## Cluster Upgrade

The `upgrade` subcommand automates Kubernetes version upgrades following the official kubeadm upgrade procedure. It supports both local execution (on each node individually) and remote orchestration (from a local machine via SSH).

### Upgrade Constraints

- Version must be in `MAJOR.MINOR.PATCH` format (e.g., `1.33.2`)
- Only +1 minor version upgrades are allowed (Kubernetes skew policy)
- Downgrades are not supported
- Patch version upgrades within the same minor version are allowed

### Local Mode

Run directly on each node with `sudo`. Useful for manual, node-by-node upgrades.

```bash
# First control-plane node (runs kubeadm upgrade apply)
sudo ./setup-k8s.sh upgrade --kubernetes-version 1.33.2 --first-control-plane

# Additional control-plane nodes and workers (runs kubeadm upgrade node)
sudo ./setup-k8s.sh upgrade --kubernetes-version 1.33.2
```

For single-node clusters, use `--skip-drain` to avoid draining the only node:

```bash
sudo ./setup-k8s.sh upgrade --kubernetes-version 1.33.2 --first-control-plane --skip-drain
```

### Remote Mode

Orchestrate the entire cluster upgrade from a local machine via SSH. The script handles drain, upgrade, and uncordon for each node sequentially.

```bash
./setup-k8s.sh upgrade \
  --control-planes 10.0.0.1,10.0.0.2 \
  --workers 10.0.0.3,10.0.0.4 \
  --kubernetes-version 1.33.2 \
  --ssh-key ~/.ssh/id_rsa
```

The orchestration flow:
1. Generate and transfer a self-contained bundle to all nodes
2. Check current cluster version and validate upgrade constraints
3. Run `kubeadm upgrade plan` (informational)
4. For each control-plane node: drain, upgrade, uncordon (first CP uses `kubeadm upgrade apply`, others use `kubeadm upgrade node`)
5. For each worker node: drain, upgrade, uncordon
6. Verify cluster state with `kubectl get nodes`

### Error Handling

- **Drain timeout**: The upgrade stops at the failing node. The node remains cordoned.
- **Upgrade failure**: The process stops. Some nodes may be in mixed-version state (allowed by Kubernetes skew policy).
- **kubelet restart failure**: A warning is logged but the process continues (kubelet may take time to stabilize).
- No automatic rollback is performed. Manual intervention may be required for partially upgraded clusters.

### Requirements

- SSH access to all nodes (same requirements as the `deploy` subcommand)
- `kubeadm`, `kubelet`, and `kubectl` must already be installed on all nodes
- The target version packages must be available in the distribution's package repository

## Remote Deployment via SSH

For deploying to multiple nodes without manually running `init`/`join` on each, use the `deploy` subcommand. See [Reference - Deploy Options](reference.md#deploy-options) for full usage.

Key points:
- Runs from a local machine (no root required locally)
- Generates a self-contained bundle and transfers it to all nodes
- Supports both key-based and password-based SSH authentication
- Workers join in parallel for faster deployment
- Compatible with all init/join options (`--cri`, `--proxy-mode`, `--kubernetes-version`, etc.)

## CNI Setup
Install a Container Network Interface (CNI) plugin:
```bash
# Example: Installing Calico
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

## Single-Node Cluster Configuration
Remove control-plane taint for single-node clusters:
```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## Verification Steps
Check cluster status:
```bash
kubectl get nodes
kubectl get pods --all-namespaces
```
