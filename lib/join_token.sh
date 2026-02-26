#!/bin/sh

# Join token extraction from a control-plane node.
# Used by deploy orchestration to obtain kubeadm join credentials.

# Extract join information from the first control-plane node
# Sets: _JOIN_COMMAND, _JOIN_TOKEN, _JOIN_ADDR, _JOIN_HASH, _CERT_KEY
_extract_join_info() {
    local user="$1" host="$2"

    log_info "[$host] Extracting join information..."

    # Get join command (use sudo -n when not root for fail-fast on missing NOPASSWD)
    local sudo_pfx; sudo_pfx=$(_sudo_prefix "$user")
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
    if ! _validate_join_token_format "$_JOIN_TOKEN" "[$host] Join token"; then
        return 1
    fi
    if ! _validate_discovery_hash_format "$_JOIN_HASH" "[$host] Discovery token hash"; then
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
