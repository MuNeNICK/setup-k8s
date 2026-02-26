#!/bin/sh
# Unit tests for commands/status.sh

# ============================================================
# Test: STATUS_OUTPUT_FORMAT default
# ============================================================
test_status_output_format_default() {
    echo "=== Test: STATUS_OUTPUT_FORMAT default ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        _assert_eq "STATUS_OUTPUT_FORMAT default" "text" "$STATUS_OUTPUT_FORMAT"
    )
}

# ============================================================
# Test: parse_status_args
# ============================================================
test_parse_status_args() {
    echo "=== Test: parse_status_args ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/commands/status.sh"

        parse_status_args --output wide
        _assert_eq "STATUS_OUTPUT_FORMAT parsed" "wide" "$STATUS_OUTPUT_FORMAT"
    )
}

# ============================================================
# Test: parse_status_args rejects invalid --output
# ============================================================
test_parse_status_args_invalid_output() {
    echo "=== Test: parse_status_args rejects invalid --output ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/commands/status.sh"

        local exit_code=0
        (parse_status_args --output json) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "invalid --output rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: parse_status_args rejects unknown option
# ============================================================
test_parse_status_unknown_option() {
    echo "=== Test: parse_status_args unknown option ==="
    (
        _load_status_ssh_test_modules
        source "$PROJECT_ROOT/lib/etcd_helpers.sh"
        source "$PROJECT_ROOT/commands/status.sh"

        local exit_code=0
        (parse_status_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "unknown option rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: status --help exits 0
# ============================================================
test_status_help_exit() {
    echo "=== Test: status --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh status --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" status --help
}

# File-local module loaders
_load_status_test_modules() {
    source "$PROJECT_ROOT/lib/variables.sh"
    source "$PROJECT_ROOT/lib/logging.sh"
    source "$PROJECT_ROOT/lib/validation.sh"
    source "$PROJECT_ROOT/lib/helpers.sh"
}

_load_status_ssh_test_modules() {
    _load_status_test_modules
    source "$PROJECT_ROOT/lib/ssh_args.sh"
    source "$PROJECT_ROOT/lib/ssh.sh"
    source "$PROJECT_ROOT/lib/ssh_session.sh"
}
