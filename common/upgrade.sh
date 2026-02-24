#!/bin/sh

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

    # Validate MAJOR.MINOR.PATCH format
    if ! echo "$current" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        log_error "Invalid current version format: '${current}' (expected MAJOR.MINOR.PATCH)"
        return 1
    fi
    if ! echo "$target" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        log_error "Invalid target version format: '${target}' (expected MAJOR.MINOR.PATCH)"
        return 1
    fi

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

# --- Multi-Version Step Computation ---

# Compute intermediate upgrade steps for auto-step-upgrade.
# Fetches the latest patch version for each intermediate minor from dl.k8s.io.
# Output: newline-separated list of versions (MAJOR.MINOR.PATCH), one per line.
# Usage: _compute_upgrade_steps <current_version> <target_version>
_compute_upgrade_steps() {
    local current="$1" target="$2"
    local cur_minor tar_minor
    cur_minor=$(echo "$current" | cut -d. -f2)
    tar_minor=$(echo "$target" | cut -d. -f2)
    local major
    major=$(echo "$current" | cut -d. -f1)

    local steps=""
    local m=$((cur_minor + 1))
    while [ "$m" -lt "$tar_minor" ]; do
        local latest
        latest=$(curl -fsSL --retry 2 --max-time 10 "https://dl.k8s.io/release/stable-${major}.${m}.txt" 2>/dev/null | sed 's/^v//') || true
        if [ -z "$latest" ]; then
            log_error "Failed to fetch latest patch version for ${major}.${m}.x from dl.k8s.io"
            return 1
        fi
        steps="${steps}${steps:+
}${latest}"
        m=$((m + 1))
    done
    # Final target
    steps="${steps}${steps:+
}${target}"
    echo "$steps"
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

# --- Shared Node Name Resolution ---

# Resolve a node's Kubernetes node name from its host IP/hostname via kubectl.
# Tries: 1) match by InternalIP address, 2) match by Hostname, 3) SSH to target and get its hostname
# Usage: _get_node_name <cp_user> <cp_host> <target_host>
# Requires: _deploy_ssh, _parse_node_address, _DEPLOY_ALL_NODES, _csv_count, _csv_get
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
        local _all_cnt _ni
        _all_cnt=$(_csv_count "$_DEPLOY_ALL_NODES")
        _ni=0
        while [ "$_ni" -lt "$_all_cnt" ]; do
            local _node_entry
            _node_entry=$(_csv_get "$_DEPLOY_ALL_NODES" "$_ni")
            local _check_host="${_node_entry#*@}"
            if [ "$_check_host" = "$target_host" ] || [ "$_check_host" = "$stripped" ]; then
                _parse_node_address "$_node_entry"
                target_user="$_NODE_USER"
                target_actual_host="$_NODE_HOST"
                break
            fi
            _ni=$((_ni + 1))
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

# --- Remote Orchestration ---

