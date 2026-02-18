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
        case "$ID:${VERSION_ID:-}" in
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
        if awk '
            BEGIN{inserted=0}
            {print}
            $0 ~ /^\[plugins\."io\.containerd\.grpc\.v1\.cri"\]/ && inserted==0 {print "  sandbox_image = \"registry.k8s.io/pause:3.10\""; inserted=1}
        ' /etc/containerd/config.toml > /etc/containerd/config.toml.tmp 2>/dev/null; then
            mv /etc/containerd/config.toml.tmp /etc/containerd/config.toml
        else
            rm -f /etc/containerd/config.toml.tmp
        fi
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
    local endpoint
    endpoint=$(get_cri_socket)
    echo "Configuring crictl at /etc/crictl.yaml (endpoint: $endpoint)"
    cat > /etc/crictl.yaml <<EOF
runtime-endpoint: $endpoint
image-endpoint: $endpoint
timeout: 10
debug: false
pull-image-on-create: false
EOF
}

# Helper: Generate kubeadm configuration
generate_kubeadm_config() {
    local config_file="/tmp/kubeadm-config.yaml"

    echo "Generating kubeadm configuration..." >&2

    # Parse KUBEADM_ARGS array first
    local POD_CIDR="" SERVICE_CIDR="" API_ADDR="" CP_ENDPOINT=""
    local i=0
    while [ $i -lt ${#KUBEADM_ARGS[@]} ]; do
        case "${KUBEADM_ARGS[$i]}" in
            --pod-network-cidr)   POD_CIDR="${KUBEADM_ARGS[$((i+1))]:-}";   ((i+=2)) ;;
            --service-cidr)       SERVICE_CIDR="${KUBEADM_ARGS[$((i+1))]:-}"; ((i+=2)) ;;
            --apiserver-advertise-address) API_ADDR="${KUBEADM_ARGS[$((i+1))]:-}"; ((i+=2)) ;;
            --control-plane-endpoint)      CP_ENDPOINT="${KUBEADM_ARGS[$((i+1))]:-}"; ((i+=2)) ;;
            *) ((i+=1)) ;;
        esac
    done

    # InitConfiguration
    cat > "$config_file" <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
EOF

    # localAPIEndpoint under InitConfiguration (not ClusterConfiguration)
    if [ -n "$API_ADDR" ]; then
        cat >> "$config_file" <<EOF
localAPIEndpoint:
  advertiseAddress: $API_ADDR
EOF
    fi

    # Add CRI socket if not using default containerd
    if [ "$CRI" != "containerd" ]; then
        local cri_socket
        cri_socket=$(get_cri_socket)
        cat >> "$config_file" <<EOF
nodeRegistration:
  criSocket: $cri_socket
EOF
    fi

    # ClusterConfiguration
    cat >> "$config_file" <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
EOF

    if [ -n "$POD_CIDR" ] || [ -n "$SERVICE_CIDR" ]; then
        echo "networking:" >> "$config_file"
        [ -n "$POD_CIDR" ]     && echo "  podSubnet: $POD_CIDR" >> "$config_file"
        [ -n "$SERVICE_CIDR" ] && echo "  serviceSubnet: $SERVICE_CIDR" >> "$config_file"
    fi

    if [ -n "$CP_ENDPOINT" ]; then
        echo "controlPlaneEndpoint: $CP_ENDPOINT" >> "$config_file"
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

# Helper: Configure kubectl for a user after kubeadm init/join
_configure_kubectl() {
    echo "Configuring kubectl..."
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        USER_HOME="/home/$SUDO_USER"
        mkdir -p "$USER_HOME/.kube"
        cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
        chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$USER_HOME/.kube"
        echo "Created kubectl configuration for user $SUDO_USER"
    else
        mkdir -p /root/.kube
        cp -f /etc/kubernetes/admin.conf /root/.kube/config
        echo "Created kubectl configuration for root user at /root/.kube/config"
    fi
}

# Helper: Deploy kube-vip static pod for HA VIP
# Helper: Determine kubeconfig path for kube-vip.
# K8s 1.29+ generates super-admin.conf (server: localhost:6443) which avoids
# the chicken-and-egg problem where admin.conf points to the VIP that kube-vip
# hasn't yet claimed.  For K8s < 1.29 super-admin.conf doesn't exist, so fall
# back to admin.conf (which still points to localhost on those versions).
_kube_vip_kubeconfig_path() {
    local k8s_minor
    k8s_minor=$(echo "$K8S_VERSION" | cut -d. -f2)
    if [ -n "$k8s_minor" ] && [ "$k8s_minor" -ge 29 ] 2>/dev/null; then
        echo "/etc/kubernetes/super-admin.conf"
    else
        echo "/etc/kubernetes/admin.conf"
    fi
}

