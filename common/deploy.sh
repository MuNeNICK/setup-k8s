#!/bin/sh

# Deploy module: orchestrate remote Kubernetes cluster installation via SSH
# SSH infrastructure is provided by common/ssh.sh (loaded before this module).

# --- Token Extraction ---

# Extract join information from the first control-plane node
# Sets: _JOIN_COMMAND, _JOIN_TOKEN, _JOIN_ADDR, _JOIN_HASH, _CERT_KEY
_extract_join_info() {
    local user="$1" host="$2"

    log_info "[$host] Extracting join information..."

    # Get join command (use sudo -n when not root for fail-fast on missing NOPASSWD)
    local sudo_pfx=""
    [ "$user" != "root" ] && sudo_pfx="sudo -n "
    local attempt=1 max_attempts=3
    _JOIN_COMMAND=""
    while [ "$attempt" -le "$max_attempts" ]; do
        _JOIN_COMMAND=$(_deploy_ssh "$user" "$host" "${sudo_pfx}kubeadm token create --print-join-command") && break
        log_warn "[$host] Join command extraction attempt $attempt/$max_attempts failed, retrying in ${attempt}s..."
        sleep "$attempt"
        attempt=$((attempt + 1))
    done
    if [ -z "$_JOIN_COMMAND" ]; then
        log_error "[$host] Failed to extract join command after $max_attempts attempts"
        return 1
    fi
    log_debug "Join command: $_JOIN_COMMAND"

    # Parse token, address, and hash from join command using word-based splitting
    # Expected format: kubeadm join <addr> --token <token> --discovery-token-ca-cert-hash <hash>
    _JOIN_ADDR="" _JOIN_TOKEN="" _JOIN_HASH=""
    # shellcheck disable=SC2086 # intentional word splitting of join command
    set -- $_JOIN_COMMAND
    while [ $# -gt 0 ]; do
        case "$1" in
            join)
                # Next word is the address (if not a flag)
                if [ $# -ge 2 ]; then
                    case "$2" in
                        -*) ;;
                        *) _JOIN_ADDR="$2" ;;
                    esac
                fi
                ;;
            --token)
                [ $# -ge 2 ] && _JOIN_TOKEN="$2"
                ;;
            --discovery-token-ca-cert-hash)
                [ $# -ge 2 ] && _JOIN_HASH="$2"
                ;;
        esac
        shift
    done

    if [ -z "$_JOIN_TOKEN" ] || [ -z "$_JOIN_ADDR" ] || [ -z "$_JOIN_HASH" ]; then
        log_error "[$host] Failed to parse join command components"
        log_error "  Join command was: $_JOIN_COMMAND"
        log_error "  Parsed: addr='$_JOIN_ADDR' token='$_JOIN_TOKEN' hash='$_JOIN_HASH'"
        return 1
    fi

    # Validate extracted values
    if ! echo "$_JOIN_TOKEN" | grep -qE '^[a-z0-9]{6}\.[a-z0-9]{16}$'; then
        log_error "[$host] Join token format looks invalid: $_JOIN_TOKEN"
        return 1
    fi
    if ! echo "$_JOIN_HASH" | grep -qE '^sha256:[a-f0-9]{64}$'; then
        log_error "[$host] Discovery token hash format looks invalid: $_JOIN_HASH"
        return 1
    fi

    # For HA: get certificate key
    _CERT_KEY=""
    local has_ha_vip=false
    if [ -n "$DEPLOY_PASSTHROUGH_ARGS" ]; then
        local _chk_arg
        while IFS= read -r _chk_arg; do
            if [ "$_chk_arg" = "--ha-vip" ]; then
                has_ha_vip=true
                break
            fi
        done <<EOF
$DEPLOY_PASSTHROUGH_ARGS
EOF
    fi

    if [ "$has_ha_vip" = true ]; then
        log_info "[$host] Uploading certificates for HA join..."
        local cert_output
        if ! cert_output=$(_deploy_ssh "$user" "$host" "${sudo_pfx}kubeadm init phase upload-certs --upload-certs"); then
            log_error "[$host] kubeadm upload-certs failed"
            return 1
        fi
        _CERT_KEY=$(echo "$cert_output" | tail -1)
        if ! echo "$_CERT_KEY" | grep -qE '^[a-f0-9]{64}$'; then
            log_error "[$host] Invalid certificate key format (expected 64 hex chars, got: '$_CERT_KEY')"
            return 1
        fi
        log_debug "Certificate key: $_CERT_KEY"
    fi

    log_info "[$host] Join info extracted successfully"
    return 0
}

