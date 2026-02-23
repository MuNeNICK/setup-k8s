#!/bin/sh

# Deploy module: orchestrate remote Kubernetes cluster installation via SSH

# Timeout for remote operations (seconds)
DEPLOY_REMOTE_TIMEOUT=600
# Polling interval (seconds)
DEPLOY_POLL_INTERVAL=10
# Session-scoped known_hosts file (set by deploy_cluster)
_DEPLOY_KNOWN_HOSTS=""
# Module-level state for remote cleanup (must survive function scope for EXIT trap)
_DEPLOY_ALL_NODES=""
_DEPLOY_NODE_BUNDLE_DIRS=""

# --- SSH Infrastructure ---

# Build SSH options string (space-separated, no arrays)
# Sets: _SSH_OPTS (global string)
_build_deploy_ssh_opts() {
    local known_hosts="${_DEPLOY_KNOWN_HOSTS:-/dev/null}"
    local host_key_policy="${DEPLOY_SSH_HOST_KEY_CHECK:-yes}"
    _SSH_OPTS="-o StrictHostKeyChecking=$host_key_policy -o UserKnownHostsFile=$known_hosts -o LogLevel=ERROR -o ConnectTimeout=10"
    # Prevent interactive prompts in automated mode (BatchMode not used with sshpass)
    if [ -z "$DEPLOY_SSH_PASSWORD" ]; then
        _SSH_OPTS="$_SSH_OPTS -o BatchMode=yes"
    fi
    _SSH_OPTS="$_SSH_OPTS -p $DEPLOY_SSH_PORT"
    if [ -n "$DEPLOY_SSH_KEY" ]; then
        _SSH_OPTS="$_SSH_OPTS -i $DEPLOY_SSH_KEY"
    fi
}

# Run SSH command on a remote node
# Usage: _deploy_ssh <user> <host> <command...>
_deploy_ssh() {
    local user="$1" host="$2"; shift 2
    _build_deploy_ssh_opts

    # Strip brackets from IPv6 addresses for SSH (SSH needs user@::1, not user@[::1])
    local ssh_host="$host"
    case "$host" in
        '['*']')
            ssh_host="${host#\[}"
            ssh_host="${ssh_host%\]}"
            ;;
    esac

    if [ -n "$DEPLOY_SSH_PASSWORD" ]; then
        # shellcheck disable=SC2086 # intentional word splitting on SSH opts
        SSHPASS="$DEPLOY_SSH_PASSWORD" sshpass -e ssh $_SSH_OPTS -- "${user}@${ssh_host}" "$@"
    else
        # shellcheck disable=SC2086 # intentional word splitting on SSH opts
        ssh $_SSH_OPTS -- "${user}@${ssh_host}" "$@"
    fi
}

# Build SCP options string and bracketed host from SSH opts.
# Sets: _SCP_OPTS (string), _SCP_HOST (string)
_build_scp_args() {
    local host="$1"
    _build_deploy_ssh_opts

    # Convert -p to -P for scp
    _SCP_OPTS=$(echo "$_SSH_OPTS" | sed "s/ -p / -P /")

    _SCP_HOST="$host"
    case "$host" in
        *:*)
            case "$host" in
                '['*']') ;;  # already bracketed
                *) _SCP_HOST="[$host]" ;;
            esac
            ;;
    esac
}

# Run scp with optional sshpass
_run_scp() {
    if [ -n "$DEPLOY_SSH_PASSWORD" ]; then
        SSHPASS="$DEPLOY_SSH_PASSWORD" sshpass -e scp "$@"
    else
        scp "$@"
    fi
}

# SCP file to a remote node
# Usage: _deploy_scp <local_path> <user> <host> <remote_path>
_deploy_scp() {
    local local_path="$1" user="$2" host="$3" remote_path="$4"
    _build_scp_args "$host"
    # shellcheck disable=SC2086 # intentional word splitting on SCP opts
    _run_scp $_SCP_OPTS "$local_path" "${user}@${_SCP_HOST}:${remote_path}"
}

# SCP file from a remote node to local
# Usage: _deploy_scp_from <user> <host> <remote_path> <local_path>
_deploy_scp_from() {
    local user="$1" host="$2" remote_path="$3" local_path="$4"
    _build_scp_args "$host"
    # shellcheck disable=SC2086 # intentional word splitting on SCP opts
    _run_scp $_SCP_OPTS "${user}@${_SCP_HOST}:${remote_path}" "$local_path"
}

