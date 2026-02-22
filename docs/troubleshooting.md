# Troubleshooting

## Installation Issues
- Check kubelet logs:
```bash
journalctl -xeu kubelet
```
- Verify system requirements
- Confirm network connectivity
- Check distribution-specific logs for package management issues

## Worker Node Join Issues
- Verify network connectivity
- Check token expiration (24-hour default)
- Confirm firewall settings

## IPVS Mode Issues
- Check kernel module availability:
```bash
lsmod | grep ip_vs
```
- Verify ipvsadm is installed:
```bash
which ipvsadm
```
- Check kube-proxy mode:
```bash
kubectl get configmap -n kube-system kube-proxy -o yaml | grep mode
```
- View IPVS rules:
```bash
sudo ipvsadm -Ln
```

## nftables Mode Issues
- Check kernel module availability:
```bash
lsmod | grep nf_tables
```
- Verify nft is installed:
```bash
which nft
```
- Check kernel version (>= 3.13 required):
```bash
uname -r
```
- View nftables rules:
```bash
sudo nft list ruleset
```
- Check Kubernetes version supports nftables (>= 1.29):
```bash
kubectl version --short
```
- If NodePort services are not accessible:
  - nftables mode only allows NodePort on default IPs
  - Use the node's primary IP address, not 127.0.0.1

## Cleanup Issues
- Ensure proper node drainage
- Verify permissions
- Check system logs:
```bash
journalctl -xe
```

## Distribution Detection Issues
If the script fails to detect your distribution correctly:
- Check if `/etc/os-release` exists and contains valid information
- You may need to manually specify some steps for unsupported distributions

## Distribution-Specific Notes

### Debian/Ubuntu
- Uses apt/apt-get for package management
- Packages are held using apt-mark to prevent automatic updates

### RHEL/CentOS/Fedora
- Automatically detects and uses dnf or yum
- Package version locking handled via versionlock plugin

### SUSE
- Uses zypper for package management
- SLES may require subscription for repositories

### Alpine Linux
- Uses apk for package management
- Uses OpenRC instead of systemd; cgroup manager is set to `cgroupfs`
- Community repository is automatically enabled for Kubernetes packages
- Check kubelet logs with `rc-service kubelet status` or `/var/log/kubelet.log`
- `--ignore-preflight-errors=SystemVerification` is automatically added to kubeadm commands

### Arch Linux
- Uses pacman and AUR (Arch User Repository)
- Automatically installs yay AUR helper if needed
