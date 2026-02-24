#!/bin/sh

# SSH module: shared SSH infrastructure for remote operations.
# Extracted from deploy.sh to eliminate duplication across deploy, upgrade, remove, renew, etcd.

# Session-scoped known_hosts file (set by _setup_session_known_hosts)
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
        # If SSH agent is available and no explicit key/password, skip BatchMode
        # to allow agent-based auth that may prompt for key passphrase
        if [ -z "${SSH_AUTH_SOCK:-}" ] || [ -n "$DEPLOY_SSH_KEY" ]; then
            _SSH_OPTS="$_SSH_OPTS -o BatchMode=yes"
        fi
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

# Parse node address: "user@ip" or "ip" -> sets _NODE_USER, _NODE_HOST
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
    while [ "$elapsed" -lt "$DEPLOY_REMOTE_TIMEOUT" ]; do
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

    if [ "$elapsed" -ge "$DEPLOY_REMOTE_TIMEOUT" ]; then
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

# --- Session-scoped known_hosts management ---

# Create a session-scoped known_hosts file, optionally seeded from a user-provided file.
# Registers a cleanup handler to remove it on exit.
# Usage: _setup_session_known_hosts <label>
_setup_session_known_hosts() {
    local label="${1:-session}"
    _DEPLOY_KNOWN_HOSTS=$(mktemp "/tmp/${label}-known-hosts-XXXXXX")
    chmod 600 "$_DEPLOY_KNOWN_HOSTS"
    if [ -n "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ] && [ -f "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        cp "$DEPLOY_SSH_KNOWN_HOSTS_FILE" "$_DEPLOY_KNOWN_HOSTS"
    fi
    _push_cleanup _teardown_session_known_hosts
}

# Clean up session-scoped known_hosts file.
# Persists to DEPLOY_PERSIST_KNOWN_HOSTS path if set.
# Usage: _teardown_session_known_hosts
_teardown_session_known_hosts() {
    if [ -n "${DEPLOY_PERSIST_KNOWN_HOSTS:-}" ] && [ -n "$_DEPLOY_KNOWN_HOSTS" ] && [ -f "$_DEPLOY_KNOWN_HOSTS" ]; then
        _persist_known_hosts "$DEPLOY_PERSIST_KNOWN_HOSTS"
    fi
    rm -f "$_DEPLOY_KNOWN_HOSTS"
    _DEPLOY_KNOWN_HOSTS=""
}

# --- Bundle generation and transfer ---

# Generate a self-contained bundle script for remote execution
generate_deploy_bundle() {
    local bundle_path="$1"
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
    _generate_bundle_core "$bundle_path" "$script_dir/setup-k8s.sh" "all" "$script_dir"
}

# Generate bundle, transfer to all nodes, and register cleanup handler.
# Expects _DEPLOY_ALL_NODES to be set (comma-separated node list).
# Sets _DEPLOY_NODE_BUNDLE_DIRS with host=dir mappings.
# Usage: _generate_and_transfer_bundle <label>
_generate_and_transfer_bundle() {
    local label="${1:-deploy}"
    local all_count
    all_count=$(_csv_count "$_DEPLOY_ALL_NODES")

    # Generate bundle
    local bundle_path
    bundle_path=$(mktemp "/tmp/setup-k8s-${label}-XXXXXX")
    chmod 600 "$bundle_path"
    generate_deploy_bundle "$bundle_path"
    log_info "Bundle generated: $(wc -c < "$bundle_path") bytes"

    # Register cleanup handler for remote temp directories
    _DEPLOY_NODE_BUNDLE_DIRS=""
    _push_cleanup _cleanup_remote_bundle_dirs

    # Transfer to all nodes
    local _i=0
    while [ "$_i" -lt "$all_count" ]; do
        local node
        node=$(_csv_get "$_DEPLOY_ALL_NODES" "$_i")
        _parse_node_address "$node"
        log_info "  [${_NODE_HOST}] Transferring bundle..."
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
}

# Clean up remote bundle directories on all nodes.
# Uses module-level globals so EXIT trap can access them.
_cleanup_remote_bundle_dirs() {
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

# --- SSH settings display ---

# Log current SSH settings (used by dry-run displays)
_log_ssh_settings() {
    log_info "SSH Settings:"
    log_info "  Default user: $DEPLOY_SSH_USER"
    log_info "  Port: $DEPLOY_SSH_PORT"
    [ -n "$DEPLOY_SSH_KEY" ] && log_info "  Key: $DEPLOY_SSH_KEY"
    [ -n "$DEPLOY_SSH_PASSWORD" ] && log_info "  Auth: password (sshpass)"
    if [ -n "${DEPLOY_SSH_PASSWORD_FILE:-}" ]; then
        log_info "  Auth: password file"
    fi
}

# --- SSH key permission validation ---

# Validate SSH key file permissions (warn if too permissive)
_validate_ssh_key_permissions() {
    if [ -z "$DEPLOY_SSH_KEY" ] || [ ! -f "$DEPLOY_SSH_KEY" ]; then
        return 0
    fi
    local perms
    perms=$(stat -c '%a' "$DEPLOY_SSH_KEY" 2>/dev/null || stat -f '%Lp' "$DEPLOY_SSH_KEY" 2>/dev/null) || return 0
    case "$perms" in
        600|400) ;;
        *)
            log_warn "SSH key '$DEPLOY_SSH_KEY' has permissions $perms (recommend 600 or 400)"
            ;;
    esac
}

