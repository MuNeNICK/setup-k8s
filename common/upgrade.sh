#!/bin/bash

# Upgrade module: version helpers, local upgrade, and remote orchestration

# --- Version Helpers ---

# Extract MAJOR.MINOR from MAJOR.MINOR.PATCH
_version_minor() {
    echo "$1" | cut -d. -f1,2
}

# Get current kubeadm version as MAJOR.MINOR.PATCH
_get_current_k8s_version() {
    kubeadm version -o short | sed 's/^v//'
}

# Validate upgrade version constraints
# - No downgrade
# - No minor version skip (target minor <= current minor + 1)
# - Target must differ from current
_validate_upgrade_version() {
    local current="$1" target="$2"
    local cur_major cur_minor cur_patch tar_major tar_minor tar_patch
    cur_major=$(echo "$current" | cut -d. -f1)
    cur_minor=$(echo "$current" | cut -d. -f2)
    cur_patch=$(echo "$current" | cut -d. -f3)
    tar_major=$(echo "$target" | cut -d. -f1)
    tar_minor=$(echo "$target" | cut -d. -f2)
    tar_patch=$(echo "$target" | cut -d. -f3)

    # Same version
    if [ "$cur_major" -eq "$tar_major" ] && [ "$cur_minor" -eq "$tar_minor" ] && [ "$cur_patch" -eq "$tar_patch" ]; then
        log_error "Current version ($current) is already at target version ($target)"
        return 1
    fi

    # Downgrade check
    if [ "$tar_major" -lt "$cur_major" ]; then
        log_error "Downgrade not supported: $current -> $target"
        return 1
    fi
    if [ "$tar_major" -eq "$cur_major" ] && [ "$tar_minor" -lt "$cur_minor" ]; then
        log_error "Downgrade not supported: $current -> $target"
        return 1
    fi
    if [ "$tar_major" -eq "$cur_major" ] && [ "$tar_minor" -eq "$cur_minor" ] && [ "$tar_patch" -lt "$cur_patch" ]; then
        log_error "Downgrade not supported: $current -> $target"
        return 1
    fi

    # Minor version skip check (only +1 minor allowed)
    if [ "$tar_major" -eq "$cur_major" ] && [ "$tar_minor" -gt $((cur_minor + 1)) ]; then
        log_error "Cannot skip minor versions: $current -> $target (max +1 minor version at a time)"
        return 1
    fi

    # Major version jump
    if [ "$tar_major" -gt "$cur_major" ]; then
        log_error "Major version upgrade not supported: $current -> $target"
        return 1
    fi

    return 0
}

# --- Node Role Detection ---

# Detect whether this node is a control-plane or worker
_detect_node_role() {
    if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
        if [ "$UPGRADE_FIRST_CONTROL_PLANE" = true ]; then
            echo "first-control-plane"
        else
            echo "control-plane"
        fi
    else
        echo "worker"
    fi
}

# --- Local Upgrade ---

