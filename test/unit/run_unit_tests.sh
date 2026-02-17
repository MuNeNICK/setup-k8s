#!/bin/bash
#
# Simple unit test framework for setup-k8s
# Run: bash test/unit/run_unit_tests.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test helpers
_assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: $desc (expected='$expected', actual='$actual')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

_assert_ne() {
    local desc="$1" not_expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$not_expected" != "$actual" ]; then
        echo "  PASS: $desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: $desc (should not be '$not_expected')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

_assert_exit_code() {
    local desc="$1" expected_code="$2"
    shift 2
    TESTS_RUN=$((TESTS_RUN + 1))
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?
    if [ "$expected_code" -eq "$actual_code" ]; then
        echo "  PASS: $desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: $desc (expected exit=$expected_code, actual exit=$actual_code)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================
# Test: variables.sh defaults
# ============================================================
test_variables_defaults() {
    echo "=== Test: variables.sh defaults ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        _assert_eq "LOG_LEVEL default" "1" "$LOG_LEVEL"
        _assert_eq "DRY_RUN default" "false" "$DRY_RUN"
        _assert_eq "NODE_TYPE default" "master" "$NODE_TYPE"
        _assert_eq "CRI default" "containerd" "$CRI"
        _assert_eq "PROXY_MODE default" "iptables" "$PROXY_MODE"
        _assert_eq "FORCE default" "false" "$FORCE"
        _assert_eq "ENABLE_COMPLETION default" "true" "$ENABLE_COMPLETION"
        _assert_eq "INSTALL_HELM default" "false" "$INSTALL_HELM"
        _assert_eq "JOIN_AS_CONTROL_PLANE default" "false" "$JOIN_AS_CONTROL_PLANE"
        _assert_eq "K8S_VERSION_FALLBACK default" "1.32" "$K8S_VERSION_FALLBACK"
        _assert_eq "KUBEADM_ARGS is array" "0" "${#KUBEADM_ARGS[@]}"
    )
}

# ============================================================
# Test: logging.sh functions
# ============================================================
test_logging() {
    echo "=== Test: logging.sh functions ==="
    source "$PROJECT_ROOT/common/logging.sh"

    # Test log_error always outputs
    local out
    out=$(LOG_LEVEL=0 log_error "test error" 2>&1)
    _assert_eq "log_error outputs at level 0" "ERROR: test error" "$out"

    # Test log_info suppressed at level 0
    out=$(LOG_LEVEL=0 log_info "test info" 2>&1)
    _assert_eq "log_info suppressed at level 0" "" "$out"

    # Test log_info visible at level 1
    out=$(LOG_LEVEL=1 log_info "test info" 2>&1)
    _assert_eq "log_info visible at level 1" "test info" "$out"

    # Test log_debug suppressed at level 1
    out=$(LOG_LEVEL=1 log_debug "test debug" 2>&1)
    _assert_eq "log_debug suppressed at level 1" "" "$out"

    # Test log_debug visible at level 2
    out=$(LOG_LEVEL=2 log_debug "test debug" 2>&1)
    _assert_eq "log_debug visible at level 2" "DEBUG: test debug" "$out"
}

# ============================================================
# Test: kernel version comparison logic
# ============================================================
test_kernel_version_comparison() {
    echo "=== Test: kernel version comparison ==="
    # Simulate the fixed comparison from networking.sh
    _check_kernel() {
        local major="$1" minor="$2"
        if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 13 ]; }; then
            echo "too_old"
        elif [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 14 ]; }; then
            echo "limited"
        else
            echo "ok"
        fi
    }
    _assert_eq "kernel 2.6 too old" "too_old" "$(_check_kernel 2 6)"
    _assert_eq "kernel 3.10 too old" "too_old" "$(_check_kernel 3 10)"
    _assert_eq "kernel 3.12 too old" "too_old" "$(_check_kernel 3 12)"
    _assert_eq "kernel 3.13 limited" "limited" "$(_check_kernel 3 13)"
    _assert_eq "kernel 4.0 limited" "limited" "$(_check_kernel 4 0)"
    _assert_eq "kernel 4.13 limited" "limited" "$(_check_kernel 4 13)"
    _assert_eq "kernel 4.14 ok" "ok" "$(_check_kernel 4 14)"
    _assert_eq "kernel 5.15 ok" "ok" "$(_check_kernel 5 15)"
    _assert_eq "kernel 6.1 ok" "ok" "$(_check_kernel 6 1)"
}

