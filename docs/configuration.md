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
./setup-k8s.sh --node-type master --proxy-mode ipvs
```

nftables mode (requires K8s 1.29+):
```bash
./setup-k8s.sh --node-type master --proxy-mode nftables --kubernetes-version 1.31
```

**Note**: If prerequisites are not met, the script will automatically fall back to iptables mode.

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
