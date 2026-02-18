# K8s Multi-Distribution Test Suite

Docker + QEMU test framework that validates `setup-k8s.sh` across multiple Linux distributions. VM lifecycle management relies on the published [`ghcr.io/munenick/docker-vm-runner`](https://github.com/MuNeNICK/docker-vm-runner) image, so contributors can run identical environments without custom tooling.

## Features

- **Simple**: Complete test execution with a single command
- **No host pollution**: No need to install QEMU/cloud-utils on host
- **Fully automated**: Unattended execution from VM boot to K8s setup and result collection
- **13 distributions/versions supported**: Ubuntu, Debian, CentOS, Fedora, openSUSE, Rocky, AlmaLinux, Arch Linux
- **Reliable result verification**: Confirms setup-k8s.sh execution, kubelet startup, and API response

## Supported Distributions

| Distribution | Version | Login User |
|-------------|---------|------------|
| ubuntu-2404 | 24.04 LTS | ubuntu |
| ubuntu-2204 | 22.04 LTS | ubuntu |
| ubuntu-2004 | 20.04 LTS | ubuntu |
| debian-12 | 12 (Bookworm) | debian |
| debian-11 | 11 (Bullseye) | debian |
| centos-stream-9 | Stream 9 | centos |
| fedora-41 | 41 | fedora |
| opensuse-leap-155 | Leap 15.5 | opensuse |
| rocky-linux-9 | 9 | rocky |
| rocky-linux-8 | 8 | rocky |
| almalinux-9 | 9 | almalinux |
| almalinux-8 | 8 | almalinux |
| archlinux | Rolling | arch |

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
| `VM_STATE_DIR` | Host directory bound to `/var/lib/docker-vm-runner`. |

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

1. **Load configuration**: Read distro/image metadata from `distro-urls.conf`.
2. **Prepare docker-vm-runner**: Pull (or build) the container image and create the shared `/images` cache directories.
3. **Render cloud-init**: Bundle `setup-k8s.sh`/`cleanup-k8s.sh` into `results/cloud-init/user-data.yaml`.
4. **Launch VM container**: Run docker-vm-runner with `/dev/kvm`, mount caches, and feed the rendered cloud-init payload.
5. **Stream console output**: Attach via `script` so the guest serial console is visible and parsed for JSON markers.
6. **Collect results**: Save structured JSON output plus log files under `results/`.

## File Structure

```
test/
├── run-e2e-tests.sh         # E2E test runner (VM-based setup/cleanup)
├── run-unit-tests.sh        # Unit tests for shell modules
├── data/                    # Cloud image cache (base/, vms/, state/)
└── results/                 # Test artifacts
    ├── logs/                    # Execution logs
    └── test-result.json         # Latest JSON summary

```

## Customization

### Adding New Distributions

Add to `distro-urls.conf` in the following format:

```bash
# New distribution
newdistro-1.0=https://example.com/newdistro-1.0-cloud.qcow2
newdistro-1.0_user=newuser
```

### Timeout Adjustment

Modify constants in `run-e2e-tests.sh`:

```bash
TIMEOUT_TOTAL=1800    # Extend to 30 minutes
```

### VM Configuration Tuning

`docker-vm-runner` exposes resource settings through environment variables (e.g., `MEMORY`, `CPUS`, `DISK_SIZE`). Add extra `-e` entries to the `docker_cmd` array in `run-e2e-tests.sh` when you need to tweak these values for all tests.

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
  "setup_exit_code": 0,
  "kubelet_status": "active|inactive", 
  "kubeconfig_exists": "true|false",
  "api_responsive": "true|false",
  "timestamp": "2025-01-01T12:00:00Z"
}
```

## License

This project follows the same license as the original `setup-k8s` project.
