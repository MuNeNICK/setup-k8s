#!/bin/sh
# Unit tests for upgrade version validation, step computation, and node role

# ============================================================
# Test: UPGRADE_* variable defaults
# ============================================================
test_upgrade_variables_defaults() {
    echo "=== Test: UPGRADE_* variable defaults ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        _assert_eq "UPGRADE_TARGET_VERSION default" "" "$UPGRADE_TARGET_VERSION"
        _assert_eq "UPGRADE_FIRST_CONTROL_PLANE default" "false" "$UPGRADE_FIRST_CONTROL_PLANE"
        _assert_eq "UPGRADE_SKIP_DRAIN default" "false" "$UPGRADE_SKIP_DRAIN"
    )
}

# ============================================================
# Test: parse_upgrade_local_args
# ============================================================
test_parse_upgrade_local_args() {
    echo "=== Test: parse_upgrade_local_args ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/lib/helpers.sh"
        source "$PROJECT_ROOT/lib/upgrade_helpers.sh"
        source "$PROJECT_ROOT/commands/upgrade.sh"

        parse_upgrade_local_args --kubernetes-version 1.33.2 --first-control-plane --skip-drain
        _assert_eq "UPGRADE_TARGET_VERSION parsed" "1.33.2" "$UPGRADE_TARGET_VERSION"
        _assert_eq "UPGRADE_FIRST_CONTROL_PLANE parsed" "true" "$UPGRADE_FIRST_CONTROL_PLANE"
        _assert_eq "UPGRADE_SKIP_DRAIN parsed" "true" "$UPGRADE_SKIP_DRAIN"
    )
}

# ============================================================
# Test: upgrade --kubernetes-version format validation
# ============================================================
test_upgrade_version_format() {
    echo "=== Test: upgrade --kubernetes-version format validation ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/lib/helpers.sh"
        source "$PROJECT_ROOT/lib/upgrade_helpers.sh"
        source "$PROJECT_ROOT/commands/upgrade.sh"

        # MAJOR.MINOR should be rejected (must be MAJOR.MINOR.PATCH)
        local exit_code=0
        (parse_upgrade_local_args --kubernetes-version 1.33) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "MAJOR.MINOR rejected" "0" "$exit_code"

        # MAJOR.MINOR.PATCH should be accepted
        exit_code=0
        (parse_upgrade_local_args --kubernetes-version 1.33.2) >/dev/null 2>&1 || exit_code=$?
        _assert_eq "MAJOR.MINOR.PATCH accepted" "0" "$exit_code"

        # Missing --kubernetes-version should be rejected
        exit_code=0
        (parse_upgrade_local_args --first-control-plane) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --kubernetes-version rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _k8s_minor_version extraction
# ============================================================
test_k8s_minor_version() {
    echo "=== Test: _k8s_minor_version extraction ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/helpers.sh"

        _assert_eq "_k8s_minor_version 1.33.2" "1.33" "$(_k8s_minor_version "1.33.2")"
        _assert_eq "_k8s_minor_version 1.28.0" "1.28" "$(_k8s_minor_version "1.28.0")"
        _assert_eq "_k8s_minor_version 2.0.1" "2.0" "$(_k8s_minor_version "2.0.1")"
    )
}

