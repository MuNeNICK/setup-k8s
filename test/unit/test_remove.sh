#!/bin/sh
# Unit tests for commands/remove.sh

# File-local module loader
_load_remove_test_modules() {
    source "$PROJECT_ROOT/lib/bootstrap.sh" >/dev/null 2>&1 || true
    source "$PROJECT_ROOT/lib/variables.sh"
    source "$PROJECT_ROOT/lib/logging.sh"
    source "$PROJECT_ROOT/lib/validation.sh"
    source "$PROJECT_ROOT/lib/helpers.sh"
    source "$PROJECT_ROOT/lib/ssh_args.sh"
    source "$PROJECT_ROOT/lib/ssh.sh"
    source "$PROJECT_ROOT/lib/ssh_session.sh"
}

# ============================================================
# Test: REMOVE_* variable defaults
# ============================================================
test_remove_variables_defaults() {
    echo "=== Test: REMOVE_* variable defaults ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        _assert_eq "REMOVE_CONTROL_PLANES default" "" "$REMOVE_CONTROL_PLANES"
        _assert_eq "REMOVE_NODES default" "" "$REMOVE_NODES"
        _assert_eq "REMOVE_PASSTHROUGH_ARGS default" "" "$REMOVE_PASSTHROUGH_ARGS"
    )
}

# ============================================================
# Test: parse_remove_args
# ============================================================
test_parse_remove_args() {
    echo "=== Test: parse_remove_args ==="
    (
        _load_remove_test_modules
        source "$PROJECT_ROOT/commands/remove.sh"

        parse_remove_args --control-planes root@10.0.0.1 --workers root@10.0.0.2,root@10.0.0.3 --force --ssh-port 2222
        _assert_eq "REMOVE_CONTROL_PLANES parsed" "root@10.0.0.1" "$REMOVE_CONTROL_PLANES"
        _assert_eq "REMOVE_NODES parsed" "root@10.0.0.2,root@10.0.0.3" "$REMOVE_NODES"
        _assert_eq "FORCE parsed" "true" "$FORCE"
        _assert_eq "DEPLOY_SSH_PORT parsed" "2222" "$DEPLOY_SSH_PORT"
    )
}

# ============================================================
# Test: parse_remove_args rejects unknown option
# ============================================================
test_parse_remove_unknown_option() {
    echo "=== Test: parse_remove_args unknown option ==="
    (
        _load_remove_test_modules
        source "$PROJECT_ROOT/commands/remove.sh"

        local exit_code=0
        (parse_remove_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "unknown option rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: validate_remove_args requires --control-planes and --workers
# ============================================================
test_validate_remove_args_required() {
    echo "=== Test: validate_remove_args requires args ==="
    (
        _load_remove_test_modules
        source "$PROJECT_ROOT/commands/remove.sh"

        # Missing --control-planes
        local exit_code=0
        REMOVE_NODES="10.0.0.2"
        (validate_remove_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --control-planes rejected" "0" "$exit_code"

        # Missing --workers
        exit_code=0
        REMOVE_CONTROL_PLANES="10.0.0.1"
        REMOVE_NODES=""
        (validate_remove_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --workers rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: validate_remove_args prevents removing CP itself
# ============================================================
test_validate_remove_args_cp_safety() {
    echo "=== Test: validate_remove_args CP safety ==="
    (
        _load_remove_test_modules
        source "$PROJECT_ROOT/commands/remove.sh"

        REMOVE_CONTROL_PLANES="root@10.0.0.1"
        REMOVE_NODES="root@10.0.0.1"
        local exit_code=0
        (validate_remove_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "removing CP node itself rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: remove --help exits 0
# ============================================================
test_remove_help_exit() {
    echo "=== Test: remove --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh remove --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" remove --help
}

# ============================================================
# Test: cleanup --help exits 0
# ============================================================
test_cleanup_help_exit() {
    echo "=== Test: cleanup --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh cleanup --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" cleanup --help
}

# ============================================================
# Test: help text contains 'remove' and 'cleanup'
# ============================================================
test_help_contains_remove_cleanup() {
    echo "=== Test: help text contains remove/cleanup ==="
    (
        local help_out
        help_out=$(bash "$PROJECT_ROOT/setup-k8s.sh" --help 2>&1)
        local has_remove="false"
        if echo "$help_out" | grep -q 'remove'; then has_remove="true"; fi
        _assert_eq "help contains remove" "true" "$has_remove"

        local has_cleanup="false"
        if echo "$help_out" | grep -q 'cleanup'; then has_cleanup="true"; fi
        _assert_eq "help contains cleanup" "true" "$has_cleanup"
    )
}
