#!/bin/bash

# Helper: Get Debian/Ubuntu codename without lsb_release
get_debian_codename() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ -n "$VERSION_CODENAME" ]; then
            echo "$VERSION_CODENAME"
            return 0
        fi
        if [ -n "$UBUNTU_CODENAME" ]; then
            echo "$UBUNTU_CODENAME"
            return 0
        fi
        # Fallback mapping for some well-known VERSION_ID values
        case "$ID:$VERSION_ID" in
            ubuntu:24.04) echo "noble" ; return 0 ;;
            ubuntu:22.04) echo "jammy" ; return 0 ;;
            ubuntu:20.04) echo "focal" ; return 0 ;;
            debian:12) echo "bookworm" ; return 0 ;;
            debian:11) echo "bullseye" ; return 0 ;;
        esac
    fi
    # Last resort
    echo "stable"
}

# Helper: configure containerd TOML with v2 layout, SystemdCgroup=true, sandbox_image
configure_containerd_toml() {
    echo "Generating and tuning containerd config..."
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml

    # Ensure SystemdCgroup=true for runc
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml || true

    # Only inject a version header when the generated config lacks one
    if ! grep -q '^version *= *[0-9]' /etc/containerd/config.toml 2>/dev/null; then
        sed -i '1s/^/version = 2\n/' /etc/containerd/config.toml || true
    fi

    # Set sandbox_image to registry.k8s.io/pause:3.10
    if grep -q '^\s*sandbox_image\s*=\s*"' /etc/containerd/config.toml; then
        sed -i 's#^\s*sandbox_image\s*=\s*".*"#  sandbox_image = "registry.k8s.io/pause:3.10"#' /etc/containerd/config.toml || true
    else
        # Insert under the CRI plugin section
        awk '
            BEGIN{inserted=0}
            {print}
            $0 ~ /^\[plugins\."io\.containerd\.grpc\.v1\.cri"\]/ && inserted==0 {print "  sandbox_image = \"registry.k8s.io/pause:3.10\""; inserted=1}
        ' /etc/containerd/config.toml > /etc/containerd/config.toml.tmp 2>/dev/null && mv /etc/containerd/config.toml.tmp /etc/containerd/config.toml || true
    fi

    systemctl daemon-reload || true
    systemctl enable containerd || true
    systemctl restart containerd
}

# Helper: Get CRI socket path based on runtime
get_cri_socket() {
    case "$CRI" in
        containerd)
            echo "unix:///run/containerd/containerd.sock"
            ;;
        crio)
            echo "unix:///var/run/crio/crio.sock"
            ;;
        docker)
            echo "unix:///var/run/dockershim.sock"
            ;;
        *)
            # Default to containerd if unknown
            echo "unix:///run/containerd/containerd.sock"
            ;;
    esac
}

# Helper: configure crictl runtime endpoint
configure_crictl() {
    local runtime="$1"  # containerd|crio|docker
    local endpoint=$(get_cri_socket)
    echo "Configuring crictl at /etc/crictl.yaml (endpoint: $endpoint)"
    cat > /etc/crictl.yaml <<EOF
runtime-endpoint: $endpoint
image-endpoint: $endpoint
timeout: 10
debug: false
pull-image-on-create: false
EOF
}

# Helper: Generate kubeadm configuration for IPVS mode
generate_kubeadm_config() {
    local config_file="/tmp/kubeadm-config.yaml"
    
    echo "Generating kubeadm configuration..." >&2
    
    # Start with base configuration
    cat > "$config_file" <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
EOF

    # Add CRI socket if not using default containerd
    if [ "$CRI" != "containerd" ]; then
        local cri_socket=$(get_cri_socket)
        cat >> "$config_file" <<EOF
nodeRegistration:
  criSocket: $cri_socket
EOF
    fi

    # Add ClusterConfiguration
    cat >> "$config_file" <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
EOF

    # Parse KUBEADM_ARGS and add to config
    if echo "$KUBEADM_ARGS" | grep -q "pod-network-cidr"; then
        POD_CIDR=$(echo "$KUBEADM_ARGS" | sed -n 's/.*--pod-network-cidr \([^ ]*\).*/\1/p')
        cat >> "$config_file" <<EOF
networking:
  podSubnet: $POD_CIDR
EOF
    fi
    
    if echo "$KUBEADM_ARGS" | grep -q "service-cidr"; then
        SERVICE_CIDR=$(echo "$KUBEADM_ARGS" | sed -n 's/.*--service-cidr \([^ ]*\).*/\1/p')
        cat >> "$config_file" <<EOF
  serviceSubnet: $SERVICE_CIDR
EOF
    fi
    
    if echo "$KUBEADM_ARGS" | grep -q "apiserver-advertise-address"; then
        API_ADDR=$(echo "$KUBEADM_ARGS" | sed -n 's/.*--apiserver-advertise-address \([^ ]*\).*/\1/p')
        cat >> "$config_file" <<EOF
apiServer:
  advertiseAddress: $API_ADDR
EOF
    fi
    
    if echo "$KUBEADM_ARGS" | grep -q "control-plane-endpoint"; then
        CP_ENDPOINT=$(echo "$KUBEADM_ARGS" | sed -n 's/.*--control-plane-endpoint \([^ ]*\).*/\1/p')
        cat >> "$config_file" <<EOF
controlPlaneEndpoint: $CP_ENDPOINT
EOF
    fi

    # Add KubeProxyConfiguration for non-default proxy modes
    if [ "$PROXY_MODE" = "ipvs" ]; then
        cat >> "$config_file" <<EOF
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
ipvs:
  scheduler: "rr"
  strictARP: true
EOF
    elif [ "$PROXY_MODE" = "nftables" ]; then
        cat >> "$config_file" <<EOF
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: nftables
EOF
    fi
    
    echo "$config_file"
}