# Upgrade the current node (run with sudo)
upgrade_node_local() {
    local role current_version
    role=$(_detect_node_role)
    current_version=$(_get_current_k8s_version)
    _validate_upgrade_version "$current_version" "$UPGRADE_TARGET_VERSION"

    local minor_version
    minor_version=$(_version_minor "$UPGRADE_TARGET_VERSION")
    # shellcheck disable=SC2034 # K8S_VERSION used by distro functions for repo URLs
    K8S_VERSION="$minor_version"

    log_info "Upgrading node (role: $role) from v${current_version} to v${UPGRADE_TARGET_VERSION}..."

    # 1. Upgrade kubeadm package
    log_info "Step 1: Upgrading kubeadm to ${UPGRADE_TARGET_VERSION}..."
    _dispatch "upgrade_kubeadm_${DISTRO_FAMILY}" "$UPGRADE_TARGET_VERSION"

    # 2. Run kubeadm upgrade
    if [ "$role" = "first-control-plane" ]; then
        log_info "Step 2: Running kubeadm upgrade apply v${UPGRADE_TARGET_VERSION}..."
        local _preflight_errors="ControlPlaneNodesReady,CreateJob"
        if [ "$(_detect_init_system)" != "systemd" ]; then
            _preflight_errors="${_preflight_errors},SystemVerification"
        fi
        kubeadm upgrade apply "v${UPGRADE_TARGET_VERSION}" --yes --ignore-preflight-errors="${_preflight_errors}"
    else
        log_info "Step 2: Running kubeadm upgrade node..."
        # On workers, the default kubelet kubeconfig may lack permissions to read
        # kubeadm-config ConfigMap (NodeRestriction). Use admin.conf if available,
        # or a temporarily transferred copy set via UPGRADE_ADMIN_CONF.
        local _kubeconfig_arg=""
        if [ -f /etc/kubernetes/admin.conf ]; then
            _kubeconfig_arg="--kubeconfig /etc/kubernetes/admin.conf"
        elif [ -n "${UPGRADE_ADMIN_CONF:-}" ] && [ -f "${UPGRADE_ADMIN_CONF}" ]; then
            _kubeconfig_arg="--kubeconfig ${UPGRADE_ADMIN_CONF}"
        fi
        # shellcheck disable=SC2086,SC2046 # intentional word splitting
        kubeadm upgrade node $_kubeconfig_arg $(_kubeadm_preflight_ignore_args)
    fi

    # 3. Upgrade kubelet + kubectl packages
    log_info "Step 3: Upgrading kubelet and kubectl to ${UPGRADE_TARGET_VERSION}..."
    _dispatch "upgrade_kubelet_kubectl_${DISTRO_FAMILY}" "$UPGRADE_TARGET_VERSION"

    # 4. Restart kubelet
    log_info "Step 4: Restarting kubelet..."
    _service_reload
    if ! _service_restart kubelet; then
        log_warn "kubelet restart returned non-zero. It may take a moment to stabilize."
    fi

    show_versions
    log_info "Node upgrade complete (role: $role)!"
}

# --- Remote Orchestration ---

