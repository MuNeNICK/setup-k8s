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
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init --proxy-mode ipvs
```

nftables mode (requires K8s 1.29+):
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init --proxy-mode nftables --kubernetes-version 1.31
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
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init --swap-enabled --kubernetes-version 1.32

# Deploy across nodes with swap enabled
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  deploy --control-planes 10.0.0.1 --workers 10.0.0.2 --swap-enabled
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
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --ha \
  --ha-vip 192.168.1.100 \
  --pod-network-cidr 192.168.0.0/16
```

The script will output the certificate key and join command for additional control-plane nodes.

### Example: Join Additional Control-Plane Nodes

```bash
# On each additional control-plane node
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  join \
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
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  join \
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
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  upgrade --kubernetes-version 1.33.2 --first-control-plane

# Additional control-plane nodes and workers (runs kubeadm upgrade node)
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  upgrade --kubernetes-version 1.33.2
```

For single-node clusters, use `--skip-drain` to avoid draining the only node:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  upgrade --kubernetes-version 1.33.2 --first-control-plane --skip-drain
```

### Remote Mode

Orchestrate the entire cluster upgrade from a local machine via SSH. The script handles drain, upgrade, and uncordon for each node sequentially.

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  upgrade \
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

### Automatic Rollback

When a remote upgrade fails, setup-k8s automatically rolls back the failing node:

1. Records pre-upgrade package versions (kubeadm, kubelet, kubectl)
2. On failure, downgrades packages to the recorded versions
3. Restarts kubelet and uncordons the node
4. Logs the rollback outcome

Use `--no-rollback` to disable automatic rollback (useful for debugging).

### Multi-Version Upgrade

Kubernetes only supports +1 minor version upgrades. To upgrade across multiple minor versions (e.g., 1.31 → 1.33), use `--auto-step-upgrade`:

```bash
setup-k8s.sh upgrade \
  --control-planes 10.0.0.1,10.0.0.2 \
  --kubernetes-version 1.33.2 \
  --auto-step-upgrade \
  --ssh-key ~/.ssh/id_rsa
```

The script automatically computes intermediate steps (1.31 → 1.32.latest → 1.33.2), running a full cluster upgrade and health check at each step.

### Error Handling

- **Drain timeout**: The upgrade stops at the failing node. The node remains cordoned.
- **Upgrade failure**: Automatic rollback restores the failing node to pre-upgrade state (disable with `--no-rollback`).
- **kubelet restart failure**: A warning is logged but the process continues (kubelet may take time to stabilize).

### Requirements

- SSH access to all nodes (same requirements as the `deploy` subcommand)
- `kubeadm`, `kubelet`, and `kubectl` must already be installed on all nodes
- The target version packages must be available in the distribution's package repository

## etcd Backup / Restore

The `backup` and `restore` subcommands manage etcd snapshots for kubeadm clusters. Both support local execution (directly on a control-plane node) and remote orchestration (from a local machine via SSH), following the same pattern as the `upgrade` subcommand.

### How It Works

**Backup** creates an etcd snapshot using `etcdctl snapshot save` inside the running etcd container via `crictl exec`. The snapshot is saved through etcd's hostPath mount (`/var/lib/etcd`) and copied to the specified output path.

**Restore** extracts `etcdctl` and `etcdutl` binaries from the etcd container image (OCI layer extraction, compatible with distroless images), then:

1. Moves the etcd static pod manifest to stop the etcd container
2. Backs up the existing `/var/lib/etcd` directory
3. Runs `etcdutl snapshot restore` (etcd 3.6+) or `etcdctl snapshot restore` (etcd 3.5)
4. Restores the manifest to restart etcd
5. Waits for etcd health check to pass

A cleanup handler automatically restores the etcd manifest if the process fails mid-way.

### Local Mode

Run directly on a control-plane node with `sudo`.

```bash
# Backup
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  backup --snapshot-path /path/to/snapshot.db

# Backup with auto-generated path (default: /var/lib/etcd-backup/snapshot-YYYYMMDD-HHMMSS.db)
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- backup

# Restore
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  restore --snapshot-path /path/to/snapshot.db
```

### Remote Mode

Orchestrate backup/restore from a local machine via SSH. The script generates a self-contained bundle, transfers it to the target node, and executes the operation remotely.

```bash
# Backup (downloads snapshot to local machine)
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  backup \
  --control-planes root@192.168.1.10 \
  --ssh-key ~/.ssh/id_rsa \
  --snapshot-path ./etcd-snapshot.db