# Helper: Generate kube-vip static pod manifest (unified for all CRIs)
_generate_kube_vip_manifest() {
    local vip="$1" iface="$2" image="$3" kubeconfig_path="$4"
    cat <<KVEOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  containers:
  - name: kube-vip
    image: ${image}
    args:
    - manager
    env:
    - name: vip_arp
      value: "true"
    - name: port
      value: "6443"
    - name: vip_interface
      value: "${iface}"
    - name: vip_cidr
      value: "32"
    - name: cp_enable
      value: "true"
    - name: cp_namespace
      value: kube-system
    - name: vip_ddns
      value: "false"
    - name: vip_leaderelection
      value: "true"
    - name: vip_leasename
      value: plndr-cp-lock
    - name: vip_leaseduration
      value: "5"
    - name: vip_renewdeadline
      value: "3"
    - name: vip_retryperiod
      value: "1"
    - name: address
      value: "${vip}"
    securityContext:
      capabilities:
        add:
        - NET_ADMIN
        - NET_RAW
    volumeMounts:
    - mountPath: /etc/kubernetes/admin.conf
      name: kubeconfig
  hostAliases:
  - hostnames:
    - kubernetes
    ip: 127.0.0.1
  hostNetwork: true
  volumes:
  - hostPath:
      path: ${kubeconfig_path}
    name: kubeconfig
KVEOF
}

# Helper: Remove pre-added VIP on failure
_rollback_vip() {
    local vip="$HA_VIP_ADDRESS"
    local iface="$HA_VIP_INTERFACE"
    if ip addr show dev "$iface" 2>/dev/null | grep -q "inet ${vip}/"; then
        echo "Rolling back pre-added VIP $vip from $iface..."
        ip addr del "${vip}/32" dev "$iface" 2>/dev/null || true
    fi
}

# Helper: Verify kube-vip kubeconfig file exists after kubeadm init/join.
# If the expected file doesn't exist, patch the manifest to use admin.conf.
_verify_kube_vip_kubeconfig() {
    local expected_path
    expected_path=$(_kube_vip_kubeconfig_path)
    if [ ! -f "$expected_path" ]; then
        echo "Warning: Expected kubeconfig $expected_path not found"
        if [ "$expected_path" != "/etc/kubernetes/admin.conf" ] && [ -f "/etc/kubernetes/admin.conf" ]; then
            echo "Patching kube-vip manifest to use /etc/kubernetes/admin.conf instead..."
            sed -i "s|path: ${expected_path}|path: /etc/kubernetes/admin.conf|" \
                /etc/kubernetes/manifests/kube-vip.yaml 2>/dev/null || true
        fi
    fi
}

deploy_kube_vip() {
    local vip="$HA_VIP_ADDRESS"
    local iface="$HA_VIP_INTERFACE"
    local kube_vip_image="ghcr.io/kube-vip/kube-vip:v0.8.9"
    local manifest_dir="/etc/kubernetes/manifests"
    local kubeconfig_path
    kubeconfig_path=$(_kube_vip_kubeconfig_path)

    echo "Deploying kube-vip for HA (VIP=$vip, interface=$iface)..."
    echo "  kubeconfig: $kubeconfig_path"
    mkdir -p "$manifest_dir"

    # Pull image based on CRI
    if [ "$CRI" = "crio" ]; then
        echo "Pulling kube-vip image via crictl..."
        crictl pull "$kube_vip_image"
    else
        echo "Pulling kube-vip image via ctr..."
        ctr image pull "$kube_vip_image"
    fi

    # Generate manifest from unified template (same for all CRIs)
    _generate_kube_vip_manifest "$vip" "$iface" "$kube_vip_image" "$kubeconfig_path" \
        > "${manifest_dir}/kube-vip.yaml"

    echo "kube-vip manifest written to ${manifest_dir}/kube-vip.yaml"

    # Pre-add VIP to the interface so it is reachable during kubeadm init
    # before kube-vip can perform leader election.
    # kube-vip will take over management of this address once it starts.
    if ! ip addr show dev "$iface" | grep -q "inet ${vip}/"; then
        echo "Pre-adding VIP $vip to $iface for bootstrap..."
        ip addr add "${vip}/32" dev "$iface"
    fi
}

