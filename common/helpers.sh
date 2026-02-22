#!/bin/bash

# === Architecture and Init System Detection ===

_detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l|armv6l) echo "arm" ;;
        s390x)   echo "s390x" ;;
        ppc64le) echo "ppc64le" ;;
        *)       log_warn "Unknown architecture: $arch"; echo "$arch" ;;
    esac
}

_detect_init_system() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null; then
        echo "systemd"
    elif command -v rc-service &>/dev/null; then
        echo "openrc"
    else
        echo "unknown"
    fi
}

# === Download Helpers ===

_download_binary() {
    local url="$1" dest="$2"
    log_info "Downloading: $url"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"; then
        log_error "Failed to download: $url"
        return 1
    fi
    chmod +x "$dest"
}

# Checksum-verified download (verification is best-effort)
# Usage: _download_with_checksum <url> <dest> [checksum_url]
_download_with_checksum() {
    local url="$1" dest="$2" checksum_url="${3:-}"
    _download_binary "$url" "$dest"
    if [ -n "$checksum_url" ]; then
        local expected actual
        if expected=$(curl -fsSL "$checksum_url" 2>/dev/null); then
            expected=$(echo "$expected" | awk '{print $1}')
            actual=$(sha256sum "$dest" | awk '{print $1}')
            if [ "$expected" != "$actual" ]; then
                log_error "Checksum mismatch for $dest"
                rm -f "$dest"
                return 1
            fi
            log_info "Checksum verified: $(basename "$dest")"
        fi
    fi
}

# GitHub API: resolve latest release version (without "v" prefix)
_resolve_github_latest_version() {
    local repo="$1"
    local auth_args=()
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        auth_args=(-H "Authorization: token ${GITHUB_TOKEN}")
    fi
    local tag
    tag=$(curl -fsSL --retry 3 --retry-delay 2 "${auth_args[@]}" \
        "https://api.github.com/repos/${repo}/releases/latest" \
        | awk -F'"' '/"tag_name"/{print $4; exit}')
    if [ -z "$tag" ]; then
        log_error "Failed to resolve latest version for ${repo}"
        return 1
    fi
    echo "${tag#v}"
}

# === Service Abstraction (systemd / OpenRC) ===

_service_enable() {
    local svc="$1"
    case "$(_detect_init_system)" in
        systemd) systemctl enable "$svc" ;;
        openrc)  rc-update add "$svc" default ;;
    esac
}

_service_start() {
    local svc="$1"
    case "$(_detect_init_system)" in
        systemd) systemctl start "$svc" ;;
        openrc)  rc-service "$svc" start ;;
    esac
}

_service_stop() {
    local svc="$1"
    case "$(_detect_init_system)" in
        systemd) systemctl stop "$svc" 2>/dev/null || true ;;
        openrc)  rc-service "$svc" stop 2>/dev/null || true ;;
    esac
}

_service_restart() {
    local svc="$1"
    case "$(_detect_init_system)" in
        systemd) systemctl restart "$svc" ;;
        openrc)  rc-service "$svc" restart ;;
    esac
}

_service_disable() {
    local svc="$1"
    case "$(_detect_init_system)" in
        systemd) systemctl disable "$svc" 2>/dev/null || true ;;
        openrc)  rc-update del "$svc" default 2>/dev/null || true ;;
    esac
}

_service_is_active() {
    local svc="$1"
    case "$(_detect_init_system)" in
        systemd) systemctl is-active --quiet "$svc" ;;
        openrc)  rc-service "$svc" status &>/dev/null ;;
    esac
}

_service_reload() {
    case "$(_detect_init_system)" in
        systemd) systemctl daemon-reload ;;
        openrc)  : ;; # OpenRC does not need daemon-reload
    esac
}

# === kubeadm Preflight Ignore (OpenRC) ===

_kubeadm_preflight_ignore_args() {
    if [ "$(_detect_init_system)" != "systemd" ]; then
        echo "--ignore-preflight-errors=SystemVerification"
    fi
}