# Restore (uploads snapshot and restores on remote node)
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  restore \
  --control-planes root@192.168.1.10 \
  --ssh-key ~/.ssh/id_rsa \
  --snapshot-path ./etcd-snapshot.db
```

Remote backup flow:
1. Check SSH connectivity and sudo access
2. Generate and transfer a self-contained bundle to the control-plane node
3. Execute backup on the remote node (local mode inside the bundle)
4. Download the snapshot file via SCP

Remote restore flow:
1. Check SSH connectivity and sudo access
2. Upload the snapshot file via SCP
3. Generate and transfer a self-contained bundle
4. Execute restore on the remote node (local mode inside the bundle)

### etcd Version Compatibility

| etcd Version | Backup | Restore Tool |
|---|---|---|
| 3.5.x | `etcdctl snapshot save` | `etcdctl snapshot restore` |
| 3.6.x+ | `etcdctl snapshot save` | `etcdutl snapshot restore` |

The script automatically detects the available tools and uses `etcdutl` when available, falling back to `etcdctl` for older versions. Both `etcdctl` and `etcdutl` are extracted from the etcd container image via OCI layer extraction, which works with distroless images (no shell required inside the container).

### Requirements

- The target node must be a kubeadm control-plane node with etcd running as a static pod
- SSH access with passwordless sudo (for remote mode)
- Sufficient disk space for the snapshot file and the etcd data backup

## Certificate Renewal

The `renew` subcommand manages kubeadm-managed certificate renewal and expiration checks. Kubeadm certificates expire after 1 year by default; expired certificates will prevent the cluster from functioning. Both local execution (on a control-plane node) and remote orchestration (from a local machine via SSH) are supported, following the same pattern as the `upgrade` subcommand.

### How It Works

**Check-only mode** runs `kubeadm certs check-expiration` to display current certificate expiration dates without making any changes.

**Renewal mode** renews certificates via `kubeadm certs renew`, then restarts control-plane static pod components (kube-apiserver, kube-controller-manager, kube-scheduler, and etcd if etcd certificates were renewed) using `crictl stop`. Kubelet automatically restarts the stopped containers. The script waits for the API server to become ready (up to 120 seconds).

### Local Mode

Run directly on a control-plane node with `sudo`.

```bash
# Check certificate expiration (no changes)
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  renew --check-only

# Renew all certificates
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- renew

# Renew specific certificates only
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  renew --certs apiserver,front-proxy-client
```

### Remote Mode

Orchestrate certificate renewal across multiple control-plane nodes from a local machine via SSH. Nodes are processed sequentially to avoid all API servers restarting simultaneously.

```bash
# Check expiration on all control-plane nodes
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  renew \
  --control-planes root@192.168.1.10,root@192.168.1.11 \
  --ssh-key ~/.ssh/id_rsa \
  --check-only

# Renew certificates on all control-plane nodes
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  renew \
  --control-planes root@192.168.1.10,root@192.168.1.11 \
  --ssh-key ~/.ssh/id_rsa
```

Remote orchestration flow:
1. Check SSH connectivity and sudo access to all nodes
2. Generate and transfer a self-contained bundle
3. Execute renewal on each node sequentially
4. Display summary

### Valid Certificate Names

| Name | Description |
|------|-------------|
| `apiserver` | API server serving certificate |
| `apiserver-kubelet-client` | API server → kubelet client certificate |
| `front-proxy-client` | Front proxy client certificate |
| `apiserver-etcd-client` | API server → etcd client certificate |
| `etcd-healthcheck-client` | etcd health check client certificate |
| `etcd-peer` | etcd peer certificate |
| `etcd-server` | etcd serving certificate |
| `admin.conf` | Admin kubeconfig embedded certificate |
| `controller-manager.conf` | Controller manager kubeconfig certificate |
| `scheduler.conf` | Scheduler kubeconfig certificate |
| `super-admin.conf` | Super admin kubeconfig certificate |

### Requirements

- The target node must be a kubeadm control-plane node
- `crictl` must be available for restarting control-plane components after renewal
- SSH access with passwordless sudo (for remote mode)

## Remote Deployment via SSH

For deploying to multiple nodes without manually running `init`/`join` on each, use the `deploy` subcommand. See [Reference - Deploy Options](reference.md#deploy-options) for full usage.

Key points:
- Runs from a local machine (no root required locally)
- Generates a self-contained bundle and transfers it to all nodes
- Supports both key-based and password-based SSH authentication
- Workers join in parallel for faster deployment
- Compatible with all init/join options (`--cri`, `--proxy-mode`, `--kubernetes-version`, etc.)

## IPv6 / Dual-Stack

Kubernetes 1.23+ supports IPv6 single-stack and IPv4/IPv6 dual-stack networking (GA). setup-k8s automatically detects the address family from the values passed to `--pod-network-cidr`, `--service-cidr`, and `--ha-vip`.

### Dual-Stack

Pass comma-separated CIDRs (one IPv4, one IPv6) to enable dual-stack:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --pod-network-cidr 10.244.0.0/16,fd00:10:244::/48 \
  --service-cidr 10.96.0.0/12,fd00:20::/108
```

