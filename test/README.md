# K8s Multi-Distribution Test Suite

Docker + QEMU test framework for automatically testing `setup-k8s.sh` script across multiple Linux distributions.

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
./run-test.sh ubuntu-2404

# Other distribution examples
./run-test.sh debian-12
./run-test.sh centos-stream-9
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

## Detailed Usage

### Basic Commands

```bash
# Display help
./run-test.sh --help

# List supported distributions
./run-test.sh --help

# Test specific distribution
./run-test.sh <distro-name>
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
# Check container status
docker-compose ps

# Check inside container
docker-compose exec qemu-tools bash

# Manual container restart
docker-compose down
docker-compose up -d qemu-tools
```

## Internal Workflow

1. **Load configuration**: Get target distribution settings from `distro-urls.conf`
2. **Start container**: Auto-start QEMU tools container (only when needed)
3. **Fetch image**: Download and cache cloud images
4. **Prepare cloud-init**: Embed setup-k8s.sh in generic template
5. **Start QEMU**: Boot VM, start monitoring serial console output
6. **Run test**: Auto-execute setup-k8s.sh inside VM
7. **Collect results**: Check kubelet status, API response
8. **Save results**: Save results in JSON format, output log files

## File Structure

```
test/
├── run-test.sh              # Main execution script
├── distro-urls.conf         # Distribution configuration
├── cloud-init-template.yaml # Generic cloud-init template
├── docker-compose.yml       # QEMU container definition
├── Dockerfile              # QEMU environment image
├── images/                 # Cloud image cache
└── results/                # Test results and logs
    ├── logs/              # Execution logs
    └── test-result.json   # Latest test result
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

Modify constants in `run-test.sh`:

```bash
TIMEOUT_TOTAL=1800    # Extend to 30 minutes
TIMEOUT_DOWNLOAD=900  # Extend to 15 minutes
```

### QEMU Configuration Tuning

Modify QEMU command in `run-test.sh`:

```bash
# Example: Increase memory
-m 8192 \  # 8GB RAM
```

## Common Issues

### KVM Access Error
```bash
# Set /dev/kvm permissions
sudo chmod 666 /dev/kvm
```

### Download Failure
```bash
# Clear cache
rm -f images/*.qcow2
```

### VM Boot Failure
```bash
# Restart container
docker-compose restart qemu-tools
```

### Test Timeout
- Check network speed
- Adjust timeout values
- Check system resources (RAM/CPU)

## Development & Extension

### Debug Mode

```bash
# Verbose logging
BASH_DEBUG=1 ./run-test.sh ubuntu-2404

# Manual VM launch
docker-compose exec qemu-tools bash
qemu-system-x86_64 -machine pc,accel=kvm ...
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