# --- SSH key auto-discovery ---

# Auto-discover SSH private key from the invoking user's ~/.ssh/ directory.
# Searches: id_ed25519, id_rsa, id_ecdsa (in order of preference).
# Only sets DEPLOY_SSH_KEY if not already specified and a key file is found.
_auto_discover_ssh_key() {
    # Skip if already explicitly set
    [ -n "$DEPLOY_SSH_KEY" ] && return 0

    # Determine the home directory of the original (pre-sudo) user
    local ssh_home=""
    if [ -n "${SUDO_USER:-}" ]; then
        ssh_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)" || true
        [ -z "$ssh_home" ] && ssh_home="/home/$SUDO_USER"
    else
        ssh_home="${HOME:-}"
    fi
    [ -z "$ssh_home" ] && return 0

    local key_name
    for key_name in id_ed25519 id_rsa id_ecdsa; do
        if [ -f "${ssh_home}/.ssh/${key_name}" ]; then
            DEPLOY_SSH_KEY="${ssh_home}/.ssh/${key_name}"
            log_info "SSH key auto-discovered: $DEPLOY_SSH_KEY"
            return 0
        fi
    done
}

# --- SSH password file support ---

# Load SSH password from a file (validates permissions).
# Usage: _load_ssh_password_file <path>
_load_ssh_password_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        log_error "SSH password file not found: $path"
        return 1
    fi
    local perms
    perms=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null) || true
    case "$perms" in
        600|400) ;;
        *)
            log_error "SSH password file '$path' has permissions $perms (must be 600 or 400)"
            return 1
            ;;
    esac
    DEPLOY_SSH_PASSWORD=$(cat "$path")
    if [ -z "$DEPLOY_SSH_PASSWORD" ]; then
        log_error "SSH password file '$path' is empty"
        return 1
    fi
}

# --- known_hosts persistence ---

# Persist session known_hosts to a user-specified path for reuse.
# Usage: _persist_known_hosts <dest_path>
_persist_known_hosts() {
    local dest="$1"
    if [ -z "$_DEPLOY_KNOWN_HOSTS" ] || [ ! -f "$_DEPLOY_KNOWN_HOSTS" ]; then
        log_warn "No session known_hosts to persist"
        return 0
    fi
    cp "$_DEPLOY_KNOWN_HOSTS" "$dest"
    chmod 600 "$dest"
    log_info "Session known_hosts persisted to: $dest"
}