# Helper: Initialize Kubernetes cluster (master node)
initialize_master() {
    echo "Initializing master node..."
    
    # Generate configuration file if non-default proxy mode or complex config needed
    if [ "$PROXY_MODE" != "iptables" ] || [ -n "$KUBEADM_ARGS" ]; then
        CONFIG_FILE=$(generate_kubeadm_config)
        echo "Using kubeadm configuration file: $CONFIG_FILE"
        kubeadm init --config "$CONFIG_FILE"
        rm -f "$CONFIG_FILE"
    else
        # Simple init for default iptables mode with no extra args
        if [ "$CRI" != "containerd" ]; then
            local cri_socket=$(get_cri_socket)
            kubeadm init --cri-socket "$cri_socket"
        else
            kubeadm init
        fi
    fi

    # Configure kubectl
    echo "Configuring kubectl..."
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        # If run with sudo by a non-root user
        USER_HOME="/home/$SUDO_USER"
        mkdir -p "$USER_HOME/.kube"
        cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
        chown -R "$SUDO_USER:$(id -gn $SUDO_USER)" "$USER_HOME/.kube"
        echo "Created kubectl configuration for user $SUDO_USER"
    else
        # If run directly as root 
        mkdir -p /root/.kube
        cp -f /etc/kubernetes/admin.conf /root/.kube/config
        echo "Created kubectl configuration for root user at /root/.kube/config"
    fi

    # Display join command
    echo "Displaying join command for worker nodes..."
    kubeadm token create --print-join-command

    echo "Master node initialization complete!"
    echo "Next steps:"
    echo "1. Install a CNI plugin"
    echo "2. For single-node clusters, remove the taint with:"
    echo "   kubectl taint nodes --all node-role.kubernetes.io/control-plane-"
}

# Helper: Join worker node to cluster
join_worker() {
    echo "Joining worker node to cluster..."
    JOIN_ARGS="${JOIN_ADDRESS} --token ${JOIN_TOKEN} --discovery-token-ca-cert-hash ${DISCOVERY_TOKEN_HASH}"
    if [ "$CRI" != "containerd" ]; then
        local cri_socket=$(get_cri_socket)
        JOIN_ARGS="$JOIN_ARGS --cri-socket $cri_socket"
    fi
    kubeadm join $JOIN_ARGS
    
    echo "Worker node has joined the cluster!"
}

# Helper: Clean up .kube directories
cleanup_kube_configs() {
    # Clean up .kube directory
    if [ -n "$SUDO_USER" ]; then
        USER_HOME="/home/$SUDO_USER"
        echo "Cleanup: Removing .kube directory and config for user $SUDO_USER"
        rm -rf "$USER_HOME/.kube" || true
        rm -f "$USER_HOME/.kube/config" || true
    fi

    # Clean up root's .kube directory
    ROOT_HOME=$(eval echo ~root)
    echo "Cleanup: Removing .kube directory and config for root user at $ROOT_HOME"
    rm -rf "$ROOT_HOME/.kube" || true
    rm -f "$ROOT_HOME/.kube/config" || true

    # Clean up all users' .kube/config files
    for user_home in /home/*; do
        if [ -d "$user_home" ]; then
            echo "Cleanup: Removing .kube directory and config for user directory $user_home"
            rm -rf "$user_home/.kube" || true
            rm -f "$user_home/.kube/config" || true
        fi
    done
}

# Helper: Reset containerd configuration
reset_containerd_config() {
    if [ -f /etc/containerd/config.toml ]; then
        echo "Resetting containerd configuration to default..."
        if command -v containerd &> /dev/null; then
            # Backup current config
            cp /etc/containerd/config.toml /etc/containerd/config.toml.bak.$(date +%Y%m%d%H%M%S)
            # Generate default config
            containerd config default > /etc/containerd/config.toml
            # Restart containerd if it's running
            if systemctl is-active containerd &>/dev/null; then
                echo "Restarting containerd with default configuration..."
                systemctl restart containerd
            fi
        fi
    fi
}

# Show installed versions
show_versions() {
    echo "Installed versions:"
    kubectl version --client || true
    kubeadm version || true
}

# === Cleanup helper functions ===

# Stop Kubernetes services
stop_kubernetes_services() {
    echo "Stopping Kubernetes services..."
    systemctl stop kubelet || true
    systemctl disable kubelet || true
}

# Stop CRI services
stop_cri_services() {
    echo "Checking and stopping CRI services..."
    
    # Stop CRI-O if present
    if systemctl list-unit-files | grep -q '^crio\.service'; then
        echo "Stopping and disabling CRI-O service..."
        systemctl stop crio || true
        systemctl disable crio || true
    fi
    
    # Note: containerd is not stopped to avoid impacting Docker
    # Only its configuration will be reset later with reset_containerd_config()
}

# Remove Kubernetes configuration files
remove_kubernetes_configs() {
    echo "Removing Kubernetes configuration files..."
    rm -f /etc/default/kubelet
    rm -rf /etc/kubernetes
    rm -rf /etc/systemd/system/kubelet.service.d
}

# Reset Kubernetes cluster state
reset_kubernetes_cluster() {
    if command -v kubeadm &> /dev/null; then
        echo "Resetting kubeadm cluster state..."
        kubeadm reset -f || true
    fi
}

# Conditionally cleanup CNI
cleanup_cni_conditionally() {
    if [ "$PRESERVE_CNI" = false ]; then
        cleanup_cni
    else
        echo "Preserving CNI configurations as requested."
    fi
}