# --- Main Orchestration ---

# Show dry-run deployment plan
deploy_dry_run() {
    log_info "=== Deploy Dry-Run Plan ==="
    log_info ""

    # Parse control-plane nodes
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

    # Parse worker nodes
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

    _log_ssh_settings
    log_info ""

    if [ -n "$DEPLOY_PASSTHROUGH_ARGS" ]; then
        log_info "Passthrough Args: $DEPLOY_PASSTHROUGH_ARGS"
        log_info ""
    fi

    local cp0
    cp0=$(_csv_get "$DEPLOY_CONTROL_PLANES" 0)
    log_info "Orchestration Plan:"
    log_info "  1. Generate bundle (all modules → single file)"
    log_info "  2. Check SSH connectivity to all nodes"
    log_info "  3. Transfer bundle to all nodes"
    log_info "  4. Init first control-plane: ${cp0}"
    if [ "$cp_count" -gt 1 ]; then
        log_info "  5. Extract join token"
        log_info "  6. Join additional control-planes (sequential):"
        _i=1
        while [ "$_i" -lt "$cp_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_CONTROL_PLANES" "$_i")
            log_info "     - ${node}"
            _i=$((_i + 1))
        done
    else
        log_info "  5. Extract join token"
    fi
    if [ -n "$DEPLOY_WORKERS" ]; then
        log_info "  7. Join workers (parallel):"
        _i=0
        local w_count
        w_count=$(_csv_count "$DEPLOY_WORKERS")
        while [ "$_i" -lt "$w_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_WORKERS" "$_i")
            log_info "     - $node"
            _i=$((_i + 1))
        done
    fi
    log_info "  8. Show summary"
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# Main deploy orchestration
deploy_cluster() {
    local cp_count w_count
    cp_count=$(_csv_count "$DEPLOY_CONTROL_PLANES")
    w_count=0
    [ -n "$DEPLOY_WORKERS" ] && w_count=$(_csv_count "$DEPLOY_WORKERS")

    # Build combined node list (comma-separated)
    _DEPLOY_ALL_NODES="$DEPLOY_CONTROL_PLANES"
    [ -n "$DEPLOY_WORKERS" ] && _DEPLOY_ALL_NODES="${_DEPLOY_ALL_NODES},${DEPLOY_WORKERS}"
    local all_count
    all_count=$(_csv_count "$_DEPLOY_ALL_NODES")

    # Calculate total orchestration steps: bundle, ssh-check, transfer, init, extract-token,
    # [join-cps], [join-workers], cleanup-remote, summary
    local total_steps=6
    [ "$cp_count" -gt 1 ] && total_steps=$((total_steps + 1))
    [ "$w_count" -gt 0 ] && total_steps=$((total_steps + 1))
    # State/resume support (only when --resume is enabled)
    if [ "${RESUME_ENABLED:-false}" = true ]; then
        local resume_file
        resume_file=$(_state_find_resume "deploy")
        if [ -n "$resume_file" ]; then
            _state_load "$resume_file"
            log_info "Resuming previous deploy operation..."
        else
            log_info "No resumable deploy state found, starting fresh."
            _state_init "deploy"
        fi
    fi
    _state_set "cp_count" "$cp_count"
    _state_set "w_count" "$w_count"

    _audit_log "deploy" "started" "cp=${cp_count} workers=${w_count}"
    log_info "Deploying Kubernetes cluster: ${cp_count} control-plane(s), ${w_count} worker(s)"

    # Inform about SSH host key policy
    if [ "${DEPLOY_SSH_HOST_KEY_CHECK}" = "accept-new" ]; then
        log_info "SSH host key check: accept-new (TOFU). New keys are accepted on first connect;"
        log_info "subsequent connections reject changed keys. For stricter security, use:"
        log_info "  --ssh-known-hosts known_hosts"
    elif [ "${DEPLOY_SSH_HOST_KEY_CHECK}" = "yes" ] && [ -z "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        log_info "SSH strict host key checking is enabled."
        log_info "Provide known_hosts with --ssh-known-hosts to proceed:"
        log_info "  ssh-keyscan -H <node-ip> >> known_hosts  # collect fingerprints"
        log_info "  setup-k8s.sh deploy --ssh-known-hosts known_hosts ..."
    fi

    # Create session-scoped known_hosts for MITM detection within this deploy
    _setup_session_known_hosts "deploy"

    # --- Step 1: Generate bundle ---
    # Always regenerate the bundle (even on resume), because bundle paths are
    # process-local and remote temp dirs are cleaned on exit.
    local _step=0
    _step=$((_step + 1))
    local bundle_path=""
    log_info "Step ${_step}/${total_steps}: Generating deploy bundle..."
    bundle_path=$(mktemp /tmp/setup-k8s-deploy-XXXXXX)
    chmod 600 "$bundle_path"
    generate_deploy_bundle "$bundle_path"
    log_info "Bundle generated: $(wc -c < "$bundle_path") bytes"

    # --- Step 2: SSH connectivity check ---
    _step=$((_step + 1))
    log_info "Step ${_step}/${total_steps}: Checking SSH connectivity to all nodes..."
    # Build argument list for connectivity check
    local _i=0 _conn_nodes=""
    while [ "$_i" -lt "$all_count" ]; do
        local _n
        _n=$(_csv_get "$_DEPLOY_ALL_NODES" "$_i")
        _conn_nodes="${_conn_nodes} ${_n}"
        _i=$((_i + 1))
    done
    # shellcheck disable=SC2086 # intentional word splitting
    if ! _check_ssh_connectivity $_conn_nodes; then
        log_error "SSH connectivity check failed. Aborting deployment."
        rm -f "$bundle_path"
        return 1
    fi

    # --- Step 3: Transfer bundle to all nodes ---
    # Always re-transfer (even on resume): remote temp dirs are cleaned on exit,
    # and _DEPLOY_NODE_BUNDLE_DIRS is process-local.
    _step=$((_step + 1))
    log_info "Step ${_step}/${total_steps}: Transferring bundle to all nodes..."
    _DEPLOY_NODE_BUNDLE_DIRS=""

    # Register cleanup handler for remote temp directories (best-effort on early failure)
    # Uses module-level globals so EXIT trap can access them after function returns
    _push_cleanup _cleanup_remote_bundle_dirs

    _i=0
    while [ "$_i" -lt "$all_count" ]; do
        local node
        node=$(_csv_get "$_DEPLOY_ALL_NODES" "$_i")
        _parse_node_address "$node"
        log_info "  [${_NODE_HOST}] Transferring bundle..."
        # Create secure temp dir on remote (owned by SSH user, mode 700)
        local rdir
        rdir=$(_deploy_ssh "$_NODE_USER" "$_NODE_HOST" "d=\$(mktemp -d) && chmod 700 \"\$d\" && echo \"\$d\"") || true
        rdir=$(echo "$rdir" | tr -d '[:space:]')
        if [ -z "$rdir" ]; then
            log_error "  [${_NODE_HOST}] Failed to create remote temp directory (got: '${rdir}')"
            rm -f "$bundle_path"
            return 1
        fi
        case "$rdir" in
            /*) ;;
            *)
                log_error "  [${_NODE_HOST}] Failed to create remote temp directory (got: '${rdir}')"
                rm -f "$bundle_path"
                return 1
                ;;
        esac
        _bundle_dir_set "$_NODE_HOST" "$rdir"
        if ! _deploy_scp "$bundle_path" "$_NODE_USER" "$_NODE_HOST" "${rdir}/setup-k8s.sh"; then
            log_error "  [${_NODE_HOST}] Failed to transfer bundle"
            rm -f "$bundle_path"
            return 1
        fi
        _i=$((_i + 1))
    done
    rm -f "$bundle_path"
    log_info "Bundle transferred to all nodes"

    # --- Step 4: Init first control-plane ---
    _step=$((_step + 1))
    local cp0
    cp0=$(_csv_get "$DEPLOY_CONTROL_PLANES" 0)
    _parse_node_address "$cp0"
    local cp1_user="$_NODE_USER" cp1_host="$_NODE_HOST"

    if ! _state_is_step_done "init_cp"; then
        log_info "Step ${_step}/${total_steps}: Initializing first control-plane..."

        # Transfer kubeadm config patch file to remote if specified
        local _remote_patch_path=""
        if [ -n "${KUBEADM_CONFIG_PATCH:-}" ] && [ -f "$KUBEADM_CONFIG_PATCH" ]; then
            local _rdir
            _rdir=$(_bundle_dir_lookup "$cp1_host")
            _remote_patch_path="${_rdir}/kubeadm-config-patch.yaml"
            log_info "  Transferring kubeadm config patch to ${cp1_host}..."
            if ! _deploy_scp "$KUBEADM_CONFIG_PATCH" "$cp1_user" "$cp1_host" "$_remote_patch_path"; then
                log_error "Failed to transfer kubeadm config patch to ${cp1_host}"
                return 1
            fi
            # Rewrite passthrough args: replace local path with remote path
            DEPLOY_PASSTHROUGH_ARGS=$(printf '%s\n' "$DEPLOY_PASSTHROUGH_ARGS" | while IFS= read -r _line; do
                if [ "$_line" = "$KUBEADM_CONFIG_PATCH" ]; then
                    echo "$_remote_patch_path"
                else
                    echo "$_line"
                fi
            done)
        fi

        # Build init command with passthrough args (shell-escaped)
        local remote_bundle
        remote_bundle="$(_bundle_dir_lookup "$cp1_host")/setup-k8s.sh"
        local sudo_pfx=""
        [ "$cp1_user" != "root" ] && sudo_pfx="sudo -n "
        local init_cmd="${sudo_pfx}sh ${remote_bundle} init"
        # If multiple CPs, enable HA
        if [ "$cp_count" -gt 1 ]; then
            init_cmd="${init_cmd} --ha"
        fi
        init_cmd=$(_append_passthrough_to_cmd "$init_cmd" "$DEPLOY_PASSTHROUGH_ARGS")

        if ! _deploy_exec_remote "$cp1_user" "$cp1_host" "kubeadm init" "$init_cmd"; then
            log_error "First control-plane initialization failed. Aborting."
            if [ "${COLLECT_DIAGNOSTICS:-false}" = true ]; then
                _collect_diagnostics "$cp1_user" "$cp1_host" "/tmp/setup-k8s-diag-init-$(date +%s)" || true
            fi
            return 1
        fi
        _state_mark_step "init_cp" "done"
    else
        log_info "Step ${_step}/${total_steps}: Initializing first control-plane... (skipped, resumed)"
    fi

    # --- Step 5: Extract join token ---
    _step=$((_step + 1))
    log_info "Step ${_step}/${total_steps}: Extracting join information..."
    if ! _extract_join_info "$cp1_user" "$cp1_host"; then
        log_error "Failed to extract join info. Aborting."
        return 1
    fi

    # --- Step 6: Join additional control-planes (sequential) ---
    if [ "$cp_count" -gt 1 ]; then
        _step=$((_step + 1))
        log_info "Step ${_step}/${total_steps}: Joining additional control-planes..."
        _i=1
        while [ "$_i" -lt "$cp_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_CONTROL_PLANES" "$_i")
            _parse_node_address "$node"

            if _state_is_step_done "join_cp_${_NODE_HOST}"; then
                log_info "  [${_NODE_HOST}] Control-plane join... (skipped, resumed)"
                _i=$((_i + 1))
                continue
            fi

            local node_bundle
            node_bundle="$(_bundle_dir_lookup "$_NODE_HOST")/setup-k8s.sh"
            local sudo_pfx=""
            [ "$_NODE_USER" != "root" ] && sudo_pfx="sudo -n "
            local join_cmd="${sudo_pfx}sh ${node_bundle} join"
            join_cmd="${join_cmd} --join-token $(_posix_shell_quote "$_JOIN_TOKEN")"
            join_cmd="${join_cmd} --join-address $(_posix_shell_quote "$_JOIN_ADDR")"
            join_cmd="${join_cmd} --discovery-token-hash $(_posix_shell_quote "$_JOIN_HASH")"
            join_cmd="${join_cmd} --control-plane"
            join_cmd="${join_cmd} --certificate-key $(_posix_shell_quote "$_CERT_KEY")"
            # Pass through HA and other args (shell-escaped)
            join_cmd=$(_append_passthrough_to_cmd "$join_cmd" "$DEPLOY_PASSTHROUGH_ARGS")

            if ! _deploy_exec_remote "$_NODE_USER" "$_NODE_HOST" "join control-plane" "$join_cmd"; then
                log_error "Control-plane join failed for ${_NODE_HOST}. Aborting."
                if [ "${COLLECT_DIAGNOSTICS:-false}" = true ]; then
                    _collect_diagnostics "$_NODE_USER" "$_NODE_HOST" "/tmp/setup-k8s-diag-join-cp-$(date +%s)" || true
                fi
                return 1
            fi
            _state_mark_step "join_cp_${_NODE_HOST}" "done"
            _i=$((_i + 1))
        done
    fi

    # --- Step 7: Join workers (parallel) ---
    local worker_failed=false
    if [ "$w_count" -gt 0 ]; then
        _step=$((_step + 1))
        log_info "Step ${_step}/${total_steps}: Joining worker nodes (parallel)..."
        local worker_pids="" worker_hosts=""

        _i=0
        while [ "$_i" -lt "$w_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_WORKERS" "$_i")
            _parse_node_address "$node"
            local w_user="$_NODE_USER" w_host="$_NODE_HOST"

            local w_bundle
            w_bundle="$(_bundle_dir_lookup "$w_host")/setup-k8s.sh"
            local w_sudo=""
            [ "$w_user" != "root" ] && w_sudo="sudo -n "
            local join_cmd="${w_sudo}sh ${w_bundle} join"
            join_cmd="${join_cmd} --join-token $(_posix_shell_quote "$_JOIN_TOKEN")"
            join_cmd="${join_cmd} --join-address $(_posix_shell_quote "$_JOIN_ADDR")"
            join_cmd="${join_cmd} --discovery-token-hash $(_posix_shell_quote "$_JOIN_HASH")"
            # Pass through args (exclude HA-specific ones for workers, shell-escaped)
            join_cmd=$(_append_passthrough_to_cmd_worker "$join_cmd" "$DEPLOY_PASSTHROUGH_ARGS")

            # Run in background subshell
            (
                _deploy_exec_remote "$w_user" "$w_host" "join worker" "$join_cmd"
            ) &
            worker_pids="${worker_pids}${worker_pids:+ }$!"
            worker_hosts="${worker_hosts}${worker_hosts:+ }${w_host}"
            _i=$((_i + 1))
        done

        # Wait for all worker joins
        local _pi=0
        for _pid in $worker_pids; do
            _pi=$((_pi + 1))
            local _w_host
            _w_host=$(echo "$worker_hosts" | tr ' ' '\n' | sed -n "${_pi}p")
            if ! wait "$_pid"; then
                log_error "Worker join failed for ${_w_host}"
                worker_failed=true
            fi
        done
    fi

    # --- Post-deploy health check ---
    log_info ""
    _health_check_cluster "$cp1_user" "$cp1_host" --post || true

    # Verify expected node count (fatal if mismatch)
    local node_count_ok=true
    _verify_node_count "$cp1_user" "$cp1_host" "$all_count" || node_count_ok=false

    # --- Step 8: Clean up remote bundle directories ---
    _step=$((_step + 1))
    log_info "Step ${_step}/${total_steps}: Cleaning up remote bundle directories..."
    _cleanup_remote_bundle_dirs
    _pop_cleanup

    # --- Step 9: Summary ---
    log_info ""
    log_info "=== Deployment Summary ==="
    log_info ""
    log_info "Control-Plane Nodes:"
    _i=0
    while [ "$_i" -lt "$cp_count" ]; do
        local node
        node=$(_csv_get "$DEPLOY_CONTROL_PLANES" "$_i")
        _parse_node_address "$node"
        log_info "  - ${_NODE_USER}@${_NODE_HOST} [OK]"
        _i=$((_i + 1))
    done
    log_info ""
    if [ "$w_count" -gt 0 ]; then
        log_info "Worker Nodes:"
        _i=0
        while [ "$_i" -lt "$w_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_WORKERS" "$_i")
            _parse_node_address "$node"
            log_info "  - ${_NODE_USER}@${_NODE_HOST}"
            _i=$((_i + 1))
        done
        log_info ""
    fi

    # Retrieve kubeconfig from first CP
    local scp_display="scp"
    [ "$DEPLOY_SSH_PORT" != "22" ] && scp_display="$scp_display -P $DEPLOY_SSH_PORT"
    [ -n "$DEPLOY_SSH_KEY" ] && scp_display="$scp_display -i $DEPLOY_SSH_KEY"
    # shellcheck disable=SC2088  # tilde is intentional display text, not expanded
    scp_display="$scp_display ${cp1_user}@${cp1_host}:/etc/kubernetes/admin.conf ~/.kube/config"
    log_info "To access the cluster from this machine:"
    log_info "  ${scp_display}"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Install a CNI plugin (e.g., Calico, Cilium, Flannel)"
    log_info "  2. Verify: kubectl get nodes"
    log_info "=========================="

    if [ "$worker_failed" = true ] || [ "$node_count_ok" = false ]; then
        _state_set "status" "failed"
        if [ "$worker_failed" = true ]; then
            _audit_log "deploy" "failed" "some worker joins failed"
            log_error "Some worker joins failed. Check logs above."
        fi
        if [ "$node_count_ok" = false ]; then
            _audit_log "deploy" "failed" "node count mismatch"
            log_error "Not all nodes registered. Check logs above."
        fi
        return 1
    fi

    # Clean up session-scoped known_hosts
    _teardown_session_known_hosts
    _pop_cleanup

    _state_complete
    _audit_log "deploy" "completed" "cp=${cp_count} workers=${w_count}"
    log_info "Cluster deployment completed successfully!"
    return 0
}