# ============================================================
# Test: _validate_upgrade_version constraints
# ============================================================
test_validate_upgrade_version() {
    echo "=== Test: _validate_upgrade_version constraints ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/upgrade_helpers.sh"
        source "$PROJECT_ROOT/commands/upgrade.sh"

        # +1 minor should be OK
        local exit_code=0
        (_validate_upgrade_version "1.32.0" "1.33.2") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "+1 minor allowed" "0" "$exit_code"

        # Same minor, higher patch should be OK
        exit_code=0
        (_validate_upgrade_version "1.32.0" "1.32.5") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "patch upgrade allowed" "0" "$exit_code"

        # +2 minor should be rejected
        exit_code=0
        (_validate_upgrade_version "1.31.0" "1.33.0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "+2 minor rejected" "0" "$exit_code"

        # Downgrade should be rejected
        exit_code=0
        (_validate_upgrade_version "1.33.0" "1.32.0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "downgrade rejected" "0" "$exit_code"

        # Same version should be rejected
        exit_code=0
        (_validate_upgrade_version "1.33.2" "1.33.2") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "same version rejected" "0" "$exit_code"

        # Patch downgrade should be rejected
        exit_code=0
        (_validate_upgrade_version "1.33.5" "1.33.2") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "patch downgrade rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _detect_node_role
# ============================================================
test_detect_node_role() {
    echo "=== Test: _detect_node_role ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/upgrade_helpers.sh"
        source "$PROJECT_ROOT/commands/upgrade.sh"

        # Without kube-apiserver manifest -> worker
        local role
        role=$(_detect_node_role)
        _assert_eq "no manifest = worker" "worker" "$role"

        # With UPGRADE_FIRST_CONTROL_PLANE=false and no manifest -> worker
        UPGRADE_FIRST_CONTROL_PLANE=true
        role=$(_detect_node_role)
        _assert_eq "no manifest + first-cp flag = still worker" "worker" "$role"
    )
}

# ============================================================
# Test: upgrade --help exits 0
# ============================================================
test_upgrade_help_exit() {
    echo "=== Test: upgrade --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh upgrade --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" upgrade --help
}

# ============================================================
# Test: _validate_upgrade_version format validation
# ============================================================
test_validate_upgrade_version_format() {
    echo "=== Test: _validate_upgrade_version format validation ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/upgrade_helpers.sh"
        source "$PROJECT_ROOT/commands/upgrade.sh"

        # Invalid format should be rejected
        local exit_code=0
        (_validate_upgrade_version "1.32" "1.33.0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "MAJOR.MINOR current rejected" "0" "$exit_code"

        exit_code=0
        (_validate_upgrade_version "1.32.0" "latest") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "non-numeric target rejected" "0" "$exit_code"

        exit_code=0
        (_validate_upgrade_version "" "1.33.0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "empty current rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: UPGRADE_NO_ROLLBACK default and --no-rollback parsing
# ============================================================
test_upgrade_rollback_flag() {
    echo "=== Test: --no-rollback flag ==="
    (
        source "$PROJECT_ROOT/lib/bootstrap.sh"
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/lib/helpers.sh"
        source "$PROJECT_ROOT/lib/ssh_args.sh"
        source "$PROJECT_ROOT/lib/ssh.sh"
        source "$PROJECT_ROOT/lib/ssh_session.sh"
        source "$PROJECT_ROOT/lib/upgrade_helpers.sh"
        source "$PROJECT_ROOT/commands/upgrade.sh"

        # Default value
        _assert_eq "UPGRADE_NO_ROLLBACK default" "false" "$UPGRADE_NO_ROLLBACK"

        # Parse --no-rollback in local mode
        UPGRADE_NO_ROLLBACK=false
        parse_upgrade_local_args --kubernetes-version 1.33.2 --no-rollback
        _assert_eq "--no-rollback parsed (local)" "true" "$UPGRADE_NO_ROLLBACK"

        # Parse --no-rollback in deploy mode
        UPGRADE_NO_ROLLBACK=false
        parse_upgrade_deploy_args --control-planes 10.0.0.1 --kubernetes-version 1.33.2 --no-rollback
        _assert_eq "--no-rollback parsed (deploy)" "true" "$UPGRADE_NO_ROLLBACK"
    )
}

# ============================================================
# Test: rollback helper functions exist
# ============================================================
test_rollback_functions() {
    echo "=== Test: rollback helper functions ==="
    (
        source "$PROJECT_ROOT/lib/bootstrap.sh"
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/lib/helpers.sh"
        source "$PROJECT_ROOT/lib/ssh_args.sh"
        source "$PROJECT_ROOT/lib/ssh.sh"
        source "$PROJECT_ROOT/lib/ssh_session.sh"
        source "$PROJECT_ROOT/lib/health.sh"
        source "$PROJECT_ROOT/lib/upgrade_helpers.sh"
        source "$PROJECT_ROOT/commands/upgrade.sh"

        local has_record="false"
        type _record_pre_upgrade_versions >/dev/null 2>&1 && has_record="true"
        _assert_eq "_record_pre_upgrade_versions defined" "true" "$has_record"

        local has_rollback="false"
        type _rollback_node >/dev/null 2>&1 && has_rollback="true"
        _assert_eq "_rollback_node defined" "true" "$has_rollback"
    )
}

# ============================================================
# Test: auto-step-upgrade default
# ============================================================
test_auto_step_upgrade_default() {
    echo "=== Test: auto-step-upgrade default ==="
    (
        . "$PROJECT_ROOT/lib/variables.sh"
        _assert_eq "UPGRADE_AUTO_STEP default" "false" "$UPGRADE_AUTO_STEP"
    )
}

# ============================================================
# Test: parse --auto-step-upgrade
# ============================================================
test_parse_auto_step_upgrade() {
    echo "=== Test: parse --auto-step-upgrade ==="
    (
        . "$PROJECT_ROOT/lib/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 1; }; }
        _parse_distro_arg() { :; }
        . "$PROJECT_ROOT/lib/validation.sh"
        . "$PROJECT_ROOT/lib/helpers.sh"
        . "$PROJECT_ROOT/lib/upgrade_helpers.sh"
        . "$PROJECT_ROOT/commands/upgrade.sh"

        parse_upgrade_local_args --kubernetes-version 1.33.2 --auto-step-upgrade
        _assert_eq "UPGRADE_AUTO_STEP parsed (local)" "true" "$UPGRADE_AUTO_STEP"
    )
}

# ============================================================
# Test: _compute_upgrade_steps function defined
# ============================================================
test_compute_upgrade_steps_defined() {
    echo "=== Test: _compute_upgrade_steps function defined ==="
    (
        . "$PROJECT_ROOT/lib/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { :; }
        . "$PROJECT_ROOT/lib/upgrade_helpers.sh"
        . "$PROJECT_ROOT/commands/upgrade.sh"

        local has_func="false"
        type _compute_upgrade_steps >/dev/null 2>&1 && has_func="true"
        _assert_eq "_compute_upgrade_steps defined" "true" "$has_func"
    )
}