# ============================================================
# Test: parse_setup_args with KUBEADM_ARGS array
# ============================================================
test_parse_setup_args() {
    echo "=== Test: parse_setup_args ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        parse_setup_args --node-type worker --cri crio --kubernetes-version 1.31 \
            --join-token abc --join-address 1.2.3.4:6443 \
            --discovery-token-hash sha256:xyz \
            --proxy-mode ipvs --install-helm true \
            --pod-network-cidr 10.244.0.0/16 --service-cidr 10.96.0.0/12

        _assert_eq "NODE_TYPE parsed" "worker" "$NODE_TYPE"
        _assert_eq "CRI parsed" "crio" "$CRI"
        _assert_eq "K8S_VERSION parsed" "1.31" "$K8S_VERSION"
        _assert_eq "K8S_VERSION_USER_SET" "true" "$K8S_VERSION_USER_SET"
        _assert_eq "JOIN_TOKEN parsed" "abc" "$JOIN_TOKEN"
        _assert_eq "JOIN_ADDRESS parsed" "1.2.3.4:6443" "$JOIN_ADDRESS"
        _assert_eq "PROXY_MODE parsed" "ipvs" "$PROXY_MODE"
        _assert_eq "INSTALL_HELM parsed" "true" "$INSTALL_HELM"
        _assert_eq "KUBEADM_ARGS count" "4" "${#KUBEADM_ARGS[@]}"
        _assert_eq "KUBEADM_ARGS[0]" "--pod-network-cidr" "${KUBEADM_ARGS[0]}"
        _assert_eq "KUBEADM_ARGS[1]" "10.244.0.0/16" "${KUBEADM_ARGS[1]}"
    )
}

# ============================================================
# Test: parse_setup_args HA cluster flags
# ============================================================
test_parse_ha_args() {
    echo "=== Test: parse_setup_args HA cluster flags ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        parse_setup_args --node-type worker --control-plane --certificate-key mykey123 \
            --join-token abc --join-address 1.2.3.4:6443 --discovery-token-hash sha256:xyz

        _assert_eq "JOIN_AS_CONTROL_PLANE" "true" "$JOIN_AS_CONTROL_PLANE"
        _assert_eq "CERTIFICATE_KEY" "mykey123" "$CERTIFICATE_KEY"
    )
}

# ============================================================
# Test: --help early exit (no module download)
# ============================================================
test_help_early_exit() {
    echo "=== Test: --help early exit ==="
    _assert_exit_code "setup-k8s.sh --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" --help
    _assert_exit_code "cleanup-k8s.sh --help exits 0" 0 bash "$PROJECT_ROOT/cleanup-k8s.sh" --help
}

# ============================================================
# Test: validate_proxy_mode nftables version check
# ============================================================
test_validate_proxy_mode() {
    echo "=== Test: validate_proxy_mode ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # iptables should always pass
        PROXY_MODE="iptables"
        K8S_VERSION="1.28"
        validate_proxy_mode
        _assert_eq "iptables mode passes" "iptables" "$PROXY_MODE"

        # nftables with old version should fail (run in nested subshell
        # because validate_proxy_mode uses exit, not return)
        PROXY_MODE="nftables"
        K8S_VERSION="1.28"
        local exit_code=0
        (validate_proxy_mode) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "nftables 1.28 rejected" "0" "$exit_code"
    )
}

# ============================================================
# Run all tests
# ============================================================
echo "Running setup-k8s unit tests..."
echo ""

test_variables_defaults
test_logging
test_kernel_version_comparison
test_parse_setup_args
test_parse_ha_args
test_help_early_exit
test_validate_proxy_mode

echo ""
echo "==================================="
echo "Results: $TESTS_RUN tests, $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "==================================="

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
