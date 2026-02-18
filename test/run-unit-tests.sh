#!/bin/bash
#
# Simple unit test framework for setup-k8s
# Run: bash test/run-unit-tests.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
        _assert_eq "ACTION default" "" "$ACTION"
        _assert_eq "CRI default" "containerd" "$CRI"
        _assert_eq "PROXY_MODE default" "iptables" "$PROXY_MODE"
        _assert_eq "FORCE default" "false" "$FORCE"
        _assert_eq "ENABLE_COMPLETION default" "true" "$ENABLE_COMPLETION"
        _assert_eq "INSTALL_HELM default" "false" "$INSTALL_HELM"
        _assert_eq "JOIN_AS_CONTROL_PLANE default" "false" "$JOIN_AS_CONTROL_PLANE"
        _assert_eq "HA_ENABLED default" "false" "$HA_ENABLED"
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

        ACTION="join"
        parse_setup_args --cri crio --kubernetes-version 1.31 \
            --join-token abc --join-address 1.2.3.4:6443 \
            --discovery-token-hash sha256:xyz \
            --proxy-mode ipvs --install-helm true \
            --pod-network-cidr 10.244.0.0/16 --service-cidr 10.96.0.0/12

        _assert_eq "ACTION" "join" "$ACTION"
        _assert_eq "CRI parsed" "crio" "$CRI"
        _assert_eq "K8S_VERSION parsed" "1.31" "$K8S_VERSION"
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

        ACTION="join"
        parse_setup_args --control-plane --certificate-key mykey123 \
            --join-token abc --join-address 1.2.3.4:6443 --discovery-token-hash sha256:xyz

        _assert_eq "JOIN_AS_CONTROL_PLANE" "true" "$JOIN_AS_CONTROL_PLANE"
        _assert_eq "CERTIFICATE_KEY" "mykey123" "$CERTIFICATE_KEY"
    )
}

# ============================================================
# Test: parse_setup_args HA kube-vip flags
# ============================================================
test_parse_ha_kube_vip_args() {
    echo "=== Test: parse_setup_args HA kube-vip flags ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        ACTION="init"
        parse_setup_args --ha --ha-vip 192.168.1.100 --ha-interface eth0

        _assert_eq "HA_ENABLED" "true" "$HA_ENABLED"
        _assert_eq "HA_VIP_ADDRESS" "192.168.1.100" "$HA_VIP_ADDRESS"
        _assert_eq "HA_VIP_INTERFACE" "eth0" "$HA_VIP_INTERFACE"
    )
}

# ============================================================
# Test: _kube_vip_kubeconfig_path version guard
# ============================================================
test_kube_vip_kubeconfig_path() {
    echo "=== Test: _kube_vip_kubeconfig_path version guard ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/helpers.sh"

        K8S_VERSION="1.35"
        _assert_eq "K8s 1.35 uses super-admin.conf" \
            "/etc/kubernetes/super-admin.conf" "$(_kube_vip_kubeconfig_path)"

        K8S_VERSION="1.29"
        _assert_eq "K8s 1.29 uses super-admin.conf" \
            "/etc/kubernetes/super-admin.conf" "$(_kube_vip_kubeconfig_path)"

        K8S_VERSION="1.28"
        _assert_eq "K8s 1.28 uses admin.conf" \
            "/etc/kubernetes/admin.conf" "$(_kube_vip_kubeconfig_path)"

        K8S_VERSION="1.27"
        _assert_eq "K8s 1.27 uses admin.conf" \
            "/etc/kubernetes/admin.conf" "$(_kube_vip_kubeconfig_path)"

        K8S_VERSION=""
        _assert_eq "empty version uses admin.conf" \
            "/etc/kubernetes/admin.conf" "$(_kube_vip_kubeconfig_path)"
    )
}

# ============================================================
# Test: _generate_kube_vip_manifest produces valid YAML
# ============================================================
test_generate_kube_vip_manifest() {
    echo "=== Test: _generate_kube_vip_manifest ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/helpers.sh"

        local manifest
        manifest=$(_generate_kube_vip_manifest "10.0.0.100" "eth0" "ghcr.io/kube-vip/kube-vip:v0.8.9" "/etc/kubernetes/super-admin.conf")

        local has_vip="false"
        if echo "$manifest" | grep -q 'value: "10.0.0.100"'; then has_vip="true"; fi
        _assert_eq "manifest contains VIP" "true" "$has_vip"

        local has_iface="false"
        if echo "$manifest" | grep -q 'value: "eth0"'; then has_iface="true"; fi
        _assert_eq "manifest contains interface" "true" "$has_iface"

        local has_kubeconfig="false"
        if echo "$manifest" | grep -q 'path: /etc/kubernetes/super-admin.conf'; then has_kubeconfig="true"; fi
        _assert_eq "manifest contains kubeconfig path" "true" "$has_kubeconfig"

        local has_image="false"
        if echo "$manifest" | grep -q 'image: ghcr.io/kube-vip/kube-vip:v0.8.9'; then has_image="true"; fi
        _assert_eq "manifest contains image" "true" "$has_image"
    )
}

