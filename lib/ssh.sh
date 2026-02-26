#!/bin/sh

# SSH transport: low-level SSH/SCP operations and node address parsing.
# Argument parsing -> lib/ssh_args.sh | Session management -> lib/ssh_session.sh

# --- SSH Transport ---

# Session-scoped known_hosts file (set by _setup_session_known_hosts)
_DEPLOY_KNOWN_HOSTS=""

# --- SSH_ASKPASS infrastructure ---

_DEPLOY_ASKPASS_SCRIPT=""

# Create a temporary SSH_ASKPASS script that echoes the password.
# Called once during SSH session setup; cleaned up by _teardown_ssh_askpass.
_setup_ssh_askpass() {
    [ -n "$_DEPLOY_ASKPASS_SCRIPT" ] && return 0
    _DEPLOY_ASKPASS_SCRIPT=$(mktemp /tmp/.setup-k8s-askpass-XXXXXX)
    cat > "$_DEPLOY_ASKPASS_SCRIPT" <<'ASKPASS_EOF'
#!/bin/sh
echo "$DEPLOY_SSH_PASSWORD"
ASKPASS_EOF
    chmod 700 "$_DEPLOY_ASKPASS_SCRIPT"
}

_teardown_ssh_askpass() {
    [ -n "$_DEPLOY_ASKPASS_SCRIPT" ] && rm -f "$_DEPLOY_ASKPASS_SCRIPT"
    _DEPLOY_ASKPASS_SCRIPT=""
}

# Run a command with SSH_ASKPASS enabled for password authentication.
# Usage: _with_askpass <command...>
_with_askpass() {
    SSH_ASKPASS="$_DEPLOY_ASKPASS_SCRIPT" SSH_ASKPASS_REQUIRE=force DEPLOY_SSH_PASSWORD="$DEPLOY_SSH_PASSWORD" setsid -w "$@"
}

# --- SSH Infrastructure ---

# Build SSH options string (space-separated, no arrays)
# Sets: _SSH_OPTS (global string)
_build_deploy_ssh_opts() {
    local known_hosts="${_DEPLOY_KNOWN_HOSTS:-/dev/null}"
    local host_key_policy="${DEPLOY_SSH_HOST_KEY_CHECK:-yes}"
    _SSH_OPTS="-o StrictHostKeyChecking=$host_key_policy -o UserKnownHostsFile=$known_hosts -o LogLevel=ERROR -o ConnectTimeout=10"
    # Prevent interactive prompts in automated mode (BatchMode not used with password auth)
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
        _with_askpass ssh $_SSH_OPTS -- "${user}@${ssh_host}" "$@"
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

# Run scp with optional password auth
_run_scp() {
    if [ -n "$DEPLOY_SSH_PASSWORD" ]; then
        _with_askpass scp "$@"
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

# --- Node address parsing ---

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
