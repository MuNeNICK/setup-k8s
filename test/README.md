# K8s Multi-Distribution Test Suite

Docker + QEMU test framework that validates `setup-k8s.sh` across multiple Linux distributions. VM lifecycle management relies on the published [`ghcr.io/munenick/docker-vm-runner`](https://github.com/MuNeNICK/docker-vm-runner) image, so contributors can run identical environments without custom tooling.

## Features

- **Simple**: Complete test execution with a single command
- **No host pollution**: No need to install QEMU/cloud-utils on host
- **Fully automated**: Unattended execution from VM boot to K8s setup and result collection
- **19 distributions/versions supported**: Ubuntu, Debian, CentOS, Fedora, openSUSE, Rocky, AlmaLinux, Oracle Linux, Arch Linux, Alpine Linux
- **Reliable result verification**: Confirms setup-k8s.sh execution, kubelet startup, and API response

## Test Scripts

| Script | Description |
|--------|------------|
| `run-e2e-tests.sh` | Single-node E2E test: init + cleanup across all supported distros |
| `run-ha-test.sh` | HA (kube-vip) test: init with `--ha --ha-vip` on a single VM |
| `run-deploy-test.sh` | Deploy subcommand test: multi-node cluster (1 CP + 1 Worker) via SSH |
| `run-backup-test.sh` | Backup/restore subcommand test: deploy + backup + restore on single CP |
| `run-renew-test.sh` | Certificate renewal test: deploy + check-only + renew all + renew specific on single CP |
| `run-unit-tests.sh` | Unit tests for shell modules |

## Supported Distributions

| Distribution | Version | Login User |
|-------------|---------|------------|
| ubuntu-2404 | 24.04 LTS | user |
| ubuntu-2204 | 22.04 LTS | user |
| debian-13 | 13 (Trixie) | user |
| debian-12 | 12 (Bookworm) | user |
| debian-11 | 11 (Bullseye) | user |
| centos-stream-10 | Stream 10 | user |
| centos-stream-9 | Stream 9 | user |
| fedora-43 | 43 | user |
| opensuse-tumbleweed | Tumbleweed | user |
| opensuse-leap-160 | Leap 16.0 | user |
| rocky-linux-10 | 10 | user |
| rocky-linux-9 | 9 | user |
| rocky-linux-8 | 8 | user |
| almalinux-10 | 10 | user |
| almalinux-9 | 9 | user |
| almalinux-8 | 8 | user |
| oracle-linux-9 | 9 | user |
| alpine-3 | 3.23 | user |
| archlinux | Rolling | user |

## System Requirements

- Linux host (Ubuntu 20.04+ recommended)
- Docker Engine 20.10+
- `/dev/kvm` access permissions (for KVM virtualization)
- `script` command from util-linux (used to stream the VM serial console)
- Minimum 8GB RAM, 10GB disk space

## Quick Start

### 1. Prerequisites Check

```bash
# Check Docker installation
docker --version

# Check KVM availability
kvm-ok

# Check /dev/kvm permissions
ls -la /dev/kvm

# Add to kvm group if necessary
sudo usermod -aG kvm $USER
# (Re-login required)
```

### 2. Run Tests

```bash
# Navigate to project directory
cd setup-k8s/test

# Test specific distribution
./run-e2e-tests.sh ubuntu-2404

# Other distribution examples
./run-e2e-tests.sh debian-12
./run-e2e-tests.sh centos-stream-9
```

### 3. Check Results

After test completion, results are displayed in the following format:

```
✅ Test PASSED for ubuntu-2404
Status: success
Setup Exit Code: 0
Kubelet Status: active
API Responsive: true
```

## docker-vm-runner integration

- `run-e2e-tests.sh` launches the public `ghcr.io/munenick/docker-vm-runner:latest` image. Override via `DOCKER_VM_RUNNER_IMAGE` to test new builds.
- `test/data/` is bind-mounted to `/data` inside the container. Cached QCOW2 images live under `data/base/`; per-test writable disks live under `data/vms/`.
- `test/data/state/` stores libvirt metadata and certificates (`/var/lib/docker-vm-runner` inside the container). Delete this directory to reset docker-vm-runner state between runs.
- `results/cloud-init/user-data.yaml` contains the rendered cloud-init payload that is mounted into the VM via docker-vm-runner.

Environment overrides:

| Variable | Purpose |
| --- | --- |
| `DOCKER_VM_RUNNER_IMAGE` | Container image tag to run (default `ghcr.io/munenick/docker-vm-runner:latest`). |
| `VM_DATA_DIR` | Host directory bound to `/data`. |

## Detailed Usage

### Basic Commands

```bash
# Display help
./run-e2e-tests.sh --help

# List supported distributions
./run-e2e-tests.sh --help

# Test specific distribution
./run-e2e-tests.sh <distro-name>
```

### Log Inspection

```bash
# Check execution logs
ls -la results/logs/
tail -f results/logs/ubuntu-2404-20250101-120000.log

# Check JSON results
cat results/test-result.json
```

### Troubleshooting

```bash
# Tail the most recent log
tail -f results/logs/<distro>-*.log

# If a test hangs, look for running containers named k8s-vm-*
docker ps | grep k8s-vm-
docker logs -f <container-name>

# Abort a stuck VM
docker stop <container-name>

# Pull the latest docker-vm-runner image
docker pull ghcr.io/munenick/docker-vm-runner:latest
```

## Internal Workflow

1. **Load configuration**: Validate the requested distribution against the built-in supported list.
2. **Prepare docker-vm-runner**: Pull the container image and create the shared data/cache directories.
3. **Prepare scripts**: In offline (bundled) mode, bundle `setup-k8s.sh` with all modules into a self-contained script. In online mode, run `curl | bash` from GitHub inside the VM to test the production flow.
4. **Launch VM container**: Run docker-vm-runner with `/dev/kvm`, mount caches, and inject an SSH key via cloud-init.
5. **Execute tests via SSH**: Transfer scripts, run setup/cleanup, and poll for completion.
6. **Collect results**: Save structured JSON output plus log files under `results/`.

## File Structure

```
test/
├── run-e2e-tests.sh         # E2E test runner (VM-based setup/cleanup)
├── run-ha-test.sh           # HA (kube-vip) integration test
├── run-deploy-test.sh       # Deploy subcommand E2E test (multi-VM)
├── run-backup-test.sh       # Backup/restore subcommand E2E test
├── run-renew-test.sh        # Certificate renewal E2E test
├── run-unit-tests.sh        # Unit tests for shell modules
├── data/                    # Cloud image cache (base/, vms/, state/)
└── results/                 # Test artifacts
    ├── logs/                    # Execution logs
    └── test-result.json         # Latest JSON summary

```

## Customization

### Adding New Distributions

Add the distribution name to the `SUPPORTED_DISTROS` array in `run-e2e-tests.sh`. The distribution must be supported by docker-vm-runner.

### Timeout Adjustment

Modify constants in `run-e2e-tests.sh`:

```bash
TIMEOUT_TOTAL=1800    # Extend to 30 minutes
```

### VM Configuration Tuning

`docker-vm-runner` exposes resource settings through environment variables (e.g., `MEMORY`, `CPUS`, `DISK_SIZE`). Use the `--memory`, `--cpus`, and `--disk-size` flags of `run-e2e-tests.sh`, or modify the `docker run` command in `run_vm_container()` when you need to tweak these values for all tests.

## Common Issues

### KVM Access Error
```bash
# Add your user to the kvm group (re-login required)
sudo usermod -aG kvm $USER
```

### Download Failure
```bash
# Clear cached base images (docker-vm-runner will re-download)
rm -f data/base/*.qcow2
```

### VM Boot Failure
```bash
# Remove working disks/state and rerun the test
rm -rf data/vms/*
rm -rf data/state/*
```

### Test Timeout
- Check network speed
- Adjust timeout values
- Check system resources (RAM/CPU)

## Development & Extension

### Debug Mode

```bash
# Verbose logging
BASH_DEBUG=1 ./run-e2e-tests.sh ubuntu-2404

# Manual VM launch using docker-vm-runner
cd setup-k8s/test
DOCKER_VM_RUNNER_IMAGE=docker-vm-runner:local \
docker run --rm -it \
  --device /dev/kvm:/dev/kvm \
  -v "$PWD/data:/data" \
  -v "$PWD/data/state:/var/lib/docker-vm-runner" \
  "$DOCKER_VM_RUNNER_IMAGE" bash
```

### Result Format

Test results are output in the following JSON format:

```json
{
  "status": "success|failed",
  "setup_test": {
    "status": "success|failed",
    "exit_code": 0,
    "kubelet_status": "active|inactive",
    "api_responsive": "true|false"
  },
  "cleanup_test": {
    "status": "success|failed|skipped",
    "exit_code": 0,
    "services_stopped": "true|false",
    "config_cleaned": "true|false",
    "packages_removed": "true|false"
  },
  "timestamp": "2025-01-01T12:00:00+00:00"
}
```

## License

This project follows the same license as the original `setup-k8s` project.