# ============================================================
# Test: validate_ha_args for join --control-plane with --ha-vip
# ============================================================
test_validate_ha_join_cp() {
    echo "=== Test: validate_ha_args join --control-plane ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # join --control-plane with --ha-vip should pass (interface auto-detect may fail,
        # so provide it explicitly)
        ACTION="join"
        JOIN_AS_CONTROL_PLANE=true
        HA_VIP_ADDRESS="10.0.0.100"
        HA_VIP_INTERFACE="eth0"
        validate_ha_args
        _assert_eq "join CP with ha-vip passes" "10.0.0.100" "$HA_VIP_ADDRESS"

        # join worker with --ha-vip should fail
        ACTION="join"
        JOIN_AS_CONTROL_PLANE=false
        HA_VIP_ADDRESS="10.0.0.100"
        HA_VIP_INTERFACE="eth0"
        local exit_code=0
        (validate_ha_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "join worker with ha-vip rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _require_value catches missing arguments
# ============================================================
test_require_value() {
    echo "=== Test: _require_value argument guard ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # Simulating $# = 1 (only the flag, no value)
        local exit_code=0
        (_require_value 1 "--cri") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "_require_value rejects missing value" "0" "$exit_code"

        # Simulating $# = 2 (flag + value present)
        exit_code=0
        (_require_value 2 "--cri") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "_require_value accepts present value" "0" "$exit_code"
    )
}

# ============================================================
# Test: unknown option exits with non-zero
# ============================================================
test_unknown_option_exit_code() {
    echo "=== Test: unknown option exit code ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        local exit_code=0
        ACTION="init"
        (parse_setup_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "parse_setup_args rejects unknown option" "0" "$exit_code"

        exit_code=0
        (parse_cleanup_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "parse_cleanup_args rejects unknown option" "0" "$exit_code"
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
# Test: pipefail safety — awk pipelines must survive zero matches
# ============================================================
test_pipefail_safety() {
    echo "=== Test: pipefail safety (awk vs grep under set -euo pipefail) ==="

    # networking.sh: nft list tables | awk ... | while read
    # Simulate empty input (no k8s-related nft tables)
    _assert_exit_code "nft awk pipeline (no match)" 0 \
        bash -c "set -euo pipefail; echo '' | awk '/kube-proxy|kubernetes/ {print \$2, \$3}' | while read -r family name; do echo \"\$family \$name\"; done"

    # debian/kubernetes.sh: apt-cache madison | awk -v ver=...
    # Simulate no matching version
    _assert_exit_code "apt-cache awk pipeline (no match)" 0 \
        bash -c "set -euo pipefail; echo 'kubeadm | 1.30.0-1.1 | https://pkgs.k8s.io' | awk -v ver='9.99' '\$0 ~ ver {print \$3; exit}'"

    # suse/crio.sh: zypper | awk -F ... | sort | head
    # Simulate no matching package
    _assert_exit_code "zypper awk pipeline (no match)" 0 \
        bash -c "set -euo pipefail; echo 'no-match-here' | awk -F'kubernetes1.' '/kubernetes1\.[0-9]+-kubeadm/ {split(\$2,a,\"-\"); print a[1]}' | sort -nr | head -1"

    # debian/kubernetes.sh: awk early exit with large input must not SIGPIPE
    # Simulates apt-cache madison producing many lines; awk exits after first match
    _assert_exit_code "awk early exit on large input (no SIGPIPE)" 0 \
        bash -c "set -euo pipefail; madison_out=\$(seq 1 1000 | sed 's/^/kubeadm | 1.32./'); echo \"\$madison_out\" | awk -v ver='1.32' '\$0 ~ ver {print \$3; exit}'"

    # Same pattern but piped directly — would SIGPIPE under pipefail
    # Exit code varies by environment (141 locally, 1 on some CI), so just assert non-zero
    local sigpipe_exit=0
    bash -c 'set -euo pipefail; seq 1 100000 | awk "{print; exit}"' >/dev/null 2>&1 || sigpipe_exit=$?
    _assert_ne "direct pipe awk early exit SIGPIPE (sanity check)" "0" "$sigpipe_exit"

    # Negative test: confirm grep WOULD fail under pipefail
    _assert_exit_code "grep pipeline fails under pipefail (sanity check)" 1 \
        bash -c 'set -euo pipefail; echo "no-match" | grep "NOTFOUND" | head -1'
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
test_parse_ha_kube_vip_args
test_kube_vip_kubeconfig_path
test_generate_kube_vip_manifest
test_validate_ha_join_cp
test_require_value
test_unknown_option_exit_code
test_help_early_exit
test_validate_proxy_mode
test_pipefail_safety

echo ""
echo "==================================="
echo "Results: $TESTS_RUN tests, $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "==================================="

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