# Show dry-run upgrade plan
upgrade_dry_run() {
    log_info "=== Upgrade Dry-Run Plan ==="
    log_info ""
    log_info "Target Version: ${UPGRADE_TARGET_VERSION}"
    log_info ""

    local cp_count
    cp_count=$(_csv_count "$DEPLOY_CONTROL_PLANES")
    log_info "Control-Plane Nodes (${cp_count}):"
    local _i=0
    while [ "$_i" -lt "$cp_count" ]; do
        local node
        node=$(_csv_get "$DEPLOY_CONTROL_PLANES" "$_i")
        _parse_node_address "$node"
        log_info "  - ${_NODE_USER}@${_NODE_HOST}"
        _i=$((_i + 1))
    done
    log_info ""

    if [ -n "$DEPLOY_WORKERS" ]; then
        local w_count
        w_count=$(_csv_count "$DEPLOY_WORKERS")
        log_info "Worker Nodes (${w_count}):"
        _i=0
        while [ "$_i" -lt "$w_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_WORKERS" "$_i")
            _parse_node_address "$node"
            log_info "  - ${_NODE_USER}@${_NODE_HOST}"
            _i=$((_i + 1))
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
    step=$((step + 1))
    log_info "  ${step}. Upgrade control-planes (sequential):"
    _i=0
    while [ "$_i" -lt "$cp_count" ]; do
        local node
        node=$(_csv_get "$DEPLOY_CONTROL_PLANES" "$_i")
        if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
            log_info "     - drain ${node}"
        fi
        local _suffix=""
        [ "$_i" -eq 0 ] && _suffix=" (--first-control-plane)"
        log_info "     - upgrade ${node}${_suffix}"
        if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
            log_info "     - uncordon ${node}"
        fi
        _i=$((_i + 1))
    done
    if [ -n "$DEPLOY_WORKERS" ]; then
        local w_count
        w_count=$(_csv_count "$DEPLOY_WORKERS")
        step=$((step + 1))
        log_info "  ${step}. Upgrade workers (sequential):"
        _i=0
        while [ "$_i" -lt "$w_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_WORKERS" "$_i")
            if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
                log_info "     - drain $node"
            fi
            log_info "     - upgrade $node"
            if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
                log_info "     - uncordon $node"
            fi
            _i=$((_i + 1))
        done
    fi
    step=$((step + 1))
    log_info "  ${step}. Verify: kubectl get nodes"
    step=$((step + 1))
    log_info "  ${step}. Show summary"
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# Append UPGRADE_PASSTHROUGH_ARGS (newline-delimited) to a command string,
# skipping --kubernetes-version (+ its value) and --skip-drain.
# Outputs modified command string to stdout.
# Usage: cmd=$(_append_upgrade_passthrough "$cmd" "$UPGRADE_PASSTHROUGH_ARGS")
_append_upgrade_passthrough() {
    local _cmd="$1" _args_str="$2"
    if [ -n "$_args_str" ]; then
        local _pt_arg _skip_next=false
        while IFS= read -r _pt_arg; do
            if [ "$_skip_next" = true ]; then
                _skip_next=false
                continue
            fi
            case "$_pt_arg" in
                --kubernetes-version) _skip_next=true; continue ;;
                --skip-drain) continue ;;
                *) _cmd="${_cmd} $(_posix_shell_quote "$_pt_arg")" ;;
            esac
        done <<EOF
$_args_str
EOF
    fi
    printf '%s' "$_cmd"
}

# --- Rollback helpers ---

# Record pre-upgrade package versions from a remote node.
# Sets _PRE_UPGRADE_VERSION with the current kubeadm version.
# Usage: _record_pre_upgrade_versions <user> <host>
_record_pre_upgrade_versions() {
    local user="$1" host="$2"
    local pfx=""
    [ "$user" != "root" ] && pfx="sudo -n "

    _PRE_UPGRADE_VERSION=""
    _PRE_UPGRADE_VERSION=$(_deploy_ssh "$user" "$host" "${pfx}kubeadm version -o short" 2>/dev/null | sed 's/^v//' | tr -d '[:space:]') || true
    if [ -n "$_PRE_UPGRADE_VERSION" ]; then
        log_debug "  [${host}] Pre-upgrade version: v${_PRE_UPGRADE_VERSION}"
    fi
}

# Attempt to rollback a failed node to the pre-upgrade version.
# Usage: _rollback_node <user> <host> <node_name> <bundle_path> <pre_version>
_rollback_node() {
    local user="$1" host="$2" node_name="$3" bundle_path="$4" pre_version="$5"
    local pfx=""
    [ "$user" != "root" ] && pfx="sudo -n "

    if [ -z "$pre_version" ]; then
        log_warn "  [${host}] No pre-upgrade version recorded, cannot rollback"
        return 1
    fi

    log_warn "  [${host}] Attempting rollback to v${pre_version}..."

    # Downgrade packages to pre-upgrade version
    local rollback_cmd
    rollback_cmd="${pfx}sh ${bundle_path} upgrade --kubernetes-version $(_posix_shell_quote "$pre_version")"
    rollback_cmd=$(_append_upgrade_passthrough "$rollback_cmd" "$UPGRADE_PASSTHROUGH_ARGS")

    if _deploy_exec_remote "$user" "$host" "rollback" "$rollback_cmd"; then
        log_info "  [${host}] Rollback to v${pre_version} succeeded"

        # Restart kubelet
        _deploy_ssh "$user" "$host" "${pfx}systemctl daemon-reload && systemctl restart kubelet" >/dev/null 2>&1 || true

        return 0
    else
        log_error "  [${host}] Rollback failed. Manual intervention required."
        return 1
    fi
}