# Parse node address: "user@ip" or "ip" → sets _NODE_USER, _NODE_HOST
_parse_node_address() {
    local addr="$1"
    case "$addr" in
        *@*)
            _NODE_USER="${addr%%@*}"
            _NODE_HOST="${addr#*@}"
            ;;
        *)
            _NODE_USER="$DEPLOY_SSH_USER"
            _NODE_HOST="$addr"
            ;;
    esac
}

# Check SSH connectivity and sudo for a list of nodes
# Usage: _check_ssh_connectivity <node1> [node2] ...
_check_ssh_connectivity() {
    local ssh_failed=false
    for node in "$@"; do
        _parse_node_address "$node"
        local _ssh_err
        if _ssh_err=$(_deploy_ssh "$_NODE_USER" "$_NODE_HOST" "echo ok" 2>&1 >/dev/null); then
            log_info "  [${_NODE_HOST}] SSH OK"
            if [ "$_NODE_USER" != "root" ]; then
                local _sudo_err
                if ! _sudo_err=$(_deploy_ssh "$_NODE_USER" "$_NODE_HOST" "sudo -n true" 2>&1); then
                    log_error "  [${_NODE_HOST}] sudo -n failed — NOPASSWD sudo required for ${_NODE_USER}"
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
    [ "$ssh_failed" = true ] && return 1
    return 0
}

# --- Bundle Generation ---

# Generate a self-contained bundle script for remote execution
generate_deploy_bundle() {
    local bundle_path="$1"
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
    _generate_bundle_core "$bundle_path" "$script_dir/setup-k8s.sh" "all" "$script_dir"
}

# --- Associative store helpers (newline-separated key=value) ---

# Store a key=value pair in the bundle dirs store
# Usage: _bundle_dir_set <host> <dir>
_bundle_dir_set() {
    _DEPLOY_NODE_BUNDLE_DIRS="${_DEPLOY_NODE_BUNDLE_DIRS}${_DEPLOY_NODE_BUNDLE_DIRS:+
}${1}=${2}"
}

# Lookup a value by key from the bundle dirs store
# Usage: _bundle_dir_lookup <host>
_bundle_dir_lookup() {
    local _lookup_key="$1" _lookup_result=""
    _lookup_result=$(printf '%s\n' "$_DEPLOY_NODE_BUNDLE_DIRS" | while IFS='=' read -r _k _v; do
        if [ "$_k" = "$_lookup_key" ]; then
            echo "$_v"
            break
        fi
    done)
    echo "$_lookup_result"
}

# --- Passthrough args helpers ---

# Append all passthrough args (newline-delimited) to a command string.
# Outputs the modified command string to stdout (caller captures via $()).
# Usage: cmd=$(_append_passthrough_to_cmd "$cmd" "$DEPLOY_PASSTHROUGH_ARGS")
_append_passthrough_to_cmd() {
    local _cmd="$1" _args_str="$2"
    if [ -n "$_args_str" ]; then
        local _pt_arg
        while IFS= read -r _pt_arg; do
            _cmd="${_cmd} $(_posix_shell_quote "$_pt_arg")"
        done <<EOF
$_args_str
EOF
    fi
    printf '%s' "$_cmd"
}

# Append passthrough args for workers (excluding HA-specific flags + their values).
# Outputs the modified command string to stdout.
# Usage: cmd=$(_append_passthrough_to_cmd_worker "$cmd" "$DEPLOY_PASSTHROUGH_ARGS")
_append_passthrough_to_cmd_worker() {
    local _cmd="$1" _args_str="$2"
    if [ -n "$_args_str" ]; then
        local _pt_arg _skip_next=false
        while IFS= read -r _pt_arg; do
            if [ "$_skip_next" = true ]; then
                _skip_next=false
                continue
            fi
            case "$_pt_arg" in
                --ha-vip|--ha-interface) _skip_next=true; continue ;;
            esac
            _cmd="${_cmd} $(_posix_shell_quote "$_pt_arg")"
        done <<EOF
$_args_str
EOF
    fi
    printf '%s' "$_cmd"
}

# --- Remote Execution ---

