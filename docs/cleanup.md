# Cleanup Guide

## Quick Start

Execute the cleanup script:
```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/cleanup-k8s.sh | sudo bash -s -- [options]
```

## Worker Node Cleanup

1. Drain the node (run on master):
```bash
kubectl drain <worker-node-name> --ignore-daemonsets
kubectl delete node <worker-node-name>
```

2. Run cleanup on worker:
```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/cleanup-k8s.sh | sudo bash -s -- --node-type worker
```

## Master Node Cleanup

**Warning**: This will destroy your entire cluster.

1. Ensure all worker nodes are removed first
2. Run cleanup:
```bash
curl -fsSL https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main/cleanup-k8s.sh | sudo bash -s -- --node-type master
```

## Options

See [reference.md](reference.md) for the full list of cleanup-k8s.sh options.
