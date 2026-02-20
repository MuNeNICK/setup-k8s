# Option Reference

## setup-k8s.sh

```
Usage: setup-k8s.sh <init|join|deploy> [options]
```

### Subcommands

| Subcommand | Description |
|------------|-------------|
| `init` | Initialize a new Kubernetes cluster |
| `join` | Join an existing cluster as a worker or control-plane node |
| `deploy` | Deploy a cluster across remote nodes via SSH |

### Options

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--cri RUNTIME` | Container runtime (containerd or crio) | `containerd` | `--cri crio` |
| `--proxy-mode MODE` | Kube-proxy mode (iptables, ipvs, or nftables) | `iptables` | `--proxy-mode nftables` |
| `--pod-network-cidr CIDR` | Pod network CIDR | — | `--pod-network-cidr 192.168.0.0/16` |
| `--apiserver-advertise-address ADDR` | API server advertise address | — | `--apiserver-advertise-address 192.168.1.10` |
| `--control-plane-endpoint ENDPOINT` | Control plane endpoint | — | `--control-plane-endpoint cluster.example.com` |
| `--service-cidr CIDR` | Service CIDR | — | `--service-cidr 10.96.0.0/12` |
| `--kubernetes-version VER` | Kubernetes version | — | `--kubernetes-version 1.29` |
| `--join-token TOKEN` | Join token (join only) | — | `--join-token abcdef.1234567890abcdef` |
| `--join-address ADDR` | Control plane address (join only) | — | `--join-address 192.168.1.10:6443` |
| `--discovery-token-hash HASH` | Discovery token hash (join only) | — | `--discovery-token-hash sha256:abc...` |
| `--control-plane` | Join as control-plane node (join only, HA cluster) | — | `--control-plane` |
| `--certificate-key KEY` | Certificate key for control-plane join | — | `--certificate-key abc123` |
| `--ha` | Enable HA mode with kube-vip (init only) | — | `--ha` |
| `--ha-vip ADDRESS` | VIP address (required when --ha is set) | — | `--ha-vip 192.168.1.100` |
| `--ha-interface IFACE` | Network interface for VIP | auto-detect | `--ha-interface eth0` |
| `--enable-completion BOOL` | Enable shell completion setup | `true` | `--enable-completion false` |
| `--completion-shells LIST` | Shells to configure (auto, bash, zsh, fish, or comma-separated) | `auto` | `--completion-shells bash,zsh` |
| `--install-helm BOOL` | Install Helm package manager | `false` | `--install-helm true` |
| `--offline` | Run in offline mode (use bundled modules) | — | `--offline` |
| `--dry-run` | Show configuration summary and exit without making changes | — | `--dry-run` |
| `--verbose` | Enable debug logging | — | `--verbose` |
| `--quiet` | Suppress informational messages (errors only) | — | `--quiet` |
| `--help`, `-h` | Display help message | — | `--help` |

### Deploy Options

Options specific to the `deploy` subcommand. Init/join options like `--cri`, `--proxy-mode`, `--kubernetes-version`, `--pod-network-cidr`, `--service-cidr`, and `--control-plane-endpoint` are passed through to remote nodes.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--control-planes IPs` | Comma-separated control-plane nodes (user@ip or ip) | — (required) | `--control-planes 10.0.0.1,10.0.0.2` |
| `--workers IPs` | Comma-separated worker nodes (user@ip or ip) | — | `--workers 10.0.0.3,10.0.0.4` |
| `--ssh-user USER` | Default SSH user | `root` | `--ssh-user ubuntu` |
| `--ssh-port PORT` | SSH port | `22` | `--ssh-port 2222` |
| `--ssh-key PATH` | Path to SSH private key | — | `--ssh-key ~/.ssh/id_rsa` |
| `--ssh-password PASS` | SSH password (requires sshpass; prefer `DEPLOY_SSH_PASSWORD` env var) | — | `DEPLOY_SSH_PASSWORD=secret bash setup-k8s.sh deploy ...` |
| `--ssh-known-hosts FILE` | Pre-seeded known_hosts file for SSH host key verification (implies `--ssh-host-key-check yes`) | — | `--ssh-known-hosts ~/.ssh/known_hosts` |
| `--ssh-host-key-check MODE` | SSH host key verification policy (`yes`, `no`, or `accept-new`) | `yes` | `--ssh-host-key-check no` |
| `--ha-vip ADDRESS` | VIP for HA (required when >1 control-plane) | — | `--ha-vip 10.0.0.100` |
| `--ha-interface IFACE` | Network interface for VIP | auto-detect | `--ha-interface eth0` |
| `--dry-run` | Show deployment plan and exit | — | `--dry-run` |

## cleanup-k8s.sh

```
Usage: cleanup-k8s.sh [options]
```

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--force` | Skip confirmation prompt | — | `--force` |
| `--preserve-cni` | Preserve CNI configurations | — | `--preserve-cni` |
| `--remove-helm` | Remove Helm binary and configuration | — | `--remove-helm` |
| `--verbose` | Enable debug logging | — | `--verbose` |
| `--quiet` | Suppress informational messages (errors only) | — | `--quiet` |
| `--offline` | Run in offline mode (use bundled modules) | — | `--offline` |
| `--help`, `-h` | Display help message | — | `--help` |