# Helper: Initialize Kubernetes cluster
initialize_cluster() {
    echo "Initializing cluster..."

    # Deploy kube-vip before kubeadm init if HA is enabled
    if [ "$HA_ENABLED" = true ]; then
        deploy_kube_vip
    fi

    # Run kubeadm init, capturing exit code for rollback
    local init_exit=0
    if [ "$PROXY_MODE" != "iptables" ] || [ "${#KUBEADM_ARGS[@]}" -gt 0 ]; then
        local CONFIG_FILE
        CONFIG_FILE=$(generate_kubeadm_config)
        echo "Using kubeadm configuration file: $CONFIG_FILE"
        kubeadm init --config "$CONFIG_FILE" || init_exit=$?
        rm -f "$CONFIG_FILE"
    else
        if [ "$CRI" != "containerd" ]; then
            local cri_socket
            cri_socket=$(get_cri_socket)
            kubeadm init --cri-socket "$cri_socket" || init_exit=$?
        else
            kubeadm init || init_exit=$?
        fi
    fi

    if [ "$init_exit" -ne 0 ]; then
        echo "Error: kubeadm init failed (exit code: $init_exit)"
        if [ "$HA_ENABLED" = true ]; then
            _rollback_vip
        fi
        return "$init_exit"
    fi

    # Verify kube-vip kubeconfig exists after init
    if [ "$HA_ENABLED" = true ]; then
        _verify_kube_vip_kubeconfig
    fi

    _configure_kubectl

    # Display join command for worker nodes
    echo "Displaying join command for worker nodes..."
    kubeadm token create --print-join-command

    # For HA clusters, upload certs and display control-plane join command
    if [ "$HA_ENABLED" = true ]; then
        echo ""
        echo "=== HA Cluster: Control-Plane Join Information ==="
        local cert_key
        cert_key=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
        if [ -z "$cert_key" ]; then
            echo "Error: Failed to retrieve certificate key from upload-certs"
            echo "You can manually run: kubeadm init phase upload-certs --upload-certs"
            return 1
        fi
        echo "Certificate key: $cert_key"
        echo ""
        echo "To join additional control-plane nodes, run:"
        echo "  setup-k8s.sh join --control-plane --certificate-key $cert_key \\"
        echo "    --ha-vip ${HA_VIP_ADDRESS} \\"
        echo "    --join-token <token> --join-address <address> --discovery-token-hash <hash>"
        echo "================================================="
    fi

    echo "Cluster initialization complete!"
    echo "Next steps:"
    echo "1. Install a CNI plugin"
    echo "2. For single-node clusters, remove the taint with:"
    echo "   kubectl taint nodes --all node-role.kubernetes.io/control-plane-"
}

# Helper: Join node to cluster
join_cluster() {
    echo "Joining node to cluster..."

    # Deploy kube-vip on additional control-plane nodes
    if [ "${JOIN_AS_CONTROL_PLANE:-false}" = true ] && [ -n "$HA_VIP_ADDRESS" ]; then
        deploy_kube_vip
    fi

    local -a join_args=("${JOIN_ADDRESS}" --token "${JOIN_TOKEN}" --discovery-token-ca-cert-hash "${DISCOVERY_TOKEN_HASH}")
    if [ "$CRI" != "containerd" ]; then
        local cri_socket
        cri_socket=$(get_cri_socket)
        join_args+=(--cri-socket "$cri_socket")
    fi

    # HA cluster: join as control-plane node
    if [ "${JOIN_AS_CONTROL_PLANE:-false}" = true ]; then
        join_args+=(--control-plane --certificate-key "${CERTIFICATE_KEY}")
    fi

    local join_exit=0
    kubeadm join "${join_args[@]}" || join_exit=$?

    if [ "$join_exit" -ne 0 ]; then
        echo "Error: kubeadm join failed (exit code: $join_exit)"
        if [ "${JOIN_AS_CONTROL_PLANE:-false}" = true ] && [ -n "$HA_VIP_ADDRESS" ]; then
            _rollback_vip
        fi
        return "$join_exit"
    fi

    # Verify kube-vip kubeconfig exists for control-plane join
    if [ "${JOIN_AS_CONTROL_PLANE:-false}" = true ] && [ -n "$HA_VIP_ADDRESS" ]; then
        _verify_kube_vip_kubeconfig
    fi

    # Configure kubectl for control-plane join
    if [ "${JOIN_AS_CONTROL_PLANE:-false}" = true ]; then
        _configure_kubectl
        echo "Control-plane node has joined the cluster!"
    else
        echo "Worker node has joined the cluster!"
    fi
}

# Helper: Clean up .kube directories
cleanup_kube_configs() {
    # Clean up .kube directory
    if [ -n "${SUDO_USER:-}" ]; then
        USER_HOME="/home/$SUDO_USER"
        echo "Cleanup: Removing .kube directory and config for user $SUDO_USER"
        rm -rf "$USER_HOME/.kube" || true
    fi

    # Clean up root's .kube directory
    ROOT_HOME=$(eval echo ~root)
    echo "Cleanup: Removing .kube directory and config for root user at $ROOT_HOME"
    rm -rf "$ROOT_HOME/.kube" || true
}

# Helper: Reset containerd configuration
reset_containerd_config() {
    if [ -f /etc/containerd/config.toml ]; then
        echo "Resetting containerd configuration to default..."
        if command -v containerd &> /dev/null; then
            # Backup current config
            cp /etc/containerd/config.toml "/etc/containerd/config.toml.bak.$(date +%Y%m%d%H%M%S)"
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