# Execute a command on a remote node via nohup + polling
# Usage: _deploy_exec_remote <user> <host> <description> <command>
_deploy_exec_remote() {
    local user="$1" host="$2" desc="$3" cmd="$4"

    log_info "[$host] Starting: $desc"

    # Create secure temp directory on remote (mktemp -d defaults to mode 700)
    local remote_dir
    remote_dir=$(_deploy_ssh "$user" "$host" "d=\$(mktemp -d) && chmod 700 \"\$d\" && echo \"\$d\"") || true
    remote_dir=$(echo "$remote_dir" | tr -d '[:space:]')
    if [ -z "$remote_dir" ]; then
        log_error "[$host] Failed to create remote temp directory (got: '${remote_dir}')"
        return 1
    fi
    case "$remote_dir" in
        /*) ;;
        *)
            log_error "[$host] Failed to create remote temp directory (got: '${remote_dir}')"
            return 1
            ;;
    esac

    local remote_script="${remote_dir}/run.sh"
    local log_file="${remote_dir}/run.log"
    local exit_file="${remote_dir}/run.exit"

    # Write command to remote script via stdin
    if ! printf '%s\n' "$cmd" | _deploy_ssh "$user" "$host" "cat > '$remote_script' && chmod 700 '$remote_script'"; then
        log_error "[$host] Failed to upload remote script"
        _deploy_ssh "$user" "$host" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
        return 1
    fi

    # Launch via nohup (nohup wraps the entire command to ensure exit-code file is written)
    if ! _deploy_ssh "$user" "$host" "nohup sh -c 'sh \"$remote_script\" > \"$log_file\" 2>&1; echo \$? > \"$exit_file\"' </dev/null >/dev/null 2>&1 &"; then
        log_error "[$host] Failed to launch remote command"
        _deploy_ssh "$user" "$host" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
        return 1
    fi

    # Poll for completion
    local elapsed=0 _last_poll_err=""
    while [ $elapsed -lt $DEPLOY_REMOTE_TIMEOUT ]; do
        sleep "$DEPLOY_POLL_INTERVAL"
        elapsed=$((elapsed + DEPLOY_POLL_INTERVAL))

        if _last_poll_err=$(_deploy_ssh "$user" "$host" "test -f '$exit_file'" 2>&1 >/dev/null); then
            break
        fi

        # Show progress
        local progress_line
        progress_line=$(_deploy_ssh "$user" "$host" "tail -1 '$log_file'" 2>/dev/null || true)
        if [ -n "$progress_line" ]; then
            log_info "[$host] [${elapsed}s] $progress_line"
        fi
    done

    if [ $elapsed -ge $DEPLOY_REMOTE_TIMEOUT ]; then
        log_error "[$host] Timeout after ${DEPLOY_REMOTE_TIMEOUT}s: $desc"
        [ -n "$_last_poll_err" ] && log_error "[$host] Last poll error: $_last_poll_err"
        log_error "[$host] Remote log:"
        _deploy_ssh "$user" "$host" "cat '$log_file'" || true
        _deploy_ssh "$user" "$host" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
        return 1
    fi

    # Retrieve exit code
    local remote_exit
    remote_exit=$(_deploy_ssh "$user" "$host" "cat '$exit_file'" || echo "1")
    remote_exit=$(echo "$remote_exit" | tr -d '[:space:]')

    if ! echo "$remote_exit" | grep -qE '^[0-9]+$'; then
        log_error "[$host] Invalid exit code from remote: '$remote_exit'"
        _deploy_ssh "$user" "$host" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
        return 1
    fi

    if [ "$remote_exit" -ne 0 ]; then
        log_error "[$host] Failed (exit $remote_exit): $desc"
        log_error "[$host] Remote log:"
        _deploy_ssh "$user" "$host" "cat '$log_file'" || true
        _deploy_ssh "$user" "$host" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
        return 1
    fi

    # Clean up remote temp directory
    _deploy_ssh "$user" "$host" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true

    log_info "[$host] Completed: $desc"
    return 0
}

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

    log_info "SSH Settings:"
    log_info "  Default user: $DEPLOY_SSH_USER"
    log_info "  Port: $DEPLOY_SSH_PORT"
    if [ -n "$DEPLOY_SSH_KEY" ]; then
        log_info "  Key: $DEPLOY_SSH_KEY"
    fi
    if [ -n "$DEPLOY_SSH_PASSWORD" ]; then
        log_info "  Auth: password (sshpass)"
    fi
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
    log_info "Deploying Kubernetes cluster: ${cp_count} control-plane(s), ${w_count} worker(s)"

    # Inform about SSH host key policy
    if [ "${DEPLOY_SSH_HOST_KEY_CHECK}" = "yes" ] && [ -z "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        log_info "SSH strict host key checking is enabled."
        log_info "Provide known_hosts with --ssh-known-hosts to proceed:"
        log_info "  ssh-keyscan -H <node-ip> >> known_hosts  # collect fingerprints"
        log_info "  setup-k8s.sh deploy --ssh-known-hosts known_hosts ..."
    elif [ "${DEPLOY_SSH_HOST_KEY_CHECK}" = "accept-new" ]; then
        log_info "SSH host key check: accept-new (TOFU). New keys are accepted on first connect;"
        log_info "subsequent connections reject changed keys. For stricter security, use:"
        log_info "  --ssh-known-hosts known_hosts"
    fi

    # Create session-scoped known_hosts for MITM detection within this deploy
    if [ -n "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ] && [ -f "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        _DEPLOY_KNOWN_HOSTS=$(mktemp /tmp/deploy-known-hosts-XXXXXX)
        chmod 600 "$_DEPLOY_KNOWN_HOSTS"
        cp "$DEPLOY_SSH_KNOWN_HOSTS_FILE" "$_DEPLOY_KNOWN_HOSTS"
    else
        _DEPLOY_KNOWN_HOSTS=$(mktemp /tmp/deploy-known-hosts-XXXXXX)
        chmod 600 "$_DEPLOY_KNOWN_HOSTS"
    fi
    _cleanup_deploy_known_hosts() { rm -f "$_DEPLOY_KNOWN_HOSTS"; }
    _push_cleanup _cleanup_deploy_known_hosts

    # --- Step 1: Generate bundle ---
    local _step=0
    _step=$((_step + 1))
    log_info "Step ${_step}/${total_steps}: Generating deploy bundle..."
    local bundle_path
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
    _step=$((_step + 1))
    log_info "Step ${_step}/${total_steps}: Transferring bundle to all nodes..."
    _DEPLOY_NODE_BUNDLE_DIRS=""

    # Register cleanup handler for remote temp directories (best-effort on early failure)
    # Uses module-level globals so EXIT trap can access them after function returns
    _cleanup_deploy_remote_dirs() {
        local _all_cnt _ci _cleanup_node
        [ -z "$_DEPLOY_ALL_NODES" ] && return 0
        _all_cnt=$(_csv_count "$_DEPLOY_ALL_NODES")
        _ci=0
        while [ "$_ci" -lt "$_all_cnt" ]; do
            _cleanup_node=$(_csv_get "$_DEPLOY_ALL_NODES" "$_ci")
            _parse_node_address "$_cleanup_node"
            local _cdir
            _cdir=$(_bundle_dir_lookup "$_NODE_HOST")
            [ -n "$_cdir" ] && _deploy_ssh "$_NODE_USER" "$_NODE_HOST" "rm -rf '$_cdir'" >/dev/null 2>&1 || true
            _ci=$((_ci + 1))
        done
    }
    _push_cleanup _cleanup_deploy_remote_dirs

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
    log_info "Step ${_step}/${total_steps}: Initializing first control-plane..."
    local cp0
    cp0=$(_csv_get "$DEPLOY_CONTROL_PLANES" 0)
    _parse_node_address "$cp0"
    local cp1_user="$_NODE_USER" cp1_host="$_NODE_HOST"

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
        return 1
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
                return 1
            fi
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

    # --- Step 8: Clean up remote bundle directories ---
    _step=$((_step + 1))
    log_info "Step ${_step}/${total_steps}: Cleaning up remote bundle directories..."
    _cleanup_deploy_remote_dirs
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

    if [ "$worker_failed" = true ]; then
        log_error "Some worker joins failed. Check logs above."
        return 1
    fi

    # Clean up session-scoped known_hosts and restore previous cleanup handler
    _cleanup_deploy_known_hosts
    _pop_cleanup
    _DEPLOY_KNOWN_HOSTS=""

    log_info "Cluster deployment completed successfully!"
    return 0
}