# Show dry-run upgrade plan
upgrade_dry_run() {
    log_info "=== Upgrade Dry-Run Plan ==="
    log_info ""
    log_info "Target Version: ${UPGRADE_TARGET_VERSION}"
    log_info ""

    IFS=',' read -ra cp_nodes <<< "$DEPLOY_CONTROL_PLANES"
    log_info "Control-Plane Nodes (${#cp_nodes[@]}):"
    for node in "${cp_nodes[@]}"; do
        _parse_node_address "$node"
        log_info "  - ${_NODE_USER}@${_NODE_HOST}"
    done
    log_info ""

    if [ -n "$DEPLOY_WORKERS" ]; then
        IFS=',' read -ra w_nodes <<< "$DEPLOY_WORKERS"
        log_info "Worker Nodes (${#w_nodes[@]}):"
        for node in "${w_nodes[@]}"; do
            _parse_node_address "$node"
            log_info "  - ${_NODE_USER}@${_NODE_HOST}"
        done
    else
        log_info "Worker Nodes: (none)"
    fi
    log_info ""

    log_info "SSH Settings:"
    log_info "  Default user: $DEPLOY_SSH_USER"
    log_info "  Port: $DEPLOY_SSH_PORT"
    [ -n "$DEPLOY_SSH_KEY" ] && log_info "  Key: $DEPLOY_SSH_KEY"
    [ -n "$DEPLOY_SSH_PASSWORD" ] && log_info "  Auth: password (sshpass)"
    log_info ""

    log_info "Orchestration Plan:"
    log_info "  1. Generate bundle (all modules -> single file)"
    log_info "  2. Check SSH connectivity to all nodes"
    log_info "  3. Transfer bundle to all nodes"
    log_info "  4. Get current version from first CP"
    log_info "  5. Run kubeadm upgrade plan (informational)"
    local step=5
    log_info "  $((++step)). Upgrade control-planes (sequential):"
    for ((i=0; i<${#cp_nodes[@]}; i++)); do
        if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
            log_info "     - drain ${cp_nodes[$i]}"
        fi
        log_info "     - upgrade ${cp_nodes[$i]}$([ $i -eq 0 ] && echo ' (--first-control-plane)')"
        if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
            log_info "     - uncordon ${cp_nodes[$i]}"
        fi
    done
    if [ -n "$DEPLOY_WORKERS" ]; then
        IFS=',' read -ra w_nodes <<< "$DEPLOY_WORKERS"
        log_info "  $((++step)). Upgrade workers (sequential):"
        for node in "${w_nodes[@]}"; do
            if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
                log_info "     - drain $node"
            fi
            log_info "     - upgrade $node"
            if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
                log_info "     - uncordon $node"
            fi
        done
    fi
    log_info "  $((++step)). Verify: kubectl get nodes"
    log_info "  $((++step)). Show summary"
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# Main upgrade orchestration (remote mode)
upgrade_cluster() {
    IFS=',' read -ra cp_nodes <<< "$DEPLOY_CONTROL_PLANES"
    local -a w_nodes=()
    if [ -n "$DEPLOY_WORKERS" ]; then
        IFS=',' read -ra w_nodes <<< "$DEPLOY_WORKERS"
    fi

    log_info "Upgrading Kubernetes cluster to v${UPGRADE_TARGET_VERSION}: ${#cp_nodes[@]} control-plane(s), ${#w_nodes[@]} worker(s)"

    # Inform about SSH host key policy
    if [ "${DEPLOY_SSH_HOST_KEY_CHECK}" = "yes" ] && [ -z "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        log_info "SSH strict host key checking is enabled."
        log_info "Provide known_hosts with --ssh-known-hosts to proceed:"
        log_info "  ssh-keyscan -H <node-ip> >> known_hosts"
        log_info "  setup-k8s.sh upgrade --ssh-known-hosts known_hosts ..."
    elif [ "${DEPLOY_SSH_HOST_KEY_CHECK}" = "accept-new" ]; then
        log_info "SSH host key check: accept-new (TOFU)."
    fi

    # Create session-scoped known_hosts
    if [ -n "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ] && [ -f "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        _DEPLOY_KNOWN_HOSTS=$(mktemp -t upgrade-known-hosts-XXXXXX)
        chmod 600 "$_DEPLOY_KNOWN_HOSTS"
        cp "$DEPLOY_SSH_KNOWN_HOSTS_FILE" "$_DEPLOY_KNOWN_HOSTS"
    else
        _DEPLOY_KNOWN_HOSTS=$(mktemp -t upgrade-known-hosts-XXXXXX)
        chmod 600 "$_DEPLOY_KNOWN_HOSTS"
    fi
    _cleanup_upgrade_known_hosts() { rm -f "$_DEPLOY_KNOWN_HOSTS"; }
    _push_cleanup _cleanup_upgrade_known_hosts

    local _step=0

    # --- Step 1: Generate bundle ---
    log_info "Step $((_step+=1)): Generating upgrade bundle..."
    local bundle_path
    bundle_path=$(mktemp -t setup-k8s-upgrade-XXXXXX.sh)
    chmod 600 "$bundle_path"
    generate_deploy_bundle "$bundle_path"
    log_info "Bundle generated: $(wc -c < "$bundle_path") bytes"

    # --- Step 2: SSH connectivity check ---
    log_info "Step $((_step+=1)): Checking SSH connectivity to all nodes..."
    local ssh_failed=false
    _DEPLOY_ALL_NODES=("${cp_nodes[@]}" "${w_nodes[@]}")
    for node in "${_DEPLOY_ALL_NODES[@]}"; do
        _parse_node_address "$node"
        local _ssh_err
        if _ssh_err=$(_deploy_ssh "$_NODE_USER" "$_NODE_HOST" "echo ok" 2>&1 >/dev/null); then
            log_info "  [${_NODE_HOST}] SSH OK"
            if [ "$_NODE_USER" != "root" ]; then
                local _sudo_err
                if ! _sudo_err=$(_deploy_ssh "$_NODE_USER" "$_NODE_HOST" "sudo -n true" 2>&1); then
                    log_error "  [${_NODE_HOST}] sudo -n failed -- NOPASSWD sudo required for ${_NODE_USER}"
                    [ -n "$_sudo_err" ] && log_error "  [${_NODE_HOST}] ${_sudo_err}"
                    ssh_failed=true
                fi
            fi
        else
            log_error "  [${_NODE_HOST}] SSH connection failed (${_NODE_USER}@${_NODE_HOST}:${DEPLOY_SSH_PORT})"
            [ -n "$_ssh_err" ] && log_error "  [${_NODE_HOST}] ${_ssh_err}"
            ssh_failed=true
        fi
    done
    if [ "$ssh_failed" = true ]; then
        log_error "SSH connectivity check failed. Aborting upgrade."
        rm -f "$bundle_path"
        return 1
    fi

    # --- Step 3: Transfer bundle to all nodes ---
    log_info "Step $((_step+=1)): Transferring bundle to all nodes..."
    _DEPLOY_NODE_BUNDLE_DIRS=()
    _cleanup_upgrade_remote_dirs() {
        for _cleanup_node in "${_DEPLOY_ALL_NODES[@]}"; do
            _parse_node_address "$_cleanup_node"
            local _cdir="${_DEPLOY_NODE_BUNDLE_DIRS[$_NODE_HOST]:-}"
            [ -n "$_cdir" ] && _deploy_ssh "$_NODE_USER" "$_NODE_HOST" "rm -rf '$_cdir'" >/dev/null 2>&1 || true
        done
    }
    _push_cleanup _cleanup_upgrade_remote_dirs

    for node in "${_DEPLOY_ALL_NODES[@]}"; do
        _parse_node_address "$node"
        log_info "  [${_NODE_HOST}] Transferring bundle..."
        local rdir
        rdir=$(_deploy_ssh "$_NODE_USER" "$_NODE_HOST" "d=\$(mktemp -d) && chmod 700 \"\$d\" && echo \"\$d\"") || true
        rdir=$(echo "$rdir" | tr -d '[:space:]')
        if [ -z "$rdir" ] || [[ "$rdir" != /* ]]; then
            log_error "  [${_NODE_HOST}] Failed to create remote temp directory (got: '${rdir}')"
            rm -f "$bundle_path"
            return 1
        fi
        # shellcheck disable=SC2004 # associative array key, not arithmetic
        _DEPLOY_NODE_BUNDLE_DIRS[${_NODE_HOST}]="$rdir"
        if ! _deploy_scp "$bundle_path" "$_NODE_USER" "$_NODE_HOST" "${rdir}/setup-k8s.sh"; then
            log_error "  [${_NODE_HOST}] Failed to transfer bundle"
            rm -f "$bundle_path"
            return 1
        fi
    done
    rm -f "$bundle_path"
    log_info "Bundle transferred to all nodes"

    # --- Step 4: Get current version from first CP ---
    log_info "Step $((_step+=1)): Checking current cluster version..."
    _parse_node_address "${cp_nodes[0]}"
    local cp1_user="$_NODE_USER" cp1_host="$_NODE_HOST"
    local sudo_pfx=""
    [ "$cp1_user" != "root" ] && sudo_pfx="sudo -n "

    local current_version
    current_version=$(_deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}kubeadm version -o short" | sed 's/^v//' | tr -d '[:space:]')
    if [ -z "$current_version" ]; then
        log_error "Failed to get current Kubernetes version from ${cp1_host}"
        return 1
    fi
    log_info "Current cluster version: v${current_version}"
    log_info "Target version: v${UPGRADE_TARGET_VERSION}"

    # Validate version constraints
    _validate_upgrade_version "$current_version" "$UPGRADE_TARGET_VERSION"

    # --- Step 5: Run kubeadm upgrade plan (informational) ---
    log_info "Step $((_step+=1)): Running kubeadm upgrade plan..."
    local plan_output
    plan_output=$(_deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}kubeadm upgrade plan" 2>&1) || true
    log_info "$plan_output"

    # Helper: get node name from host IP/hostname via kubectl
    # Tries: 1) match by InternalIP address, 2) match by hostname, 3) SSH to target and get its hostname
    _get_node_name() {
        local user="$1" host="$2" target_host="$3"
        local pfx=""
        [ "$user" != "root" ] && pfx="sudo -n "
        local node_name=""
        local stripped="${target_host#[}"
        stripped="${stripped%]}"

        # Try matching by InternalIP or Hostname address
        local nodes_info
        nodes_info=$(_deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{range .status.addresses[*]}{.address}{\" \"}{end}{\"\\n\"}{end}'" 2>/dev/null) || true
        if [ -n "$nodes_info" ]; then
            node_name=$(echo "$nodes_info" | while read -r name addrs; do
                for addr in $addrs; do
                    if [ "$addr" = "$stripped" ] || [ "$addr" = "$target_host" ]; then
                        echo "$name"
                        return 0
                    fi
                done
            done)
        fi

        # Fallback: SSH to the target node and get its hostname, then match against node names
        if [ -z "$node_name" ]; then
            _parse_node_address "$target_host"
            local target_user="$_NODE_USER" target_actual_host="$_NODE_HOST"
            # For bare IPs passed as target_host, re-parse with the original node address
            # Find the matching node from _DEPLOY_ALL_NODES
            for _node_entry in "${_DEPLOY_ALL_NODES[@]}"; do
                local _check_host="${_node_entry#*@}"
                if [ "$_check_host" = "$target_host" ] || [ "$_check_host" = "$stripped" ]; then
                    _parse_node_address "$_node_entry"
                    target_user="$_NODE_USER"
                    target_actual_host="$_NODE_HOST"
                    break
                fi
            done
            local remote_hostname
            remote_hostname=$(_deploy_ssh "$target_user" "$target_actual_host" "hostname" 2>/dev/null | tr -d '[:space:]') || true
            if [ -n "$remote_hostname" ] && [ -n "$nodes_info" ]; then
                node_name=$(echo "$nodes_info" | while read -r name _addrs; do
                    if [ "$name" = "$remote_hostname" ]; then
                        echo "$name"
                        return 0
                    fi
                done)
            fi
        fi

        echo "$node_name"
    }

    # Helper: drain a node
    _upgrade_drain_node() {
        local user="$1" host="$2" node_name="$3"
        local pfx=""
        [ "$user" != "root" ] && pfx="sudo -n "
        log_info "  [${node_name}] Draining node..."
        if ! _deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf drain '$node_name' --ignore-daemonsets --delete-emptydir-data --timeout=300s"; then
            log_error "  [${node_name}] Drain failed"
            return 1
        fi
        log_info "  [${node_name}] Node drained"
    }

    # Helper: uncordon a node
    _upgrade_uncordon_node() {
        local user="$1" host="$2" node_name="$3"
        local pfx=""
        [ "$user" != "root" ] && pfx="sudo -n "
        log_info "  [${node_name}] Uncordoning node..."
        if ! _deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf uncordon '$node_name'"; then
            log_error "  [${node_name}] Uncordon failed"
            return 1
        fi
        log_info "  [${node_name}] Node uncordoned"
    }

    # --- Step 6: Upgrade control-plane nodes (sequential) ---
    log_info "Step $((_step+=1)): Upgrading control-plane nodes..."
    local upgrade_failed=false

    for ((i=0; i<${#cp_nodes[@]}; i++)); do
        _parse_node_address "${cp_nodes[$i]}"
        local node_user="$_NODE_USER" node_host="$_NODE_HOST"
        local node_bundle="${_DEPLOY_NODE_BUNDLE_DIRS[$node_host]}/setup-k8s.sh"
        local node_sudo=""
        [ "$node_user" != "root" ] && node_sudo="sudo -n "

        # Get node name for drain/uncordon
        local node_name
        node_name=$(_get_node_name "$cp1_user" "$cp1_host" "$node_host")
        if [ -z "$node_name" ]; then
            log_warn "Could not resolve node name for ${node_host}, using host as node name"
            node_name="$node_host"
        fi

        # Drain (unless skipped)
        if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
            if ! _upgrade_drain_node "$cp1_user" "$cp1_host" "$node_name"; then
                log_error "Drain failed for ${node_host}. Stopping upgrade."
                upgrade_failed=true
                break
            fi
        fi

        # Build upgrade command
        local upgrade_cmd
        upgrade_cmd="${node_sudo}bash ${node_bundle} upgrade --kubernetes-version $(printf '%q' "$UPGRADE_TARGET_VERSION")"
        if [ $i -eq 0 ]; then
            upgrade_cmd+=" --first-control-plane"
        fi
        # Forward extra passthrough args (e.g. --distro)
        local _pt_skip_next=false
        local _pt_idx
        for ((_pt_idx=0; _pt_idx<${#UPGRADE_PASSTHROUGH_ARGS[@]}; _pt_idx++)); do
            if [ "$_pt_skip_next" = true ]; then _pt_skip_next=false; continue; fi
            case "${UPGRADE_PASSTHROUGH_ARGS[$_pt_idx]}" in
                --kubernetes-version) _pt_skip_next=true ;; # skip flag + value
                --skip-drain) ;;
                *) upgrade_cmd+=" $(printf '%q' "${UPGRADE_PASSTHROUGH_ARGS[$_pt_idx]}")" ;;
            esac
        done

        if ! _deploy_exec_remote "$node_user" "$node_host" "upgrade control-plane" "$upgrade_cmd"; then
            log_error "Upgrade failed for ${node_host}. Node may be in cordoned state."
            upgrade_failed=true
            break
        fi

        # Uncordon
        if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
            if ! _upgrade_uncordon_node "$cp1_user" "$cp1_host" "$node_name"; then
                log_warn "Uncordon failed for ${node_host}. Continuing..."
            fi
        fi

        log_info "  [${node_host}] Control-plane upgrade complete"
    done

    if [ "$upgrade_failed" = true ]; then
        log_error "Control-plane upgrade failed. Check logs above for details."
        log_error "Some nodes may be in mixed-version state (this is allowed by K8s skew policy)."
        _cleanup_upgrade_remote_dirs
        _pop_cleanup
        return 1
    fi

    # --- Step 7: Upgrade worker nodes (sequential) ---
    if [ ${#w_nodes[@]} -gt 0 ]; then
        log_info "Step $((_step+=1)): Upgrading worker nodes..."

        for node in "${w_nodes[@]}"; do
            _parse_node_address "$node"
            local node_user="$_NODE_USER" node_host="$_NODE_HOST"
            local node_bundle="${_DEPLOY_NODE_BUNDLE_DIRS[$node_host]}/setup-k8s.sh"
            local node_sudo=""
            [ "$node_user" != "root" ] && node_sudo="sudo -n "

            # Get node name
            local node_name
            node_name=$(_get_node_name "$cp1_user" "$cp1_host" "$node_host")
            if [ -z "$node_name" ]; then
                log_warn "Could not resolve node name for ${node_host}, using host as node name"
                node_name="$node_host"
            fi

            # Drain
            if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
                if ! _upgrade_drain_node "$cp1_user" "$cp1_host" "$node_name"; then
                    log_error "Drain failed for ${node_host}. Stopping worker upgrades."
                    upgrade_failed=true
                    break
                fi
            fi

            # Transfer admin.conf from CP to worker (workers lack admin kubeconfig,
            # and kubelet's kubeconfig may be denied by NodeRestriction)
            local remote_admin_conf="/tmp/upgrade-admin.conf"
            local tmp_admin_conf
            tmp_admin_conf=$(mktemp -t admin-conf-XXXXXX)
            _deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}cat /etc/kubernetes/admin.conf" > "$tmp_admin_conf" 2>/dev/null
            _deploy_scp "$tmp_admin_conf" "$node_user" "$node_host" "$remote_admin_conf" >/dev/null 2>&1
            _deploy_ssh "$node_user" "$node_host" "${node_sudo}chmod 600 '$remote_admin_conf'" >/dev/null 2>&1
            rm -f "$tmp_admin_conf"

            # Build upgrade command with UPGRADE_ADMIN_CONF so kubeadm upgrade node
            # on the worker can use the admin kubeconfig for API access.
            local upgrade_cmd
            upgrade_cmd="${node_sudo}env UPGRADE_ADMIN_CONF=${remote_admin_conf} bash ${node_bundle} upgrade --kubernetes-version $(printf '%q' "$UPGRADE_TARGET_VERSION")"
            # Forward extra passthrough args (e.g. --distro)
            local _pt_skip_next=false
            local _pt_idx
            for ((_pt_idx=0; _pt_idx<${#UPGRADE_PASSTHROUGH_ARGS[@]}; _pt_idx++)); do
                if [ "$_pt_skip_next" = true ]; then _pt_skip_next=false; continue; fi
                case "${UPGRADE_PASSTHROUGH_ARGS[$_pt_idx]}" in
                    --kubernetes-version) _pt_skip_next=true ;;
                    --skip-drain) ;;
                    *) upgrade_cmd+=" $(printf '%q' "${UPGRADE_PASSTHROUGH_ARGS[$_pt_idx]}")" ;;
                esac
            done

            if ! _deploy_exec_remote "$node_user" "$node_host" "upgrade worker" "$upgrade_cmd"; then
                log_error "Upgrade failed for ${node_host}. Node may be in cordoned state."
                _deploy_ssh "$node_user" "$node_host" "${node_sudo}rm -f '$remote_admin_conf'" >/dev/null 2>&1 || true
                upgrade_failed=true
                break
            fi
            _deploy_ssh "$node_user" "$node_host" "${node_sudo}rm -f '$remote_admin_conf'" >/dev/null 2>&1 || true

            # Uncordon
            if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
                if ! _upgrade_uncordon_node "$cp1_user" "$cp1_host" "$node_name"; then
                    log_warn "Uncordon failed for ${node_host}. Continuing..."
                fi
            fi

            log_info "  [${node_host}] Worker upgrade complete"
        done
    fi

    # --- Step 8: Verify ---
    log_info "Step $((_step+=1)): Verifying cluster state..."
    local verify_output
    verify_output=$(_deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide" 2>&1) || true
    log_info "$verify_output"

    # --- Step 9: Clean up remote bundle directories ---
    log_info "Step $((_step+=1)): Cleaning up remote bundle directories..."
    _cleanup_upgrade_remote_dirs
    _pop_cleanup

    # --- Step 10: Summary ---
    log_info ""
    log_info "=== Upgrade Summary ==="
    log_info ""
    log_info "Target Version: v${UPGRADE_TARGET_VERSION}"
    log_info ""
    log_info "Control-Plane Nodes:"
    for node in "${cp_nodes[@]}"; do
        _parse_node_address "$node"
        log_info "  - ${_NODE_USER}@${_NODE_HOST}"
    done
    if [ ${#w_nodes[@]} -gt 0 ]; then
        log_info ""
        log_info "Worker Nodes:"
        for node in "${w_nodes[@]}"; do
            _parse_node_address "$node"
            log_info "  - ${_NODE_USER}@${_NODE_HOST}"
        done
    fi
    log_info ""
    log_info "=========================="

    # Clean up known_hosts
    _cleanup_upgrade_known_hosts
    _pop_cleanup
    _DEPLOY_KNOWN_HOSTS=""

    if [ "$upgrade_failed" = true ]; then
        log_error "Some worker upgrades failed. Check logs above."
        return 1
    fi

    log_info "Cluster upgrade completed successfully!"
    return 0
}
