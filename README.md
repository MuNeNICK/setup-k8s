# Kubernetes Cluster Management Scripts

[![ShellCheck & Unit Tests](https://github.com/MuNeNICK/setup-k8s/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/MuNeNICK/setup-k8s/actions/workflows/shellcheck.yml)

Set up or tear down a Kubernetes cluster with a single command.
Follows the official [kubeadm installation guide](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/).
Distro auto-detection means the same command works on Ubuntu, Rocky Linux, Arch, and more.
Proxy mode, CRI, version pinning, and many other options are fully configurable.

## Quick Start

### Initialize Cluster
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo bash -s -- init
```

### Join Cluster
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo bash -s -- \
  join \
  --join-token <token> \
  --join-address <address> \
  --discovery-token-hash <hash>
```

### Cleanup
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/cleanup-k8s.sh | sudo bash -s -- --force
```

## Documentation

| Document | Description |
|----------|-------------|
| [Installation Guide](docs/setup.md) | Web installer, master/worker setup examples, prerequisites |
| [Cleanup Guide](docs/cleanup.md) | Worker/master cleanup procedures, node drain steps |
| [Configuration](docs/configuration.md) | Proxy modes (iptables/IPVS/nftables), CNI setup, single-node config |
| [Option Reference](docs/reference.md) | All setup-k8s.sh and cleanup-k8s.sh options |
| [Troubleshooting](docs/troubleshooting.md) | Common issues, distribution-specific notes |

## Support
- Issues and feature requests: Open an issue in the repository
- Documentation updates: Submit a pull request

## Distribution Test Results

Tested with Kubernetes v1.35 (latest stable).

| Distribution | Version | Test Date | Status | Notes |
|-------------|---------|-----------|---------|-------|
| Ubuntu | 24.04 LTS | 2026-02-18 | ✅ Tested | |
| Ubuntu | 22.04 LTS | 2026-02-18 | ✅ Tested | |
| Ubuntu | 20.04 LTS | 2026-02-18 | ⚠️ Partial | cgroups v1 only ¹ |
| Debian | 12 (Bookworm) | 2026-02-18 | ✅ Tested | |
| Debian | 11 (Bullseye) | 2026-02-18 | ✅ Tested | |
| RHEL | 9 | - | 🚫 Untested | Subscription required |
| RHEL | 8 | - | 🚫 Untested | Subscription required |
| CentOS | 7 | - | 🚫 Untested | EOL |
| CentOS Stream | 9 | 2026-02-18 | ✅ Tested | |
| CentOS Stream | 8 | - | 🚫 Untested | EOL |
| Rocky Linux | 9 | 2026-02-18 | ✅ Tested | |
| Rocky Linux | 8 | 2026-02-18 | ⚠️ Partial | cgroups v1 only ¹ |
| AlmaLinux | 9 | 2026-02-18 | ✅ Tested | |
| AlmaLinux | 8 | 2026-02-18 | ⚠️ Partial | cgroups v1 only ¹ |
| Fedora | 41 | 2026-02-18 | ✅ Tested | |
| Fedora | 39 | - | 🚫 Untested | EOL |
| openSUSE | Leap 15.5 | 2026-02-18 | ⚠️ Partial | cgroups v1 only ¹ |
| SLES | 15 SP5 | - | 🚫 Untested | Subscription required |
| Arch Linux | Rolling | 2026-02-18 | ✅ Tested | |
| Manjaro | Rolling | - | 🚫 Untested | No cloud image |

Status Legend:
- ✅ Tested: Fully tested and working
- ⚠️ Partial: Works with some limitations or manual steps
- ❌ Failed: Not working or major issues
- 🚫 Untested: Not yet tested

Notes:
¹ Kubernetes 1.35 disabled cgroups v1 support by default. Use `--kubernetes-version 1.34` or earlier on these distributions.

Note: Test dates and results should be updated regularly. Please submit your test results via issues or pull requests.