### IPv6 Single-Stack

Pass IPv6 CIDRs only:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --pod-network-cidr fd00:10:244::/48 \
  --service-cidr fd00:20::/108
```

### HA with IPv6 VIP

IPv6 addresses are supported for `--ha-vip`. The control-plane endpoint is automatically formatted with brackets (`[addr]:6443`):

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --ha --ha-vip fd00::100 \
  --pod-network-cidr fd00:10:244::/48
```

### CNI Plugin Notes

- Ensure your CNI plugin supports dual-stack or IPv6 if using those modes
- Calico, Cilium, and Flannel all support dual-stack
- Some CNI plugins may require additional configuration for IPv6

### Requirements

- Kubernetes 1.23+ (dual-stack GA)
- CNI plugin with IPv6/dual-stack support
- IPv6 connectivity between nodes (for IPv6 or dual-stack modes)

## Generic (Binary Download) Support

When running on an unsupported distribution (or when `--distro generic` is specified), setup-k8s downloads Kubernetes, containerd, runc, CNI plugins, and CRI-O binaries directly from official release URLs instead of using a package manager. OS-level dependencies (socat, conntrack, ipset, kmod) are still installed via the system package manager when available.

### How It Works

- **K8s binaries** (kubeadm, kubelet, kubectl) are downloaded from `dl.k8s.io` with SHA-256 checksum verification
- **containerd** and **runc** are downloaded from GitHub Releases with checksum verification
- **CNI plugins** are downloaded from GitHub Releases with checksum verification
- **CRI-O** is downloaded as a tarball from `storage.googleapis.com` (bundles crio, conmon, runc, crun, crictl, and CNI plugins)
- Binaries are installed to `/usr/local/bin/` (separate from package manager paths)
- CNI plugins are installed to `/opt/cni/bin/`

### Init System Support

The script auto-detects the init system (systemd or OpenRC) and generates the appropriate service files:

- **systemd**: Unit files are placed in `/etc/systemd/system/` with a kubeadm drop-in for kubelet
- **OpenRC**: Init scripts are placed in `/etc/init.d/`

When running on OpenRC, `--ignore-preflight-errors=SystemVerification` is automatically added to kubeadm commands.

### Default Versions

Component versions are pinned by default and can be overridden via environment variables:

| Component | Default | Environment Variable |
|-----------|---------|---------------------|
| containerd | 2.0.4 | `CONTAINERD_VERSION` |
| runc | 1.2.5 | `RUNC_VERSION` |
| CNI plugins | 1.6.2 | `CNI_PLUGINS_VERSION` |
| CRI-O | 1.32.0 | `CRIO_VERSION` |

### Architecture Support

Supported architectures: `amd64` (x86_64), `arm64` (aarch64).

### Usage

```bash
# Force generic mode on any distribution
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init --distro generic --kubernetes-version 1.32

# Override component versions
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | \
  sudo CONTAINERD_VERSION=2.0.4 RUNC_VERSION=1.2.5 sh -s -- init --distro generic
```

### Cleanup

The `setup-k8s.sh cleanup` subcommand removes only the binaries, configs, and service files placed by the script. System packages (socat, conntrack, etc.) installed via the package manager are intentionally preserved.

## Cluster Status

The `status` subcommand shows the current state of the Kubernetes node and cluster. Unlike other subcommands, `status` performs read-only checks only and does not require root privileges (`sudo` is not needed).

### Usage

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- status
```

The `--output wide` flag adds cluster-level information (API server endpoint, CIDR ranges, etcd health):

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- status --output wide
```

### What It Checks

**text mode** (default):

1. **Node role** — control-plane or worker (detected by the presence of `/etc/kubernetes/manifests/kube-apiserver.yaml`)
2. **Service status** — kubelet, containerd, crio (active / inactive)
3. **Installed versions** — kubelet, kubeadm, kubectl
4. **Cluster state** — `kubectl get nodes` and `kubectl get pods -n kube-system`