# Main upgrade orchestration (remote mode)
upgrade_cluster() {
    local cp_count w_count
    cp_count=$(_csv_count "$DEPLOY_CONTROL_PLANES")
    w_count=0
    [ -n "$DEPLOY_WORKERS" ] && w_count=$(_csv_count "$DEPLOY_WORKERS")

    # State/resume support
    # State/resume support (only when --resume is enabled)
    if [ "${RESUME_ENABLED:-false}" = true ]; then
        local resume_file
        resume_file=$(_state_find_resume "upgrade")
        if [ -n "$resume_file" ]; then
            _state_load "$resume_file"
            log_info "Resuming previous upgrade operation..."
        else
            log_info "No resumable upgrade state found, starting fresh."
            _state_init "upgrade"
        fi
    fi
    _state_set "target_version" "$UPGRADE_TARGET_VERSION"

    _audit_log "upgrade" "started" "target=${UPGRADE_TARGET_VERSION} cp=${cp_count} workers=${w_count}"
    log_info "Upgrading Kubernetes cluster to v${UPGRADE_TARGET_VERSION}: ${cp_count} control-plane(s), ${w_count} worker(s)"

    # Build combined node list (comma-separated)
    _DEPLOY_ALL_NODES="$DEPLOY_CONTROL_PLANES"
    [ -n "$DEPLOY_WORKERS" ] && _DEPLOY_ALL_NODES="${_DEPLOY_ALL_NODES},${DEPLOY_WORKERS}"
    local all_count
    all_count=$(_csv_count "$_DEPLOY_ALL_NODES")

    # Inform about SSH host key policy
    if [ "${DEPLOY_SSH_HOST_KEY_CHECK}" = "accept-new" ]; then
        log_info "SSH host key check: accept-new (TOFU)."
    elif [ "${DEPLOY_SSH_HOST_KEY_CHECK}" = "yes" ] && [ -z "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        log_info "SSH strict host key checking is enabled."
        log_info "Provide known_hosts with --ssh-known-hosts to proceed:"
        log_info "  ssh-keyscan -H <node-ip> >> known_hosts"
        log_info "  setup-k8s.sh upgrade --ssh-known-hosts known_hosts ..."
    fi

    # Create session-scoped known_hosts
    _setup_session_known_hosts "upgrade"

    local _step=0

    # --- Step 1: SSH connectivity check ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Checking SSH connectivity to all nodes..."
    local _i=0 _conn_nodes=""
    while [ "$_i" -lt "$all_count" ]; do
        local _n
        _n=$(_csv_get "$_DEPLOY_ALL_NODES" "$_i")
        _conn_nodes="${_conn_nodes} ${_n}"
        _i=$((_i + 1))
    done
    # shellcheck disable=SC2086 # intentional word splitting
    if ! _check_ssh_connectivity $_conn_nodes; then
        log_error "SSH connectivity check failed. Aborting upgrade."
        return 1
    fi

    # --- Step 2: Generate and transfer bundle to all nodes ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Generating and transferring bundle to all nodes..."
    if ! _generate_and_transfer_bundle "upgrade"; then
        return 1
    fi

    # --- Step 3: Get current version from first CP ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Checking current cluster version..."
    local cp0
    cp0=$(_csv_get "$DEPLOY_CONTROL_PLANES" 0)
    _parse_node_address "$cp0"
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

    # Auto-step-upgrade: compute intermediate versions if minor gap > 1
    if [ "${UPGRADE_AUTO_STEP:-false}" = true ]; then
        local cur_minor tar_minor
        cur_minor=$(echo "$current_version" | cut -d. -f2)
        tar_minor=$(echo "$UPGRADE_TARGET_VERSION" | cut -d. -f2)
        if [ "$tar_minor" -gt $((cur_minor + 1)) ]; then
            local steps final_target="$UPGRADE_TARGET_VERSION"
            steps=$(_compute_upgrade_steps "$current_version" "$UPGRADE_TARGET_VERSION")
            local step_count=0
            for _sv in $steps; do step_count=$((step_count + 1)); done
            log_info "Auto-step-upgrade: ${step_count} step(s) to reach v${final_target}"
            # Clean up current bundle setup before stepping
            _cleanup_remote_bundle_dirs
            _pop_cleanup
            # Step through each intermediate version using recursive calls
            UPGRADE_AUTO_STEP=false  # prevent recursion
            for step_version in $steps; do
                log_info ""
                log_info "========================================="
                log_info "Auto-step: upgrading to v${step_version}"
                log_info "========================================="
                UPGRADE_TARGET_VERSION="$step_version"
                if ! upgrade_cluster; then
                    log_error "Auto-step upgrade failed at v${step_version}"
                    UPGRADE_TARGET_VERSION="$final_target"
                    UPGRADE_AUTO_STEP=true
                    return 1
                fi
                log_info "Auto-step: v${step_version} complete"
            done
            UPGRADE_TARGET_VERSION="$final_target"
            UPGRADE_AUTO_STEP=true
            log_info ""
            log_info "Auto-step upgrade to v${UPGRADE_TARGET_VERSION} completed successfully!"
            return 0
        fi
    fi

    # Validate version constraints (single minor version step)
    _validate_upgrade_version "$current_version" "$UPGRADE_TARGET_VERSION"

    # --- Pre-upgrade health check ---
    log_info ""
    _health_check_cluster "$cp1_user" "$cp1_host" --pre || true
    log_info ""

    # --- Step 5: Run kubeadm upgrade plan (informational) ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Running kubeadm upgrade plan..."
    local plan_output
    plan_output=$(_deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}kubeadm upgrade plan" 2>&1) || true
    log_info "$plan_output"

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
    _step=$((_step + 1))
    log_info "Step ${_step}: Upgrading control-plane nodes..."
    local upgrade_failed=false

    _i=0
    while [ "$_i" -lt "$cp_count" ]; do
        local node
        node=$(_csv_get "$DEPLOY_CONTROL_PLANES" "$_i")
        _parse_node_address "$node"
        local node_user="$_NODE_USER" node_host="$_NODE_HOST"

        # Skip if already completed in a previous run
        if _state_is_step_done "upgrade_cp_${node_host}"; then
            log_info "  [${node_host}] Control-plane upgrade... (skipped, resumed)"
            _i=$((_i + 1))
            continue
        fi

        local node_bundle
        node_bundle="$(_bundle_dir_lookup "$node_host")/setup-k8s.sh"
        local node_sudo=""
        [ "$node_user" != "root" ] && node_sudo="sudo -n "

        # Get node name for drain/uncordon
        local node_name
        node_name=$(_get_node_name "$cp1_user" "$cp1_host" "$node_host")
        if [ -z "$node_name" ]; then
            log_warn "Could not resolve node name for ${node_host}, using host as node name"
            node_name="$node_host"
        fi

        # Record pre-upgrade version for potential rollback
        _record_pre_upgrade_versions "$node_user" "$node_host"

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
        upgrade_cmd="${node_sudo}sh ${node_bundle} upgrade --kubernetes-version $(_posix_shell_quote "$UPGRADE_TARGET_VERSION")"
        if [ "$_i" -eq 0 ]; then
            upgrade_cmd="${upgrade_cmd} --first-control-plane"
        fi
        # Forward extra passthrough args (e.g. --distro)
        upgrade_cmd=$(_append_upgrade_passthrough "$upgrade_cmd" "$UPGRADE_PASSTHROUGH_ARGS")

        if ! _deploy_exec_remote "$node_user" "$node_host" "upgrade control-plane" "$upgrade_cmd"; then
            log_error "Upgrade failed for ${node_host}. Node may be in cordoned state."
            if [ "${COLLECT_DIAGNOSTICS:-false}" = true ]; then
                _collect_diagnostics "$node_user" "$node_host" "/tmp/setup-k8s-diag-upgrade-cp-$(date +%s)" || true
            fi
            # Attempt rollback
            if [ "$UPGRADE_NO_ROLLBACK" != true ] && [ -n "${_PRE_UPGRADE_VERSION:-}" ]; then
                _rollback_node "$node_user" "$node_host" "$node_name" "$node_bundle" "$_PRE_UPGRADE_VERSION" || true
                # Uncordon after rollback
                if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
                    _upgrade_uncordon_node "$cp1_user" "$cp1_host" "$node_name" || true
                fi
            fi
            upgrade_failed=true
            break
        fi

        # Uncordon
        if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
            if ! _upgrade_uncordon_node "$cp1_user" "$cp1_host" "$node_name"; then
                log_warn "Uncordon failed for ${node_host}. Continuing..."
            fi
        fi

        _state_mark_step "upgrade_cp_${node_host}" "done"
        log_info "  [${node_host}] Control-plane upgrade complete"
        _i=$((_i + 1))
    done

    if [ "$upgrade_failed" = true ]; then
        log_error "Control-plane upgrade failed. Check logs above for details."
        log_error "Some nodes may be in mixed-version state (this is allowed by K8s skew policy)."
        _cleanup_remote_bundle_dirs
        _pop_cleanup
        return 1
    fi

    # --- Step 7: Upgrade worker nodes (sequential) ---
    if [ "$w_count" -gt 0 ]; then
        _step=$((_step + 1))
        log_info "Step ${_step}: Upgrading worker nodes..."

        _i=0
        while [ "$_i" -lt "$w_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_WORKERS" "$_i")
            _parse_node_address "$node"
            local node_user="$_NODE_USER" node_host="$_NODE_HOST"

            # Skip if already completed in a previous run
            if _state_is_step_done "upgrade_worker_${node_host}"; then
                log_info "  [${node_host}] Worker upgrade... (skipped, resumed)"
                _i=$((_i + 1))
                continue
            fi
            local node_bundle
            node_bundle="$(_bundle_dir_lookup "$node_host")/setup-k8s.sh"
            local node_sudo=""
            [ "$node_user" != "root" ] && node_sudo="sudo -n "

            # Get node name
            local node_name
            node_name=$(_get_node_name "$cp1_user" "$cp1_host" "$node_host")
            if [ -z "$node_name" ]; then
                log_warn "Could not resolve node name for ${node_host}, using host as node name"
                node_name="$node_host"
            fi

            # Record pre-upgrade version for potential rollback
            _record_pre_upgrade_versions "$node_user" "$node_host"

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
            local remote_admin_conf
            remote_admin_conf=$(_deploy_ssh "$node_user" "$node_host" "${node_sudo}mktemp /tmp/upgrade-admin-XXXXXX")
            remote_admin_conf=$(echo "$remote_admin_conf" | tr -d '[:space:]')
            local tmp_admin_conf
            tmp_admin_conf=$(mktemp /tmp/admin-conf-XXXXXX)
            chmod 600 "$tmp_admin_conf"
            if ! _deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}cat /etc/kubernetes/admin.conf" > "$tmp_admin_conf" 2>/dev/null; then
                log_error "  [${node_host}] Failed to download admin.conf from control-plane ${cp1_host}"
                rm -f "$tmp_admin_conf"
                _deploy_ssh "$node_user" "$node_host" "${node_sudo}rm -f '$remote_admin_conf'" >/dev/null 2>&1 || true
                upgrade_failed=true
                break
            fi
            if [ ! -s "$tmp_admin_conf" ]; then
                log_error "  [${node_host}] Downloaded admin.conf is empty"
                rm -f "$tmp_admin_conf"
                _deploy_ssh "$node_user" "$node_host" "${node_sudo}rm -f '$remote_admin_conf'" >/dev/null 2>&1 || true
                upgrade_failed=true
                break
            fi
            _deploy_scp "$tmp_admin_conf" "$node_user" "$node_host" "$remote_admin_conf" >/dev/null 2>&1
            _deploy_ssh "$node_user" "$node_host" "${node_sudo}chmod 600 '$remote_admin_conf'" >/dev/null 2>&1
            rm -f "$tmp_admin_conf"

            # Build upgrade command with UPGRADE_ADMIN_CONF so kubeadm upgrade node
            # on the worker can use the admin kubeconfig for API access.
            local upgrade_cmd
            upgrade_cmd="${node_sudo}env UPGRADE_ADMIN_CONF=${remote_admin_conf} sh ${node_bundle} upgrade --kubernetes-version $(_posix_shell_quote "$UPGRADE_TARGET_VERSION")"
            # Forward extra passthrough args (e.g. --distro)
            upgrade_cmd=$(_append_upgrade_passthrough "$upgrade_cmd" "$UPGRADE_PASSTHROUGH_ARGS")

            if ! _deploy_exec_remote "$node_user" "$node_host" "upgrade worker" "$upgrade_cmd"; then
                log_error "Upgrade failed for ${node_host}. Node may be in cordoned state."
                if [ "${COLLECT_DIAGNOSTICS:-false}" = true ]; then
                    _collect_diagnostics "$node_user" "$node_host" "/tmp/setup-k8s-diag-upgrade-worker-$(date +%s)" || true
                fi
                _deploy_ssh "$node_user" "$node_host" "${node_sudo}rm -f '$remote_admin_conf'" >/dev/null 2>&1 || true
                # Attempt rollback
                if [ "$UPGRADE_NO_ROLLBACK" != true ] && [ -n "${_PRE_UPGRADE_VERSION:-}" ]; then
                    _rollback_node "$node_user" "$node_host" "$node_name" "$node_bundle" "$_PRE_UPGRADE_VERSION" || true
                    if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
                        _upgrade_uncordon_node "$cp1_user" "$cp1_host" "$node_name" || true
                    fi
                fi
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

            _state_mark_step "upgrade_worker_${node_host}" "done"
            log_info "  [${node_host}] Worker upgrade complete"
            _i=$((_i + 1))
        done
    fi

    # --- Step 8: Verify ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Verifying cluster state..."
    local verify_output
    verify_output=$(_deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide" 2>&1) || true
    log_info "$verify_output"

    # --- Post-upgrade health check ---
    log_info ""
    _health_check_cluster "$cp1_user" "$cp1_host" --post || true

    # --- Step 9: Clean up remote bundle directories ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Cleaning up remote bundle directories..."
    _cleanup_remote_bundle_dirs
    _pop_cleanup

    # --- Step 10: Summary ---
    log_info ""
    log_info "=== Upgrade Summary ==="
    log_info ""
    log_info "Target Version: v${UPGRADE_TARGET_VERSION}"
    log_info ""
    log_info "Control-Plane Nodes:"
    _i=0
    while [ "$_i" -lt "$cp_count" ]; do
        local node
        node=$(_csv_get "$DEPLOY_CONTROL_PLANES" "$_i")
        _parse_node_address "$node"
        log_info "  - ${_NODE_USER}@${_NODE_HOST}"
        _i=$((_i + 1))
    done
    if [ "$w_count" -gt 0 ]; then
        log_info ""
        log_info "Worker Nodes:"
        _i=0
        while [ "$_i" -lt "$w_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_WORKERS" "$_i")
            _parse_node_address "$node"
            log_info "  - ${_NODE_USER}@${_NODE_HOST}"
            _i=$((_i + 1))
        done
    fi
    log_info ""
    log_info "=========================="

    # Clean up known_hosts
    _teardown_session_known_hosts
    _pop_cleanup

    if [ "$upgrade_failed" = true ]; then
        _state_set "status" "failed"
        _audit_log "upgrade" "failed" "target=${UPGRADE_TARGET_VERSION}"
        log_error "Some worker upgrades failed. Check logs above."
        return 1
    fi

    _state_complete
    _audit_log "upgrade" "completed" "target=${UPGRADE_TARGET_VERSION}"
    log_info "Cluster upgrade completed successfully!"
    return 0
}