# Helper: Get the home directory for a given user (portable, no hardcoded /home)
get_user_home() {
    local user="$1"
    if ! [[ "$user" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid username: $user"
        return 1
    fi
    local home
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6) || true
    if [ -z "$home" ]; then
        if [ "$user" = "root" ]; then home="/root"
        else home="/home/$user"
        fi
    fi
    echo "$home"
}

# Helper: Get Debian/Ubuntu codename without lsb_release
get_debian_codename() {
    . /etc/os-release
    if [ -n "${VERSION_CODENAME:-}" ]; then
        echo "$VERSION_CODENAME"
        return 0
    fi
    if [ -n "${UBUNTU_CODENAME:-}" ]; then
        echo "$UBUNTU_CODENAME"
        return 0
    fi
    log_error "Could not determine Debian/Ubuntu codename from /etc/os-release"
    return 1
}

# Helper: configure containerd TOML with v2 layout, SystemdCgroup=true, sandbox_image
configure_containerd_toml() {
    log_info "Generating and tuning containerd config..."
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml

    # Ensure SystemdCgroup=true for runc
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

    # Only inject a version header when the generated config lacks one
    if ! grep -q '^version *= *[0-9]' /etc/containerd/config.toml 2>/dev/null; then
        sed -i '1s/^/version = 2\n/' /etc/containerd/config.toml
    fi

    # Set sandbox_image to registry.k8s.io/pause:<version>
    local _pause_image="registry.k8s.io/pause:${PAUSE_IMAGE_VERSION}"
    if grep -q '^\s*sandbox_image\s*=\s*"' /etc/containerd/config.toml; then
        sed -i "s#^\s*sandbox_image\s*=\s*\".*\"#  sandbox_image = \"${_pause_image}\"#" /etc/containerd/config.toml
    else
        # Insert under the CRI plugin section
        if awk -v pause_img="${_pause_image}" '
            BEGIN{inserted=0}
            {print}
            $0 ~ /^\[plugins\."io\.containerd\.grpc\.v1\.cri"\]/ && inserted==0 {print "  sandbox_image = \"" pause_img "\""; inserted=1}
        ' /etc/containerd/config.toml > /etc/containerd/config.toml.tmp; then
            mv /etc/containerd/config.toml.tmp /etc/containerd/config.toml
        else
            log_error "Failed to inject sandbox_image into containerd config"
            rm -f /etc/containerd/config.toml.tmp
            return 1
        fi
    fi

    _service_reload
    _service_enable containerd
    _service_restart containerd
    if ! _service_is_active containerd; then
        log_error "containerd failed to start after configuration"
        systemctl status containerd --no-pager 2>/dev/null || true
        return 1
    fi
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
    esac
}

# Helper: configure crictl runtime endpoint
configure_crictl() {
    local endpoint
    endpoint=$(get_cri_socket)
    log_info "Configuring crictl at /etc/crictl.yaml (endpoint: $endpoint)"
    cat > /etc/crictl.yaml <<EOF
runtime-endpoint: $endpoint
image-endpoint: $endpoint
timeout: 10
debug: false
pull-image-on-create: false
EOF
}

# Helper: Auto-detect kubeadm and KubeProxy API versions from kubeadm defaults
# Caches output to avoid duplicate subprocess calls.
_KUBEADM_DEFAULTS_CACHE=""
_kubeadm_defaults() {
    if [ -z "$_KUBEADM_DEFAULTS_CACHE" ]; then
        _KUBEADM_DEFAULTS_CACHE=$(kubeadm config print init-defaults 2>/dev/null) || true
    fi
    echo "$_KUBEADM_DEFAULTS_CACHE"
}

_kubeadm_api_version() {
    local api_ver
    api_ver=$(_kubeadm_defaults | awk '/^apiVersion: kubeadm\.k8s\.io\// {print $2; exit}')
    if [ -z "$api_ver" ]; then
        log_warn "Could not detect kubeadm API version, using default: kubeadm.k8s.io/v1beta3"
        api_ver="kubeadm.k8s.io/v1beta3"
    fi
    echo "$api_ver"
}

_kubeproxy_api_version() {
    local api_ver
    api_ver=$(_kubeadm_defaults | awk '/^apiVersion: kubeproxy\.config\.k8s\.io\// {print $2; exit}')
    if [ -z "$api_ver" ]; then
        log_warn "Could not detect KubeProxy API version, using default: kubeproxy.config.k8s.io/v1alpha1"
        api_ver="kubeproxy.config.k8s.io/v1alpha1"
    fi
    echo "$api_ver"
}

_kubelet_api_version() {
    local api_ver
    api_ver=$(_kubeadm_defaults | awk '/^apiVersion: kubelet\.config\.k8s\.io\// {print $2; exit}')
    if [ -z "$api_ver" ]; then
        api_ver="kubelet.config.k8s.io/v1beta1"
    fi
    echo "$api_ver"
}

# Helper: Generate kubeadm configuration
generate_kubeadm_config() {
    local config_file
    config_file=$(mktemp -t kubeadm-config-XXXXXX.yaml)
    chmod 600 "$config_file"

    log_info "Generating kubeadm configuration..."

    # Use pre-parsed kubeadm variables (set by parse_setup_args / validate_ha_args)
    local POD_CIDR="$KUBEADM_POD_CIDR"
    local SERVICE_CIDR="$KUBEADM_SERVICE_CIDR"
    local API_ADDR="$KUBEADM_API_ADDR"
    local CP_ENDPOINT="$KUBEADM_CP_ENDPOINT"

    # Auto-detect API versions
    local kubeadm_api kubeproxy_api
    kubeadm_api=$(_kubeadm_api_version)
    kubeproxy_api=$(_kubeproxy_api_version)

    # InitConfiguration
    cat > "$config_file" <<EOF
apiVersion: $kubeadm_api
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
apiVersion: $kubeadm_api
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
apiVersion: $kubeproxy_api
kind: KubeProxyConfiguration
mode: ipvs
ipvs:
  scheduler: "rr"
  strictARP: true
EOF
    elif [ "$PROXY_MODE" = "nftables" ]; then
        cat >> "$config_file" <<EOF
---
apiVersion: $kubeproxy_api
kind: KubeProxyConfiguration
mode: nftables
EOF
    fi

    if [ "$SWAP_ENABLED" = true ]; then
        local kubelet_api
        kubelet_api=$(_kubelet_api_version)
        cat >> "$config_file" <<EOF
---
apiVersion: $kubelet_api
kind: KubeletConfiguration
failSwapOn: false
memorySwap:
  swapBehavior: LimitedSwap
EOF
    fi

    echo "$config_file"
}

# Helper: Configure kubectl for a user after kubeadm init/join
_configure_kubectl() {
    log_info "Configuring kubectl..."
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local USER_HOME
        USER_HOME=$(get_user_home "$SUDO_USER")
        mkdir -p "$USER_HOME/.kube"
        cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
        chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$USER_HOME/.kube"
        log_info "Created kubectl configuration for user $SUDO_USER"
    else
        mkdir -p /root/.kube
        cp -f /etc/kubernetes/admin.conf /root/.kube/config
        log_info "Created kubectl configuration for root user at /root/.kube/config"
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
      value: "$(_is_ipv6 "$vip" && echo "128" || echo "32")"
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
    local inet_keyword="inet"
    local vip_prefix="32"
    if _is_ipv6 "$vip"; then
        inet_keyword="inet6"
        vip_prefix="128"
    fi
    if ip addr show dev "$iface" 2>/dev/null | grep -q "${inet_keyword} ${vip}/"; then
        log_info "Rolling back pre-added VIP $vip from $iface..."
        local _vip_err
        if ! _vip_err=$(ip addr del "${vip}/${vip_prefix}" dev "$iface" 2>&1); then
            log_warn "VIP rollback failed: $_vip_err"
        fi
    fi
}

# Helper: Verify kube-vip kubeconfig file exists after kubeadm init/join.
# If the expected file doesn't exist, patch the manifest to use admin.conf.
_verify_kube_vip_kubeconfig() {
    local expected_path
    expected_path=$(_kube_vip_kubeconfig_path)
    if [ ! -f "$expected_path" ]; then
        log_warn "Expected kubeconfig $expected_path not found"
        if [ "$expected_path" != "/etc/kubernetes/admin.conf" ] && [ -f "/etc/kubernetes/admin.conf" ]; then
            log_info "Patching kube-vip manifest to use /etc/kubernetes/admin.conf instead..."
            if ! sed -i "s|path: ${expected_path}|path: /etc/kubernetes/admin.conf|" \
                /etc/kubernetes/manifests/kube-vip.yaml; then
                log_warn "Failed to patch kube-vip manifest; kube-vip may use incorrect kubeconfig path"
            fi
        fi
    fi
}

deploy_kube_vip() {
    local skip_vip_preadd=false
    if [ "${1:-}" = "--skip-vip-preadd" ]; then
        skip_vip_preadd=true
        shift
    fi

    local vip="$HA_VIP_ADDRESS"
    local iface="$HA_VIP_INTERFACE"
    local kube_vip_image="ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}"
    local manifest_dir="/etc/kubernetes/manifests"
    local kubeconfig_path
    kubeconfig_path=$(_kube_vip_kubeconfig_path)

    log_info "Deploying kube-vip for HA (VIP=$vip, interface=$iface)..."
    log_info "  kubeconfig: $kubeconfig_path"
    mkdir -p "$manifest_dir"

    # Pull image based on CRI
    if [ "$CRI" = "crio" ]; then
        log_info "Pulling kube-vip image via crictl..."
        crictl pull "$kube_vip_image"
    else
        log_info "Pulling kube-vip image via ctr..."
        ctr image pull "$kube_vip_image"
    fi

    # Generate manifest from unified template (same for all CRIs)
    _generate_kube_vip_manifest "$vip" "$iface" "$kube_vip_image" "$kubeconfig_path" \
        > "${manifest_dir}/kube-vip.yaml"

    log_info "kube-vip manifest written to ${manifest_dir}/kube-vip.yaml"

    # Pre-add VIP to the interface so it is reachable during kubeadm init
    # before kube-vip can perform leader election.
    # On join nodes, skip pre-add to avoid VIP conflicts with the existing leader.
    local inet_keyword="inet"
    local vip_prefix="32"
    if _is_ipv6 "$vip"; then
        inet_keyword="inet6"
        vip_prefix="128"
    fi
    if [ "$skip_vip_preadd" = false ]; then
        if ! ip addr show dev "$iface" | grep -q "${inet_keyword} ${vip}/"; then
            log_info "Pre-adding VIP $vip to $iface for bootstrap..."
            ip addr add "${vip}/${vip_prefix}" dev "$iface"
        fi
    else
        log_info "Skipping VIP pre-add (join mode, VIP managed by existing leader)"
    fi
}

# Helper: Initialize Kubernetes cluster
initialize_cluster() {
    log_info "Initializing cluster..."

    # Deploy kube-vip before kubeadm init if HA is enabled
    if [ "$HA_ENABLED" = true ]; then
        deploy_kube_vip
    fi

    # Run kubeadm init, capturing exit code for rollback
    local init_exit=0
    if [ "$PROXY_MODE" != "iptables" ] || [ -n "$KUBEADM_POD_CIDR" ] || \
       [ -n "$KUBEADM_SERVICE_CIDR" ] || [ -n "$KUBEADM_API_ADDR" ] || \
       [ -n "$KUBEADM_CP_ENDPOINT" ] || [ "$SWAP_ENABLED" = true ]; then
        local CONFIG_FILE
        if ! CONFIG_FILE=$(generate_kubeadm_config); then
            log_error "Failed to generate kubeadm configuration"
            if [ "$HA_ENABLED" = true ]; then
                _rollback_vip
            fi
            return 1
        fi
        log_info "Using kubeadm configuration file: $CONFIG_FILE"
        # shellcheck disable=SC2046 # intentional word splitting
        kubeadm init --config "$CONFIG_FILE" $(_kubeadm_preflight_ignore_args) || init_exit=$?
        rm -f "$CONFIG_FILE"
    else
        if [ "$CRI" != "containerd" ]; then
            local cri_socket
            cri_socket=$(get_cri_socket)
            # shellcheck disable=SC2046 # intentional word splitting
            kubeadm init --cri-socket "$cri_socket" $(_kubeadm_preflight_ignore_args) || init_exit=$?
        else
            # shellcheck disable=SC2046 # intentional word splitting
            kubeadm init $(_kubeadm_preflight_ignore_args) || init_exit=$?
        fi
    fi

    if [ "$init_exit" -ne 0 ]; then
        log_error "kubeadm init failed (exit code: $init_exit)"
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
    log_info "Displaying join command for worker nodes..."
    kubeadm token create --print-join-command

    # For HA clusters, upload certs and display control-plane join command
    if [ "$HA_ENABLED" = true ]; then
        log_info ""
        log_info "=== HA Cluster: Control-Plane Join Information ==="
        local cert_output cert_key
        if ! cert_output=$(kubeadm init phase upload-certs --upload-certs); then
            log_warn "kubeadm upload-certs failed (cluster init succeeded)"
            log_warn "You can manually run: kubeadm init phase upload-certs --upload-certs"
            return 0
        fi
        cert_key=$(echo "$cert_output" | tail -1)
        if ! [[ "$cert_key" =~ ^[a-f0-9]{64}$ ]]; then
            log_error "Invalid certificate key format (expected 64 hex chars, got: '$cert_key')"
            return 1
        fi
        log_info "Certificate key: $cert_key"
        log_info ""
        log_info "To join additional control-plane nodes, run:"
        log_info "  setup-k8s.sh join --control-plane --certificate-key $cert_key \\"
        log_info "    --ha-vip ${HA_VIP_ADDRESS} \\"
        log_info "    --join-token <token> --join-address <address> --discovery-token-hash <hash>"
        log_info "================================================="
    fi

    log_info "Cluster initialization complete!"
    log_info "Next steps:"
    log_info "1. Install a CNI plugin"
    log_info "2. For single-node clusters, remove the taint with:"
    log_info "   kubectl taint nodes --all node-role.kubernetes.io/control-plane-"
}

# Helper: Join node to cluster
join_cluster() {
    log_info "Joining node to cluster..."

    # Deploy kube-vip on additional control-plane nodes
    # Skip VIP pre-add to avoid conflicts with the existing VIP leader
    if [ "${JOIN_AS_CONTROL_PLANE:-false}" = true ] && [ -n "$HA_VIP_ADDRESS" ]; then
        deploy_kube_vip --skip-vip-preadd
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
    # shellcheck disable=SC2046 # intentional word splitting
    kubeadm join "${join_args[@]}" $(_kubeadm_preflight_ignore_args) || join_exit=$?

    if [ "$join_exit" -ne 0 ]; then
        log_error "kubeadm join failed (exit code: $join_exit)"
        return "$join_exit"
    fi

    # Verify kube-vip kubeconfig exists for control-plane join
    if [ "${JOIN_AS_CONTROL_PLANE:-false}" = true ] && [ -n "$HA_VIP_ADDRESS" ]; then
        _verify_kube_vip_kubeconfig
    fi

    # Configure kubectl for control-plane join
    if [ "${JOIN_AS_CONTROL_PLANE:-false}" = true ]; then
        _configure_kubectl
        log_info "Control-plane node has joined the cluster!"
    else
        log_info "Worker node has joined the cluster!"
    fi
}

# Helper: Clean up .kube directories
cleanup_kube_configs() {
    # Clean up .kube directory
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local USER_HOME
        USER_HOME=$(get_user_home "$SUDO_USER")
        log_info "Cleanup: Removing .kube directory and config for user $SUDO_USER"
        rm -f "$USER_HOME/.kube/config"
        rmdir "$USER_HOME/.kube" 2>/dev/null || true
    fi

    # Clean up root's .kube directory
    local ROOT_HOME
    ROOT_HOME=$(get_user_home root)
    log_info "Cleanup: Removing .kube directory and config for root user at $ROOT_HOME"
    rm -f "$ROOT_HOME/.kube/config"
    rmdir "$ROOT_HOME/.kube" 2>/dev/null || true
}

# Helper: Reset containerd configuration
reset_containerd_config() {
    if [ -f /etc/containerd/config.toml ]; then
        log_info "Resetting containerd configuration to default..."
        if command -v containerd &> /dev/null; then
            # Backup current config
            if ! cp /etc/containerd/config.toml "/etc/containerd/config.toml.bak.$(date +%Y%m%d%H%M%S)"; then
                log_warn "Failed to backup containerd config"
                return 1
            fi
            # Generate default config
            if ! containerd config default > /etc/containerd/config.toml; then
                log_warn "Failed to generate default containerd config"
                return 1
            fi
            # Restart containerd if it's running
            if _service_is_active containerd; then
                log_info "Restarting containerd with default configuration..."
                _service_restart containerd
            fi
        fi
    fi
}

# Show installed versions
show_versions() {
    log_info "Installed versions:"
    log_info "  $(kubectl version --client 2>&1)"
    log_info "  $(kubeadm version 2>&1)"
}

# Unified cleanup verification: check remaining files and report.
# Usage: _verify_cleanup <remaining_from_pkg_check> <file1> [file2] ...
_verify_cleanup() {
    local remaining="$1"; shift
    log_info "Verifying cleanup..."
    for file in "$@"; do
        if [ -f "$file" ]; then
            log_warn "File still exists: $file"
            remaining=1
        fi
    done
    if [ "$remaining" -ne 0 ]; then
        log_warn "Some files or packages could not be removed. You may want to remove them manually."
        return 1
    fi
    log_info "All specified components have been successfully removed."
}

# === Cleanup helper functions ===

# Stop Kubernetes services
stop_kubernetes_services() {
    log_info "Stopping Kubernetes services..."
    _service_stop kubelet
    _service_disable kubelet
    # Verify kubelet is actually stopped
    if _service_is_active kubelet; then
        log_error "kubelet is still active after stop attempt"
        return 1
    fi
}

# Stop CRI services
stop_cri_services() {
    log_info "Checking and stopping CRI services..."

    # Stop CRI-O if present
    local _crio_found=false
    case "$(_detect_init_system)" in
        systemd) systemctl list-unit-files 2>/dev/null | grep -q '^crio\.service' && _crio_found=true ;;
        openrc)  [ -f /etc/init.d/crio ] && _crio_found=true ;;
    esac
    if [ "$_crio_found" = true ]; then
        log_info "Stopping and disabling CRI-O service..."
        _service_stop crio
        _service_disable crio
        if _service_is_active crio; then
            log_warn "CRI-O is still active after stop attempt"
            return 1
        fi
    fi

    # Note: containerd is not stopped to avoid impacting Docker
    # Only its configuration will be reset later with reset_containerd_config()
}

# Remove Kubernetes configuration files
remove_kubernetes_configs() {
    log_info "Removing Kubernetes configuration files..."
    rm -f /etc/default/kubelet
    rm -rf /etc/kubernetes
    rm -rf /etc/systemd/system/kubelet.service.d
}

# Reset Kubernetes cluster state
reset_kubernetes_cluster() {
    if command -v kubeadm &> /dev/null; then
        log_info "Resetting kubeadm cluster state..."
        if ! kubeadm reset -f; then
            log_error "kubeadm reset failed"
            return 1
        fi
    fi
}

# Common pre-cleanup steps shared by all distributions
cleanup_pre_common() {
    log_info "Resetting cluster state..."
    kubeadm reset -f || true
    cleanup_cni
}

# Conditionally cleanup CNI
cleanup_cni_conditionally() {
    if [ "$PRESERVE_CNI" = false ]; then
        cleanup_cni
    else
        log_info "Preserving CNI configurations as requested."
    fi
}