**wide mode** (additionally):

5. **Cluster info** — API server endpoint, Pod CIDR, Service CIDR
6. **etcd health** — endpoint health check via `etcdctl` inside the etcd container

If kubectl is not configured or the cluster is unreachable, cluster queries are gracefully skipped with a warning. The command still reports service and version information.

### Limitations

- Local mode only (remote SSH mode is not yet supported)
- etcd health in wide mode requires access to the etcd container (typically available only on control-plane nodes running as root)

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

## Logging and Diagnostics

### File Logging

Persist all log output to disk with `--log-dir`:

```bash
setup-k8s.sh deploy --log-dir /var/log/setup-k8s --control-planes 10.0.0.1 --ssh-key ~/.ssh/id_rsa
```

Log files are created with timestamp names (e.g., `setup-k8s-20260224-120000.log`) and mode 0600.

### Audit Logging

Structured audit events are recorded for all operations (deploy, upgrade, remove, backup, restore, renew). Each event includes timestamp, operation, outcome, and user.

Audit events are always written to the log file (when `--log-dir` is set). Add `--audit-syslog` to also send them to syslog via `logger -t setup-k8s`.

### Failure Diagnostics

When `--collect-diagnostics` is enabled, the script automatically collects debug information from failing nodes:

- kubelet logs (last 100 lines)
- containerd logs (last 50 lines)
- Recent cluster events
- Disk and memory status

Diagnostics are saved to `/tmp/setup-k8s-diag-*` on the orchestrator machine.

## Cluster Health Checks

Post-operation health checks run automatically after deploy, upgrade, and remove operations:

- **API server responsiveness** — `kubectl get --raw /readyz`
- **Node readiness** — all nodes in `Ready` state
- **etcd health** — etcd cluster health and quorum
- **Core pods** — kube-system pods running

Pre-operation health checks run before upgrade and remove to verify the cluster is healthy before making changes.

## Operation Resume

Long-running operations (deploy, upgrade) can be resumed after interruption with `--resume`:

```bash
# If deploy was interrupted, resume from the last completed step
setup-k8s.sh deploy --resume --control-planes 10.0.0.1,10.0.0.2 --ssh-key ~/.ssh/id_rsa
```

State is persisted to `/var/lib/setup-k8s/state/`. Completed steps (e.g., kubeadm init, individual node joins) are skipped on resume. Bundle generation and transfer are always re-executed since remote temp directories are cleaned on exit.

## kubeadm Configuration

### Custom kubeadm Config Patch

Append additional kubeadm configuration via `--kubeadm-config-patch`:

```bash
setup-k8s.sh deploy --control-planes 10.0.0.1 \
  --kubeadm-config-patch custom-config.yaml \
  --ssh-key ~/.ssh/id_rsa
```

The patch file is appended as an additional YAML document (`---` separator) to the generated kubeadm config. This allows customizing any kubeadm API object (ClusterConfiguration, KubeletConfiguration, etc.).

### Extra API Server SANs

Add additional Subject Alternative Names to the API server certificate:

```bash
setup-k8s.sh deploy --control-planes 10.0.0.1 \
  --api-server-extra-sans lb.example.com,10.0.0.200 \
  --ssh-key ~/.ssh/id_rsa
```

### Kubelet Node IP

Set a specific node IP for kubelet advertisement:

```bash
setup-k8s.sh deploy --control-planes 10.0.0.1 \
  --kubelet-node-ip 10.0.0.1 \
  --ssh-key ~/.ssh/id_rsa
```

## SSH Security

### Password File

Avoid exposing passwords in the process list by using `--ssh-password-file` instead of `--ssh-password`:

```bash
setup-k8s.sh deploy --control-planes 10.0.0.1 \
  --ssh-password-file /run/secrets/ssh-pass
```

The file must have mode 0600 or stricter.

### Known Hosts Persistence

Save discovered SSH host keys for reuse across sessions. Since the default host key policy is `accept-new` (TOFU), keys are automatically accepted on first connect:

```bash
# First run: host keys are accepted automatically (accept-new is the default)
setup-k8s.sh deploy --control-planes 10.0.0.1 \
  --persist-known-hosts ./known_hosts

# Subsequent runs: reuse saved host keys with strict checking
setup-k8s.sh upgrade --control-planes 10.0.0.1 \
  --ssh-known-hosts ./known_hosts
```
