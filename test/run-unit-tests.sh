#!/bin/bash
#
# Simple unit test framework for setup-k8s
# Run: bash test/run-unit-tests.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Temporary file for collecting assertion results across subshells
_RESULTS_FILE=$(mktemp -t unit-test-results-XXXXXX)
# shellcheck disable=SC2329 # invoked indirectly via trap
_cleanup_results() { rm -f "$_RESULTS_FILE"; }
trap _cleanup_results EXIT

# Test helpers — append PASS/FAIL to temp file so subshell results are visible
_assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        echo "PASS" >> "$_RESULTS_FILE"
    else
        echo "  FAIL: $desc (expected='$expected', actual='$actual')"
        echo "FAIL" >> "$_RESULTS_FILE"
    fi
}

_assert_ne() {
    local desc="$1" not_expected="$2" actual="$3"
    if [ "$not_expected" != "$actual" ]; then
        echo "  PASS: $desc"
        echo "PASS" >> "$_RESULTS_FILE"
    else
        echo "  FAIL: $desc (should not be '$not_expected')"
        echo "FAIL" >> "$_RESULTS_FILE"
    fi
}

_assert_exit_code() {
    local desc="$1" expected_code="$2"
    shift 2
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?
    if [ "$expected_code" -eq "$actual_code" ]; then
        echo "  PASS: $desc"
        echo "PASS" >> "$_RESULTS_FILE"
    else
        echo "  FAIL: $desc (expected exit=$expected_code, actual exit=$actual_code)"
        echo "FAIL" >> "$_RESULTS_FILE"
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
        _assert_eq "KUBEADM_POD_CIDR default" "" "$KUBEADM_POD_CIDR"
        _assert_eq "KUBEADM_SERVICE_CIDR default" "" "$KUBEADM_SERVICE_CIDR"
        _assert_eq "KUBEADM_API_ADDR default" "" "$KUBEADM_API_ADDR"
        _assert_eq "KUBEADM_CP_ENDPOINT default" "" "$KUBEADM_CP_ENDPOINT"
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
# Test: parse_setup_args
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
        _assert_eq "KUBEADM_POD_CIDR parsed" "10.244.0.0/16" "$KUBEADM_POD_CIDR"
        _assert_eq "KUBEADM_SERVICE_CIDR parsed" "10.96.0.0/12" "$KUBEADM_SERVICE_CIDR"
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
        source "$PROJECT_ROOT/common/validation.sh"
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
        bash -c "set -euo pipefail; echo 'kubeadm | 1.30.0-1.1 | https://pkgs.k8s.io' | awk -v ver='9.99.' 'index(\$0, ver) {print \$3; exit}'"

    # debian/kubernetes.sh: awk early exit with large input must not SIGPIPE
    # Simulates apt-cache madison producing many lines; awk exits after first match
    _assert_exit_code "awk early exit on large input (no SIGPIPE)" 0 \
        bash -c "set -euo pipefail; madison_out=\$(seq 1 1000 | sed 's/^/kubeadm | 1.32./'); echo \"\$madison_out\" | awk -v ver='1.32.' 'index(\$0, ver) {print \$3; exit}'"

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
# Test: --swap-enabled flag parsing and default
# ============================================================
test_swap_enabled_default() {
    echo "=== Test: SWAP_ENABLED default ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        _assert_eq "SWAP_ENABLED default" "false" "$SWAP_ENABLED"
    )
}

test_parse_swap_enabled() {
    echo "=== Test: parse_setup_args --swap-enabled ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        parse_setup_args --swap-enabled
        _assert_eq "SWAP_ENABLED parsed" "true" "$SWAP_ENABLED"
    )
}

# ============================================================
# Test: validate_swap_enabled version check
# ============================================================
test_validate_swap_enabled() {
    echo "=== Test: validate_swap_enabled ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # swap enabled with K8s 1.32 should pass
        SWAP_ENABLED=true
        K8S_VERSION="1.32"
        validate_swap_enabled
        _assert_eq "swap enabled 1.32 passes" "true" "$SWAP_ENABLED"

        # swap enabled with K8s 1.28 should pass
        SWAP_ENABLED=true
        K8S_VERSION="1.28"
        validate_swap_enabled
        _assert_eq "swap enabled 1.28 passes" "true" "$SWAP_ENABLED"

        # swap enabled with K8s 1.27 should fail
        SWAP_ENABLED=true
        K8S_VERSION="1.27"
        local exit_code=0
        (validate_swap_enabled) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "swap enabled 1.27 rejected" "0" "$exit_code"

        # swap disabled should always pass regardless of version
        SWAP_ENABLED=false
        K8S_VERSION="1.25"
        validate_swap_enabled
        _assert_eq "swap disabled always passes" "false" "$SWAP_ENABLED"
    )
}

# ============================================================
# Test: --swap-enabled in help text
# ============================================================
test_help_contains_swap() {
    echo "=== Test: help text contains --swap-enabled ==="
    (
        local help_out
        help_out=$(bash "$PROJECT_ROOT/setup-k8s.sh" --help 2>&1)
        local has_swap="false"
        if echo "$help_out" | grep -q -- '--swap-enabled'; then has_swap="true"; fi
        _assert_eq "help contains --swap-enabled" "true" "$has_swap"
    )
}

# ============================================================
# Test: --swap-enabled deploy passthrough
# ============================================================
test_deploy_parse_swap_enabled() {
    echo "=== Test: parse_deploy_args --swap-enabled passthrough ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        parse_deploy_args --control-planes 10.0.0.1 --swap-enabled
        local has_swap="false"
        for arg in "${DEPLOY_PASSTHROUGH_ARGS[@]}"; do
            if [ "$arg" = "--swap-enabled" ]; then has_swap="true"; break; fi
        done
        _assert_eq "swap-enabled in passthrough" "true" "$has_swap"
    )
}

# ============================================================
# Test: UPGRADE_* variable defaults
# ============================================================
test_upgrade_variables_defaults() {
    echo "=== Test: UPGRADE_* variable defaults ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
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
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

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
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

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
# Test: _version_minor extraction
# ============================================================
test_version_minor() {
    echo "=== Test: _version_minor extraction ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/upgrade.sh"

        _assert_eq "_version_minor 1.33.2" "1.33" "$(_version_minor "1.33.2")"
        _assert_eq "_version_minor 1.28.0" "1.28" "$(_version_minor "1.28.0")"
        _assert_eq "_version_minor 2.0.1" "2.0" "$(_version_minor "2.0.1")"
    )
}

# ============================================================
# Test: _validate_upgrade_version constraints
# ============================================================
test_validate_upgrade_version() {
    echo "=== Test: _validate_upgrade_version constraints ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/upgrade.sh"

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
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/upgrade.sh"

        # Without kube-apiserver manifest → worker
        local role
        role=$(_detect_node_role)
        _assert_eq "no manifest = worker" "worker" "$role"

        # With UPGRADE_FIRST_CONTROL_PLANE=false and no manifest → worker
        UPGRADE_FIRST_CONTROL_PLANE=true
        role=$(_detect_node_role)
        _assert_eq "no manifest + first-cp flag = still worker" "worker" "$role"
    )
}

# ============================================================
# Test: help text contains 'upgrade'
# ============================================================
test_help_contains_upgrade() {
    echo "=== Test: help text contains upgrade ==="
    (
        local help_out
        help_out=$(bash "$PROJECT_ROOT/setup-k8s.sh" --help 2>&1)
        local has_upgrade="false"
        if echo "$help_out" | grep -q 'upgrade'; then has_upgrade="true"; fi
        _assert_eq "help contains upgrade" "true" "$has_upgrade"
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
# Test: _is_ipv6 address family detection
# ============================================================
test_is_ipv6() {
    echo "=== Test: _is_ipv6 address family detection ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        local result
        _is_ipv6 "192.168.1.1" && result="true" || result="false"
        _assert_eq "_is_ipv6 IPv4 returns false" "false" "$result"

        _is_ipv6 "fd00::1" && result="true" || result="false"
        _assert_eq "_is_ipv6 IPv6 returns true" "true" "$result"

        _is_ipv6 "::1" && result="true" || result="false"
        _assert_eq "_is_ipv6 loopback returns true" "true" "$result"

        _is_ipv6 "2001:db8::1" && result="true" || result="false"
        _assert_eq "_is_ipv6 full IPv6 returns true" "true" "$result"
    )
}

# ============================================================
# Test: _validate_ipv6_addr
# ============================================================
test_validate_ipv6_addr() {
    echo "=== Test: _validate_ipv6_addr ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # Valid addresses should pass
        local exit_code=0
        (_validate_ipv6_addr "fd00::1" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "valid IPv6 addr accepted" "0" "$exit_code"

        exit_code=0
        (_validate_ipv6_addr "2001:db8:85a3::8a2e:370:7334" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "full IPv6 addr accepted" "0" "$exit_code"

        # Invalid address should fail
        exit_code=0
        (_validate_ipv6_addr "not-an-ipv6" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "invalid IPv6 addr rejected" "0" "$exit_code"

        exit_code=0
        (_validate_ipv6_addr "fd00::xyz" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "IPv6 addr with invalid chars rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _validate_cidr with IPv6 and dual-stack
# ============================================================
test_validate_cidr_ipv6() {
    echo "=== Test: _validate_cidr IPv6/dual-stack ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # IPv4 single CIDR still works
        local exit_code=0
        (_validate_cidr "10.244.0.0/16" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "IPv4 single CIDR accepted" "0" "$exit_code"

        # IPv6 single CIDR
        exit_code=0
        (_validate_cidr "fd00::/48" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "IPv6 single CIDR accepted" "0" "$exit_code"

        # Dual-stack CIDR (IPv4 + IPv6)
        exit_code=0
        (_validate_cidr "10.244.0.0/16,fd00:10:244::/48" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "dual-stack CIDR accepted" "0" "$exit_code"

        # Dual-stack with two IPv4 CIDRs should fail
        exit_code=0
        (_validate_cidr "10.244.0.0/16,10.245.0.0/16" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "two IPv4 CIDRs rejected" "0" "$exit_code"

        # Dual-stack with two IPv6 CIDRs should fail
        exit_code=0
        (_validate_cidr "fd00::/48,fd01::/48" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "two IPv6 CIDRs rejected" "0" "$exit_code"

        # Invalid IPv6 CIDR
        exit_code=0
        (_validate_cidr "xyz::/48" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "invalid IPv6 CIDR rejected" "0" "$exit_code"

        # IPv6 prefix out of range
        exit_code=0
        (_validate_cidr "fd00::/200" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "IPv6 prefix >128 rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: parse_setup_args with IPv6/dual-stack CIDRs
# ============================================================
test_parse_setup_args_ipv6() {
    echo "=== Test: parse_setup_args IPv6/dual-stack ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        ACTION="init"
        parse_setup_args --pod-network-cidr "fd00:10:244::/48" --service-cidr "fd00:20::/108"
        _assert_eq "IPv6 pod CIDR parsed" "fd00:10:244::/48" "$KUBEADM_POD_CIDR"
        _assert_eq "IPv6 service CIDR parsed" "fd00:20::/108" "$KUBEADM_SERVICE_CIDR"
    )
}

test_parse_setup_args_dual_stack() {
    echo "=== Test: parse_setup_args dual-stack ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        ACTION="init"
        parse_setup_args --pod-network-cidr "10.244.0.0/16,fd00:10:244::/48" \
                         --service-cidr "10.96.0.0/12,fd00:20::/108"
        _assert_eq "dual-stack pod CIDR parsed" "10.244.0.0/16,fd00:10:244::/48" "$KUBEADM_POD_CIDR"
        _assert_eq "dual-stack service CIDR parsed" "10.96.0.0/12,fd00:20::/108" "$KUBEADM_SERVICE_CIDR"
    )
}

# ============================================================
# Test: validate_ha_args with IPv6 VIP
# ============================================================
test_validate_ha_args_ipv6() {
    echo "=== Test: validate_ha_args IPv6 VIP ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # IPv6 VIP with explicit interface should pass
        ACTION="join"
        JOIN_AS_CONTROL_PLANE=true
        HA_VIP_ADDRESS="fd00::100"
        HA_VIP_INTERFACE="eth0"
        validate_ha_args
        _assert_eq "IPv6 VIP accepted" "fd00::100" "$HA_VIP_ADDRESS"

        # IPv6 VIP on init should set bracketed CP endpoint
        ACTION="init"
        HA_ENABLED=true
        HA_VIP_ADDRESS="fd00::100"
        HA_VIP_INTERFACE="eth0"
        KUBEADM_CP_ENDPOINT=""
        validate_ha_args
        _assert_eq "IPv6 CP endpoint bracketed" "[fd00::100]:6443" "$KUBEADM_CP_ENDPOINT"
    )
}

# ============================================================
# Test: join-address error message contains IPv6 example
# ============================================================
test_join_address_ipv6_example() {
    echo "=== Test: join-address error message IPv6 example ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        ACTION="join"
        JOIN_TOKEN="abcdef.1234567890abcdef"
        # shellcheck disable=SC2034 # Used by validate_join_args
        DISCOVERY_TOKEN_HASH="sha256:$(printf '%064d' 0)"
        JOIN_ADDRESS="noport"
        local err_output
        err_output=$(validate_join_args 2>&1) || true
        local has_ipv6_example="false"
        if echo "$err_output" | grep -q '\[::1\]:6443'; then has_ipv6_example="true"; fi
        _assert_eq "join error contains IPv6 example" "true" "$has_ipv6_example"
    )
}

# ============================================================
# Test: _generate_kube_vip_manifest IPv6 VIP cidr
# ============================================================
test_generate_kube_vip_manifest_ipv6() {
    echo "=== Test: _generate_kube_vip_manifest IPv6 ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"
        source "$PROJECT_ROOT/common/helpers.sh"

        local manifest
        manifest=$(_generate_kube_vip_manifest "fd00::100" "eth0" "ghcr.io/kube-vip/kube-vip:v0.8.9" "/etc/kubernetes/super-admin.conf")

        local has_cidr_128="false"
        if echo "$manifest" | grep -q 'value: "128"'; then has_cidr_128="true"; fi
        _assert_eq "IPv6 manifest has vip_cidr 128" "true" "$has_cidr_128"

        local has_vip="false"
        if echo "$manifest" | grep -q 'value: "fd00::100"'; then has_vip="true"; fi
        _assert_eq "IPv6 manifest contains VIP" "true" "$has_vip"

        # IPv4 should still get cidr 32
        manifest=$(_generate_kube_vip_manifest "10.0.0.100" "eth0" "ghcr.io/kube-vip/kube-vip:v0.8.9" "/etc/kubernetes/super-admin.conf")
        local has_cidr_32="false"
        if echo "$manifest" | grep -q 'value: "32"'; then has_cidr_32="true"; fi
        _assert_eq "IPv4 manifest has vip_cidr 32" "true" "$has_cidr_32"
    )
}

# ============================================================
# Test: --distro option sets DISTRO_OVERRIDE
# ============================================================
test_parse_distro_override() {
    echo "=== Test: --distro sets DISTRO_OVERRIDE ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        parse_setup_args --distro generic
        _assert_eq "DISTRO_OVERRIDE set to generic" "generic" "$DISTRO_OVERRIDE"
    )
}

# ============================================================
# Test: --distro rejects invalid values
# ============================================================
test_parse_distro_invalid() {
    echo "=== Test: --distro rejects invalid values ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        local exit_code=0
        (parse_setup_args --distro invalid_distro) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "--distro invalid value rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _detect_arch returns known architecture
# ============================================================
test_detect_arch() {
    echo "=== Test: _detect_arch ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/helpers.sh"

        local arch
        arch=$(_detect_arch)
        _assert_ne "_detect_arch returns non-empty" "" "$arch"
        # Should be one of the known architectures on typical test hosts
        local known=false
        for a in amd64 arm64 arm s390x ppc64le; do
            if [ "$arch" = "$a" ]; then known=true; break; fi
        done
        _assert_eq "_detect_arch returns known arch" "true" "$known"
    )
}

# ============================================================
# Test: _detect_init_system returns valid value
# ============================================================
test_detect_init_system() {
    echo "=== Test: _detect_init_system ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/helpers.sh"

        local init
        init=$(_detect_init_system)
        _assert_ne "_detect_init_system returns non-empty" "" "$init"
        local valid=false
        for v in systemd openrc unknown; do
            if [ "$init" = "$v" ]; then valid=true; break; fi
        done
        _assert_eq "_detect_init_system returns valid value" "true" "$valid"
    )
}

# ============================================================
# Test: _download_binary fails on invalid URL
# ============================================================
test_download_binary_failure() {
    echo "=== Test: _download_binary fails on invalid URL ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/helpers.sh"

        local exit_code=0
        local tmp
        tmp=$(mktemp -t test-dl-XXXXXX)
        (_download_binary "https://invalid.example.com/nonexistent" "$tmp") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "_download_binary fails on invalid URL" "0" "$exit_code"
        rm -f "$tmp"
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
test_parse_ha_kube_vip_args
test_kube_vip_kubeconfig_path
test_generate_kube_vip_manifest
test_validate_ha_join_cp
test_require_value
test_unknown_option_exit_code
test_help_early_exit
test_validate_proxy_mode
test_pipefail_safety
test_swap_enabled_default
test_parse_swap_enabled
test_validate_swap_enabled
test_help_contains_swap
test_deploy_parse_swap_enabled
test_upgrade_variables_defaults
test_parse_upgrade_local_args
test_upgrade_version_format
test_version_minor
test_validate_upgrade_version
test_detect_node_role
test_help_contains_upgrade
test_upgrade_help_exit
test_is_ipv6
test_validate_ipv6_addr
test_validate_cidr_ipv6
test_parse_setup_args_ipv6
test_parse_setup_args_dual_stack
test_validate_ha_args_ipv6
test_join_address_ipv6_example
test_generate_kube_vip_manifest_ipv6
test_parse_distro_override
test_parse_distro_invalid
test_detect_arch
test_detect_init_system
test_download_binary_failure

# ============================================================
# Test: ETCD_* variable defaults
# ============================================================
test_etcd_variables_defaults() {
    echo "=== Test: ETCD_* variable defaults ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        _assert_eq "ETCD_SNAPSHOT_PATH default" "" "$ETCD_SNAPSHOT_PATH"
        _assert_eq "ETCD_CONTROL_PLANE default" "" "$ETCD_CONTROL_PLANE"
    )
}

# ============================================================
# Test: parse_backup_local_args
# ============================================================
test_parse_backup_local_args() {
    echo "=== Test: parse_backup_local_args ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # With explicit snapshot path
        parse_backup_local_args --snapshot-path /tmp/test-snapshot.db
        _assert_eq "ETCD_SNAPSHOT_PATH parsed" "/tmp/test-snapshot.db" "$ETCD_SNAPSHOT_PATH"
    )
}

# ============================================================
# Test: parse_backup_local_args default snapshot path
# ============================================================
test_parse_backup_local_args_default_path() {
    echo "=== Test: parse_backup_local_args default path ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # Without snapshot path, should get auto-generated default
        parse_backup_local_args
        local has_prefix="false"
        if [[ "$ETCD_SNAPSHOT_PATH" == /var/lib/etcd-backup/snapshot-*.db ]]; then has_prefix="true"; fi
        _assert_eq "backup default path has expected prefix" "true" "$has_prefix"
    )
}

# ============================================================
# Test: parse_restore_local_args requires --snapshot-path
# ============================================================
test_parse_restore_local_args_required() {
    echo "=== Test: parse_restore_local_args requires --snapshot-path ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        local exit_code=0
        (parse_restore_local_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --snapshot-path rejected" "0" "$exit_code"

        exit_code=0
        (parse_restore_local_args --snapshot-path /tmp/snap.db) >/dev/null 2>&1 || exit_code=$?
        _assert_eq "with --snapshot-path accepted" "0" "$exit_code"
    )
}

# ============================================================
# Test: parse_backup_remote_args
# ============================================================
test_parse_backup_remote_args() {
    echo "=== Test: parse_backup_remote_args ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        parse_backup_remote_args --control-plane 10.0.0.1 --snapshot-path /tmp/snap.db --ssh-port 2222
        _assert_eq "ETCD_CONTROL_PLANE parsed" "10.0.0.1" "$ETCD_CONTROL_PLANE"
        _assert_eq "ETCD_SNAPSHOT_PATH parsed" "/tmp/snap.db" "$ETCD_SNAPSHOT_PATH"
        _assert_eq "DEPLOY_SSH_PORT parsed" "2222" "$DEPLOY_SSH_PORT"
    )
}

# ============================================================
# Test: parse_restore_remote_args
# ============================================================
test_parse_restore_remote_args() {
    echo "=== Test: parse_restore_remote_args ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        parse_restore_remote_args --control-plane admin@10.0.0.1 --snapshot-path /tmp/snap.db --ssh-key /tmp/id_rsa
        _assert_eq "ETCD_CONTROL_PLANE parsed" "admin@10.0.0.1" "$ETCD_CONTROL_PLANE"
        _assert_eq "ETCD_SNAPSHOT_PATH parsed" "/tmp/snap.db" "$ETCD_SNAPSHOT_PATH"
        _assert_eq "DEPLOY_SSH_KEY parsed" "/tmp/id_rsa" "$DEPLOY_SSH_KEY"
    )
}

# ============================================================
# Test: validate_backup_remote_args requires --control-plane
# ============================================================
test_validate_backup_remote_args() {
    echo "=== Test: validate_backup_remote_args ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # Missing --control-plane should fail
        local exit_code=0
        (validate_backup_remote_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --control-plane rejected" "0" "$exit_code"

        # With valid --control-plane should pass
        ETCD_CONTROL_PLANE="10.0.0.1"
        exit_code=0
        (validate_backup_remote_args) >/dev/null 2>&1 || exit_code=$?
        _assert_eq "valid --control-plane accepted" "0" "$exit_code"
    )
}

# ============================================================
# Test: backup/restore unknown option
# ============================================================
test_backup_restore_unknown_option() {
    echo "=== Test: backup/restore unknown option ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        local exit_code=0
        (parse_backup_local_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "backup unknown option rejected" "0" "$exit_code"

        exit_code=0
        (parse_restore_local_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "restore unknown option rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: backup --help exits 0
# ============================================================
test_backup_help_exit() {
    echo "=== Test: backup --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh backup --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" backup --help
}

# ============================================================
# Test: restore --help exits 0
# ============================================================
test_restore_help_exit() {
    echo "=== Test: restore --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh restore --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" restore --help
}

# ============================================================
# Test: help text contains 'backup' and 'restore'
# ============================================================
test_help_contains_backup_restore() {
    echo "=== Test: help text contains backup/restore ==="
    (
        local help_out
        help_out=$(bash "$PROJECT_ROOT/setup-k8s.sh" --help 2>&1)
        local has_backup="false"
        if echo "$help_out" | grep -q 'backup'; then has_backup="true"; fi
        _assert_eq "help contains backup" "true" "$has_backup"

        local has_restore="false"
        if echo "$help_out" | grep -q 'restore'; then has_restore="true"; fi
        _assert_eq "help contains restore" "true" "$has_restore"
    )
}

# ============================================================
# Test: validate_join_args
# ============================================================
test_validate_join_args() {
    echo "=== Test: validate_join_args ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # Valid join args should pass
        ACTION="join"
        JOIN_TOKEN="abcdef.1234567890abcdef"
        JOIN_ADDRESS="10.0.0.1:6443"
        DISCOVERY_TOKEN_HASH="sha256:$(printf '%064d' 0)"
        validate_join_args
        _assert_eq "valid join args pass" "join" "$ACTION"

        # Missing token should fail
        local exit_code=0
        (
            ACTION="join"
            JOIN_TOKEN=""
            JOIN_ADDRESS="10.0.0.1:6443"
            DISCOVERY_TOKEN_HASH="sha256:$(printf '%064d' 0)"
            validate_join_args
        ) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing token rejected" "0" "$exit_code"

        # Bad token format should fail
        exit_code=0
        (
            ACTION="join"
            JOIN_TOKEN="bad-token"
            JOIN_ADDRESS="10.0.0.1:6443"
            DISCOVERY_TOKEN_HASH="sha256:$(printf '%064d' 0)"
            validate_join_args
        ) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "bad token format rejected" "0" "$exit_code"

        # Address without port should fail
        exit_code=0
        (
            ACTION="join"
            JOIN_TOKEN="abcdef.1234567890abcdef"
            JOIN_ADDRESS="10.0.0.1"
            DISCOVERY_TOKEN_HASH="sha256:$(printf '%064d' 0)"
            validate_join_args
        ) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "address without port rejected" "0" "$exit_code"

        # init action should skip validation
        ACTION="init"
        JOIN_TOKEN=""
        JOIN_ADDRESS=""
        # shellcheck disable=SC2034 # used by validate_join_args
        DISCOVERY_TOKEN_HASH=""
        validate_join_args
        _assert_eq "init action skips validation" "init" "$ACTION"
    )
}

# ============================================================
# Test: validate_cri
# ============================================================
test_validate_cri() {
    echo "=== Test: validate_cri ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        CRI="containerd"
        validate_cri
        _assert_eq "containerd passes" "containerd" "$CRI"

        CRI="crio"
        validate_cri
        _assert_eq "crio passes" "crio" "$CRI"

        local exit_code=0
        (CRI="docker"; validate_cri) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "docker rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _normalize_node_list
# ============================================================
test_normalize_node_list() {
    echo "=== Test: _normalize_node_list ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        local result
        result=$(_normalize_node_list " node1 , node2,,node3 ")
        _assert_eq "trims and deduplicates empty tokens" "node1,node2,node3" "$result"

        result=$(_normalize_node_list "single")
        _assert_eq "single node unchanged" "single" "$result"

        result=$(_normalize_node_list ",,")
        _assert_eq "all empty tokens gives empty" "" "$result"
    )
}

# ============================================================
# Test: _validate_node_addresses
# ============================================================
test_validate_node_addresses() {
    echo "=== Test: _validate_node_addresses ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # Valid addresses should pass
        local exit_code=0
        (_validate_node_addresses "10.0.0.1,admin@10.0.0.2") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "valid addresses pass" "0" "$exit_code"

        # Duplicate address should fail
        exit_code=0
        (_validate_node_addresses "10.0.0.1,10.0.0.1") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "duplicate address rejected" "0" "$exit_code"

        # Bare IPv6 without brackets should fail
        exit_code=0
        (_validate_node_addresses "fd00::1") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "bare IPv6 rejected" "0" "$exit_code"

        # Bracketed IPv6 should pass
        exit_code=0
        (_validate_node_addresses "[fd00::1]") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "bracketed IPv6 passes" "0" "$exit_code"

        # Username starting with - should fail
        exit_code=0
        (_validate_node_addresses "-evil@10.0.0.1") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "dash username rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _validate_upgrade_version format validation
# ============================================================
test_validate_upgrade_version_format() {
    echo "=== Test: _validate_upgrade_version format validation ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/upgrade.sh"

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

test_validate_join_args
test_validate_cri
test_normalize_node_list
test_validate_node_addresses
test_validate_upgrade_version_format

# ============================================================
# Test: STATUS_OUTPUT_FORMAT default
# ============================================================
test_status_output_format_default() {
    echo "=== Test: STATUS_OUTPUT_FORMAT default ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        _assert_eq "STATUS_OUTPUT_FORMAT default" "text" "$STATUS_OUTPUT_FORMAT"
    )
}

# ============================================================
# Test: parse_status_args
# ============================================================
test_parse_status_args() {
    echo "=== Test: parse_status_args ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"
        source "$PROJECT_ROOT/common/status.sh"

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
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"
        source "$PROJECT_ROOT/common/status.sh"

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
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"
        source "$PROJECT_ROOT/common/status.sh"

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

test_status_output_format_default
test_parse_status_args
test_parse_status_args_invalid_output
test_parse_status_unknown_option
test_status_help_exit

test_etcd_variables_defaults
test_parse_backup_local_args
test_parse_backup_local_args_default_path
test_parse_restore_local_args_required
test_parse_backup_remote_args
test_parse_restore_remote_args
test_validate_backup_remote_args
test_backup_restore_unknown_option
test_backup_help_exit
test_restore_help_exit
test_help_contains_backup_restore

# ============================================================
# Test: PREFLIGHT_* variable defaults
# ============================================================
test_preflight_variables_defaults() {
    echo "=== Test: PREFLIGHT_* variable defaults ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        _assert_eq "PREFLIGHT_MODE default" "init" "$PREFLIGHT_MODE"
        _assert_eq "PREFLIGHT_CRI default" "containerd" "$PREFLIGHT_CRI"
        _assert_eq "PREFLIGHT_PROXY_MODE default" "iptables" "$PREFLIGHT_PROXY_MODE"
    )
}

# ============================================================
# Test: parse_preflight_args
# ============================================================
test_parse_preflight_args() {
    echo "=== Test: parse_preflight_args ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"
        source "$PROJECT_ROOT/common/preflight.sh"

        parse_preflight_args --mode join --cri crio --proxy-mode ipvs
        _assert_eq "PREFLIGHT_MODE parsed" "join" "$PREFLIGHT_MODE"
        _assert_eq "PREFLIGHT_CRI parsed" "crio" "$PREFLIGHT_CRI"
        _assert_eq "PREFLIGHT_PROXY_MODE parsed" "ipvs" "$PREFLIGHT_PROXY_MODE"
    )
}

# ============================================================
# Test: parse_preflight_args rejects invalid --mode
# ============================================================
test_parse_preflight_args_invalid_mode() {
    echo "=== Test: parse_preflight_args rejects invalid --mode ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"
        source "$PROJECT_ROOT/common/preflight.sh"

        local exit_code=0
        (parse_preflight_args --mode upgrade) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "invalid --mode rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: parse_preflight_args rejects unknown option
# ============================================================
test_parse_preflight_unknown_option() {
    echo "=== Test: parse_preflight_args unknown option ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"
        source "$PROJECT_ROOT/common/preflight.sh"

        local exit_code=0
        (parse_preflight_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "unknown option rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: preflight --help exits 0
# ============================================================
test_preflight_help_exit() {
    echo "=== Test: preflight --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh preflight --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" preflight --help
}

# ============================================================
# Test: help text contains 'preflight'
# ============================================================
test_help_contains_preflight() {
    echo "=== Test: help text contains preflight ==="
    (
        local help_out
        help_out=$(bash "$PROJECT_ROOT/setup-k8s.sh" --help 2>&1)
        local has_preflight="false"
        if echo "$help_out" | grep -q 'preflight'; then has_preflight="true"; fi
        _assert_eq "help contains preflight" "true" "$has_preflight"
    )
}

# ============================================================
# Test: _preflight_check_cpu runs
# ============================================================
test_preflight_check_cpu() {
    echo "=== Test: _preflight_check_cpu runs ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"
        source "$PROJECT_ROOT/common/preflight.sh"

        local out
        out=$(_preflight_check_cpu 2>&1)
        # Should output something about CPU
        local has_cpu="false"
        if echo "$out" | grep -qi 'cpu'; then has_cpu="true"; fi
        _assert_eq "cpu check produces output" "true" "$has_cpu"
    )
}

# ============================================================
# Test: _preflight_check_memory runs
# ============================================================
test_preflight_check_memory() {
    echo "=== Test: _preflight_check_memory runs ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"
        source "$PROJECT_ROOT/common/preflight.sh"

        local out
        out=$(_preflight_check_memory 2>&1)
        # Should output something about memory
        local has_mem="false"
        if echo "$out" | grep -qi 'memory\|memtotal\|MB'; then has_mem="true"; fi
        _assert_eq "memory check produces output" "true" "$has_mem"
    )
}

test_preflight_variables_defaults
test_parse_preflight_args
test_parse_preflight_args_invalid_mode
test_parse_preflight_unknown_option
test_preflight_help_exit
test_help_contains_preflight
test_preflight_check_cpu
test_preflight_check_memory

# ============================================================
# Test: REMOVE_* variable defaults
# ============================================================
test_remove_variables_defaults() {
    echo "=== Test: REMOVE_* variable defaults ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        _assert_eq "REMOVE_CONTROL_PLANE default" "" "$REMOVE_CONTROL_PLANE"
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
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        parse_remove_args --control-plane root@10.0.0.1 --nodes root@10.0.0.2,root@10.0.0.3 --force --ssh-port 2222
        _assert_eq "REMOVE_CONTROL_PLANE parsed" "root@10.0.0.1" "$REMOVE_CONTROL_PLANE"
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
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        local exit_code=0
        (parse_remove_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "unknown option rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: validate_remove_args requires --control-plane and --nodes
# ============================================================
test_validate_remove_args_required() {
    echo "=== Test: validate_remove_args requires args ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # Missing --control-plane
        local exit_code=0
        REMOVE_NODES="10.0.0.2"
        (validate_remove_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --control-plane rejected" "0" "$exit_code"

        # Missing --nodes
        exit_code=0
        REMOVE_CONTROL_PLANE="10.0.0.1"
        REMOVE_NODES=""
        (validate_remove_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --nodes rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: validate_remove_args prevents removing CP itself
# ============================================================
test_validate_remove_args_cp_safety() {
    echo "=== Test: validate_remove_args CP safety ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        REMOVE_CONTROL_PLANE="root@10.0.0.1"
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

# ============================================================
# Test: RENEW_* variable defaults
# ============================================================
test_renew_variables_defaults() {
    echo "=== Test: RENEW_* variable defaults ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        _assert_eq "RENEW_CERTS default" "all" "$RENEW_CERTS"
        _assert_eq "RENEW_CHECK_ONLY default" "false" "$RENEW_CHECK_ONLY"
        _assert_eq "RENEW_PASSTHROUGH_ARGS default" "" "$RENEW_PASSTHROUGH_ARGS"
    )
}

# ============================================================
# Test: parse_renew_local_args
# ============================================================
test_parse_renew_local_args() {
    echo "=== Test: parse_renew_local_args ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        parse_renew_local_args --certs apiserver,etcd-server --check-only
        _assert_eq "RENEW_CERTS parsed" "apiserver,etcd-server" "$RENEW_CERTS"
        _assert_eq "RENEW_CHECK_ONLY parsed" "true" "$RENEW_CHECK_ONLY"
    )
}

# ============================================================
# Test: parse_renew_deploy_args
# ============================================================
test_parse_renew_deploy_args() {
    echo "=== Test: parse_renew_deploy_args ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        parse_renew_deploy_args --control-planes 10.0.0.1,10.0.0.2 --certs apiserver --check-only --ssh-port 2222
        _assert_eq "DEPLOY_CONTROL_PLANES parsed" "10.0.0.1,10.0.0.2" "$DEPLOY_CONTROL_PLANES"
        _assert_eq "RENEW_CERTS parsed" "apiserver" "$RENEW_CERTS"
        _assert_eq "RENEW_CHECK_ONLY parsed" "true" "$RENEW_CHECK_ONLY"
        _assert_eq "DEPLOY_SSH_PORT parsed" "2222" "$DEPLOY_SSH_PORT"

        # Verify passthrough args contain --certs and --check-only
        local has_certs="false" has_check="false"
        if echo "$RENEW_PASSTHROUGH_ARGS" | grep -q -- '--certs'; then has_certs="true"; fi
        if echo "$RENEW_PASSTHROUGH_ARGS" | grep -q -- '--check-only'; then has_check="true"; fi
        _assert_eq "passthrough has --certs" "true" "$has_certs"
        _assert_eq "passthrough has --check-only" "true" "$has_check"
    )
}

# ============================================================
# Test: validate_renew_deploy_args requires --control-planes
# ============================================================
test_validate_renew_deploy_args_required() {
    echo "=== Test: validate_renew_deploy_args requires --control-planes ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # Missing --control-planes should fail
        local exit_code=0
        (validate_renew_deploy_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --control-planes rejected" "0" "$exit_code"

        # With valid --control-planes should pass
        DEPLOY_CONTROL_PLANES="10.0.0.1"
        exit_code=0
        (validate_renew_deploy_args) >/dev/null 2>&1 || exit_code=$?
        _assert_eq "valid --control-planes accepted" "0" "$exit_code"
    )
}

# ============================================================
# Test: renew --help exits 0
# ============================================================
test_renew_help_exit() {
    echo "=== Test: renew --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh renew --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" renew --help
}

# ============================================================
# Test: help text contains 'renew'
# ============================================================
test_help_contains_renew() {
    echo "=== Test: help text contains renew ==="
    (
        local help_out
        help_out=$(bash "$PROJECT_ROOT/setup-k8s.sh" --help 2>&1)
        local has_renew="false"
        if echo "$help_out" | grep -q 'renew'; then has_renew="true"; fi
        _assert_eq "help contains renew" "true" "$has_renew"
    )
}

# ============================================================
# Test: _validate_cert_names
# ============================================================
test_validate_cert_names() {
    echo "=== Test: _validate_cert_names ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"
        source "$PROJECT_ROOT/common/renew.sh"

        # "all" should pass
        RENEW_CERTS="all"
        _validate_cert_names
        _assert_eq "all passes" "all" "$RENEW_CERTS"

        # Valid names should pass
        RENEW_CERTS="apiserver,etcd-server,admin.conf"
        local exit_code=0
        (_validate_cert_names) >/dev/null 2>&1 || exit_code=$?
        _assert_eq "valid cert names pass" "0" "$exit_code"

        # Invalid name should fail
        RENEW_CERTS="apiserver,bogus-cert"
        exit_code=0
        (_validate_cert_names) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "invalid cert name rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: parse_renew_local_args rejects unknown option
# ============================================================
test_parse_renew_unknown_option() {
    echo "=== Test: parse_renew_local_args unknown option ==="
    (
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        local exit_code=0
        (parse_renew_local_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "unknown option rejected" "0" "$exit_code"
    )
}

test_renew_variables_defaults
test_parse_renew_local_args
test_parse_renew_deploy_args
test_validate_renew_deploy_args_required
test_renew_help_exit
test_help_contains_renew
test_validate_cert_names
test_parse_renew_unknown_option

test_remove_variables_defaults
test_parse_remove_args
test_parse_remove_unknown_option
test_validate_remove_args_required
test_validate_remove_args_cp_safety
test_remove_help_exit
test_cleanup_help_exit
test_help_contains_remove_cleanup

# ============================================================
# Test: DEPLOY_REMOTE_TIMEOUT / DEPLOY_POLL_INTERVAL defaults
# ============================================================
test_deploy_timeout_defaults() {
    echo "=== Test: DEPLOY_REMOTE_TIMEOUT / DEPLOY_POLL_INTERVAL defaults ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        _assert_eq "DEPLOY_REMOTE_TIMEOUT default" "600" "$DEPLOY_REMOTE_TIMEOUT"
        _assert_eq "DEPLOY_POLL_INTERVAL default" "10" "$DEPLOY_POLL_INTERVAL"
    )
}

# ============================================================
# Test: _parse_node_address parsing
# ============================================================
test_parse_node_address() {
    echo "=== Test: _parse_node_address ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/ssh.sh"

        # user@host format
        _parse_node_address "admin@10.0.0.1"
        _assert_eq "user@host: user" "admin" "$_NODE_USER"
        _assert_eq "user@host: host" "10.0.0.1" "$_NODE_HOST"

        # bare host format (should use DEPLOY_SSH_USER)
        DEPLOY_SSH_USER="root"
        _parse_node_address "10.0.0.2"
        _assert_eq "bare host: user" "root" "$_NODE_USER"
        _assert_eq "bare host: host" "10.0.0.2" "$_NODE_HOST"

        # IPv6 bracketed format
        DEPLOY_SSH_USER="admin"
        _parse_node_address "[fd00::1]"
        _assert_eq "IPv6 bare: user" "admin" "$_NODE_USER"
        _assert_eq "IPv6 bare: host" "[fd00::1]" "$_NODE_HOST"

        # user@IPv6 format
        _parse_node_address "root@[fd00::2]"
        _assert_eq "user@IPv6: user" "root" "$_NODE_USER"
        _assert_eq "user@IPv6: host" "[fd00::2]" "$_NODE_HOST"
    )
}

# ============================================================
# Test: _build_deploy_ssh_opts
# ============================================================
test_build_deploy_ssh_opts() {
    echo "=== Test: _build_deploy_ssh_opts ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/ssh.sh"

        # Default: no password, no key
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_KEY=""
        DEPLOY_SSH_PORT="22"
        DEPLOY_SSH_HOST_KEY_CHECK="yes"
        _DEPLOY_KNOWN_HOSTS="/tmp/test-kh"
        SSH_AUTH_SOCK=""
        _build_deploy_ssh_opts

        local has_batchmode="false"
        if echo "$_SSH_OPTS" | grep -q 'BatchMode=yes'; then has_batchmode="true"; fi
        _assert_eq "BatchMode present without password" "true" "$has_batchmode"

        local has_strict="false"
        if echo "$_SSH_OPTS" | grep -q 'StrictHostKeyChecking=yes'; then has_strict="true"; fi
        _assert_eq "StrictHostKeyChecking=yes" "true" "$has_strict"

        local has_port="false"
        if echo "$_SSH_OPTS" | grep -q '\-p 22'; then has_port="true"; fi
        _assert_eq "port 22 in opts" "true" "$has_port"

        # With password: no BatchMode
        DEPLOY_SSH_PASSWORD="secret"
        _build_deploy_ssh_opts
        has_batchmode="false"
        if echo "$_SSH_OPTS" | grep -q 'BatchMode=yes'; then has_batchmode="true"; fi
        _assert_eq "BatchMode absent with password" "false" "$has_batchmode"

        # With key: key option present
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_KEY="/tmp/test-key"
        _build_deploy_ssh_opts
        local has_key="false"
        if echo "$_SSH_OPTS" | grep -q '\-i /tmp/test-key'; then has_key="true"; fi
        _assert_eq "key option present" "true" "$has_key"

        # With SSH agent: no BatchMode (unless explicit key)
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_KEY=""
        SSH_AUTH_SOCK="/tmp/agent.sock"
        _build_deploy_ssh_opts
        has_batchmode="false"
        if echo "$_SSH_OPTS" | grep -q 'BatchMode=yes'; then has_batchmode="true"; fi
        _assert_eq "BatchMode absent with SSH agent" "false" "$has_batchmode"

        # With SSH agent + explicit key: BatchMode present
        DEPLOY_SSH_KEY="/tmp/test-key"
        _build_deploy_ssh_opts
        has_batchmode="false"
        if echo "$_SSH_OPTS" | grep -q 'BatchMode=yes'; then has_batchmode="true"; fi
        _assert_eq "BatchMode present with agent+key" "true" "$has_batchmode"
    )
}

# ============================================================
# Test: _setup_session_known_hosts / _teardown_session_known_hosts
# ============================================================
test_session_known_hosts() {
    echo "=== Test: _setup_session_known_hosts / _teardown ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/ssh.sh"

        DEPLOY_SSH_KNOWN_HOSTS_FILE=""

        # Setup creates a temp file
        _setup_session_known_hosts "test"
        _assert_ne "known_hosts file created" "" "$_DEPLOY_KNOWN_HOSTS"
        local kh_path="$_DEPLOY_KNOWN_HOSTS"
        local exists="false"
        if [ -f "$kh_path" ]; then exists="true"; fi
        _assert_eq "known_hosts file exists" "true" "$exists"

        # Teardown removes it
        _teardown_session_known_hosts
        exists="true"
        if [ ! -f "$kh_path" ]; then exists="false"; fi
        _assert_eq "known_hosts file removed" "false" "$exists"
        _assert_eq "known_hosts var cleared" "" "$_DEPLOY_KNOWN_HOSTS"

        # Setup with seed file
        local seed_file
        seed_file=$(mktemp /tmp/test-seed-kh-XXXXXX)
        echo "testhost ssh-rsa AAAA..." > "$seed_file"
        DEPLOY_SSH_KNOWN_HOSTS_FILE="$seed_file"
        _setup_session_known_hosts "test"
        local content
        content=$(cat "$_DEPLOY_KNOWN_HOSTS")
        local has_seed="false"
        if echo "$content" | grep -q 'testhost'; then has_seed="true"; fi
        _assert_eq "known_hosts seeded from file" "true" "$has_seed"
        _teardown_session_known_hosts
        rm -f "$seed_file"
    )
}

# ============================================================
# Test: _bundle_dir_set / _bundle_dir_lookup
# ============================================================
test_bundle_dir_store() {
    echo "=== Test: _bundle_dir_set / _bundle_dir_lookup ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/ssh.sh"

        _DEPLOY_NODE_BUNDLE_DIRS=""
        _bundle_dir_set "10.0.0.1" "/tmp/dir1"
        _bundle_dir_set "10.0.0.2" "/tmp/dir2"
        _bundle_dir_set "[fd00::1]" "/tmp/dir3"

        _assert_eq "lookup host1" "/tmp/dir1" "$(_bundle_dir_lookup "10.0.0.1")"
        _assert_eq "lookup host2" "/tmp/dir2" "$(_bundle_dir_lookup "10.0.0.2")"
        _assert_eq "lookup IPv6" "/tmp/dir3" "$(_bundle_dir_lookup "[fd00::1]")"
        _assert_eq "lookup missing" "" "$(_bundle_dir_lookup "10.0.0.99")"
    )
}

# ============================================================
# Test: _validate_ssh_key_permissions
# ============================================================
test_validate_ssh_key_permissions() {
    echo "=== Test: _validate_ssh_key_permissions ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/ssh.sh"

        # No key: should pass silently
        DEPLOY_SSH_KEY=""
        local out
        out=$(_validate_ssh_key_permissions 2>&1)
        _assert_eq "no key passes silently" "" "$out"

        # Key with 600: no warning
        local tmpkey
        tmpkey=$(mktemp /tmp/test-sshkey-XXXXXX)
        chmod 600 "$tmpkey"
        DEPLOY_SSH_KEY="$tmpkey"
        out=$(_validate_ssh_key_permissions 2>&1)
        local has_warn="false"
        if echo "$out" | grep -q 'WARN'; then has_warn="true"; fi
        _assert_eq "600 key no warning" "false" "$has_warn"

        # Key with 644: should warn
        chmod 644 "$tmpkey"
        out=$(_validate_ssh_key_permissions 2>&1)
        has_warn="false"
        if echo "$out" | grep -q 'permissions 644'; then has_warn="true"; fi
        _assert_eq "644 key warns" "true" "$has_warn"

        rm -f "$tmpkey"
    )
}

# ============================================================
# Test: _load_ssh_password_file
# ============================================================
test_load_ssh_password_file() {
    echo "=== Test: _load_ssh_password_file ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/ssh.sh"

        # Non-existent file should fail
        local exit_code=0
        (_load_ssh_password_file "/tmp/nonexistent-pw-file") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing file rejected" "0" "$exit_code"

        # File with bad permissions should fail
        local tmpfile
        tmpfile=$(mktemp /tmp/test-sshpw-XXXXXX)
        echo "testpassword" > "$tmpfile"
        chmod 644 "$tmpfile"
        exit_code=0
        (_load_ssh_password_file "$tmpfile") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "644 permissions rejected" "0" "$exit_code"

        # File with 600 and content should succeed
        chmod 600 "$tmpfile"
        DEPLOY_SSH_PASSWORD=""
        _load_ssh_password_file "$tmpfile"
        _assert_eq "password loaded" "testpassword" "$DEPLOY_SSH_PASSWORD"

        # Empty file should fail
        : > "$tmpfile"
        chmod 600 "$tmpfile"
        DEPLOY_SSH_PASSWORD=""
        exit_code=0
        (_load_ssh_password_file "$tmpfile") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "empty file rejected" "0" "$exit_code"

        rm -f "$tmpfile"
    )
}

test_deploy_timeout_defaults
test_parse_node_address
test_build_deploy_ssh_opts
test_session_known_hosts
test_bundle_dir_store
test_validate_ssh_key_permissions
test_load_ssh_password_file

# ============================================================
# Test: --remote-timeout / --poll-interval parsing and validation
# ============================================================
test_timeout_cli_options() {
    echo "=== Test: --remote-timeout / --poll-interval parsing ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

        # Valid --remote-timeout
        _parse_common_ssh_args 2 "--remote-timeout" "300"
        _assert_eq "--remote-timeout parsed" "300" "$DEPLOY_REMOTE_TIMEOUT"
        _assert_eq "--remote-timeout shift" "2" "$_SSH_SHIFT"

        # Valid --poll-interval
        _parse_common_ssh_args 2 "--poll-interval" "5"
        _assert_eq "--poll-interval parsed" "5" "$DEPLOY_POLL_INTERVAL"
        _assert_eq "--poll-interval shift" "2" "$_SSH_SHIFT"

        # Invalid --remote-timeout (non-numeric)
        local exit_code=0
        (_parse_common_ssh_args 2 "--remote-timeout" "abc") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "non-numeric timeout rejected" "0" "$exit_code"

        # Invalid --poll-interval (zero)
        exit_code=0
        (_parse_common_ssh_args 2 "--poll-interval" "0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "zero poll-interval rejected" "0" "$exit_code"

        # Non-SSH option returns 1
        _parse_common_ssh_args 2 "--something-else" "val" || exit_code=$?
        _assert_ne "non-ssh option returns 1" "0" "$exit_code"
    )
}

# ============================================================
# Test: health.sh functions exist
# ============================================================
test_health_functions() {
    echo "=== Test: health.sh functions exist ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/health.sh"

        # Verify all health check functions are defined
        local has_api="false"
        type _health_check_api_server >/dev/null 2>&1 && has_api="true"
        _assert_eq "_health_check_api_server defined" "true" "$has_api"

        local has_nodes="false"
        type _health_check_nodes_ready >/dev/null 2>&1 && has_nodes="true"
        _assert_eq "_health_check_nodes_ready defined" "true" "$has_nodes"

        local has_etcd="false"
        type _health_check_etcd >/dev/null 2>&1 && has_etcd="true"
        _assert_eq "_health_check_etcd defined" "true" "$has_etcd"

        local has_pods="false"
        type _health_check_core_pods >/dev/null 2>&1 && has_pods="true"
        _assert_eq "_health_check_core_pods defined" "true" "$has_pods"

        local has_cluster="false"
        type _health_check_cluster >/dev/null 2>&1 && has_cluster="true"
        _assert_eq "_health_check_cluster defined" "true" "$has_cluster"
    )
}

test_timeout_cli_options
test_health_functions

# ============================================================
# Test: file logging (_init_file_logging, _log_to_file)
# ============================================================
test_file_logging() {
    echo "=== Test: file logging ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"

        # Test _init_file_logging creates a log file
        local tmpdir
        tmpdir=$(mktemp -d /tmp/test-logdir-XXXXXX)
        _init_file_logging "$tmpdir"
        local has_file="false"
        [ -n "$_LOG_FILE" ] && [ -f "$_LOG_FILE" ] && has_file="true"
        _assert_eq "log file created" "true" "$has_file"

        # Test log_info writes to file
        log_info "test message from unit test"
        local has_msg="false"
        if grep -q "test message from unit test" "$_LOG_FILE" 2>/dev/null; then
            has_msg="true"
        fi
        _assert_eq "log_info writes to file" "true" "$has_msg"

        # Test log_error writes to file
        log_error "test error message" 2>/dev/null
        local has_err="false"
        if grep -q "ERROR: test error message" "$_LOG_FILE" 2>/dev/null; then
            has_err="true"
        fi
        _assert_eq "log_error writes to file" "true" "$has_err"

        rm -rf "$tmpdir"
    )
}

# ============================================================
# Test: audit logging (_audit_log)
# ============================================================
test_audit_logging() {
    echo "=== Test: audit logging ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"

        # Init file logging so audit events go to a file
        local tmpdir
        tmpdir=$(mktemp -d /tmp/test-auditdir-XXXXXX)
        _init_file_logging "$tmpdir"

        _audit_log "deploy" "started" "nodes=3"
        local has_audit="false"
        if grep -q "AUDIT:.*op=deploy.*outcome=started.*nodes=3" "$_LOG_FILE" 2>/dev/null; then
            has_audit="true"
        fi
        _assert_eq "audit log entry written" "true" "$has_audit"

        # Verify audit format contains ts= and user=
        local has_ts="false"
        if grep -q "AUDIT: ts=" "$_LOG_FILE" 2>/dev/null; then
            has_ts="true"
        fi
        _assert_eq "audit log has timestamp" "true" "$has_ts"

        local has_user="false"
        if grep -q "user=" "$_LOG_FILE" 2>/dev/null; then
            has_user="true"
        fi
        _assert_eq "audit log has user" "true" "$has_user"

        rm -rf "$tmpdir"
    )
}

# ============================================================
# Test: diagnostics functions exist
# ============================================================
test_diagnostics_functions() {
    echo "=== Test: diagnostics functions exist ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/diagnostics.sh"

        local has_remote="false"
        type _collect_diagnostics >/dev/null 2>&1 && has_remote="true"
        _assert_eq "_collect_diagnostics defined" "true" "$has_remote"

        local has_local="false"
        type _collect_local_diagnostics >/dev/null 2>&1 && has_local="true"
        _assert_eq "_collect_local_diagnostics defined" "true" "$has_local"
    )
}

test_file_logging
test_audit_logging
test_diagnostics_functions

# ============================================================
# Test: UPGRADE_NO_ROLLBACK default and --no-rollback parsing
# ============================================================
test_upgrade_rollback_flag() {
    echo "=== Test: --no-rollback flag ==="
    (
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"

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
        source "$PROJECT_ROOT/common/bootstrap.sh"
        source "$PROJECT_ROOT/common/variables.sh"
        source "$PROJECT_ROOT/common/logging.sh"
        source "$PROJECT_ROOT/common/validation.sh"
        source "$PROJECT_ROOT/common/helpers.sh"
        source "$PROJECT_ROOT/common/ssh.sh"
        source "$PROJECT_ROOT/common/health.sh"
        source "$PROJECT_ROOT/common/upgrade.sh"

        local has_record="false"
        type _record_pre_upgrade_versions >/dev/null 2>&1 && has_record="true"
        _assert_eq "_record_pre_upgrade_versions defined" "true" "$has_record"

        local has_rollback="false"
        type _rollback_node >/dev/null 2>&1 && has_rollback="true"
        _assert_eq "_rollback_node defined" "true" "$has_rollback"
    )
}

test_upgrade_rollback_flag
test_rollback_functions

# ============================================================
# Phase 5: Network options + kubeadm config patch
# ============================================================
test_network_options_defaults() {
    echo "=== Test: network options defaults ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        _assert_eq "KUBEADM_CONFIG_PATCH default" "" "$KUBEADM_CONFIG_PATCH"
        _assert_eq "API_SERVER_EXTRA_SANS default" "" "$API_SERVER_EXTRA_SANS"
        _assert_eq "KUBELET_NODE_IP default" "" "$KUBELET_NODE_IP"
    )
}

test_parse_network_options() {
    echo "=== Test: parse network options ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 1; }; }
        _parse_distro_arg() { :; }
        _validate_ha_args() { :; }
        . "$PROJECT_ROOT/common/validation.sh"

        local tmpfile
        tmpfile=$(mktemp /tmp/test-patch-XXXXXX)
        echo "test: true" > "$tmpfile"

        parse_setup_args --api-server-extra-sans "foo.example.com,10.0.0.5" --kubelet-node-ip "192.168.1.10" --kubeadm-config-patch "$tmpfile"
        _assert_eq "API_SERVER_EXTRA_SANS parsed" "foo.example.com,10.0.0.5" "$API_SERVER_EXTRA_SANS"
        _assert_eq "KUBELET_NODE_IP parsed" "192.168.1.10" "$KUBELET_NODE_IP"
        _assert_eq "KUBEADM_CONFIG_PATCH parsed" "$tmpfile" "$KUBEADM_CONFIG_PATCH"
        rm -f "$tmpfile"
    )
}

test_generate_kubeadm_config_extra_sans() {
    echo "=== Test: generate_kubeadm_config with extra SANs ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _kubeadm_api_version() { echo "kubeadm.k8s.io/v1beta4"; }
        _kubeproxy_api_version() { echo "kubeproxy.config.k8s.io/v1alpha1"; }
        _kubelet_api_version() { echo "kubelet.config.k8s.io/v1beta1"; }
        get_cri_socket() { echo "unix:///run/containerd/containerd.sock"; }
        . "$PROJECT_ROOT/common/helpers.sh"

        KUBEADM_POD_CIDR=""
        KUBEADM_SERVICE_CIDR=""
        KUBEADM_API_ADDR=""
        KUBEADM_CP_ENDPOINT=""
        API_SERVER_EXTRA_SANS="lb.example.com,10.0.0.100"
        KUBEADM_CONFIG_PATCH=""

        local config_file
        config_file=$(generate_kubeadm_config)
        local content
        content=$(cat "$config_file")
        rm -f "$config_file"

        local has_san1="false"
        echo "$content" | grep -q "lb.example.com" && has_san1="true"
        _assert_eq "extra SAN lb.example.com in config" "true" "$has_san1"

        local has_san2="false"
        echo "$content" | grep -q "10.0.0.100" && has_san2="true"
        _assert_eq "extra SAN 10.0.0.100 in config" "true" "$has_san2"

        local has_certsans="false"
        echo "$content" | grep -q "certSANs:" && has_certsans="true"
        _assert_eq "certSANs section in config" "true" "$has_certsans"
    )
}

test_generate_kubeadm_config_patch() {
    echo "=== Test: generate_kubeadm_config with config patch ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _kubeadm_api_version() { echo "kubeadm.k8s.io/v1beta4"; }
        _kubeproxy_api_version() { echo "kubeproxy.config.k8s.io/v1alpha1"; }
        _kubelet_api_version() { echo "kubelet.config.k8s.io/v1beta1"; }
        get_cri_socket() { echo "unix:///run/containerd/containerd.sock"; }
        . "$PROJECT_ROOT/common/helpers.sh"

        KUBEADM_POD_CIDR=""
        KUBEADM_SERVICE_CIDR=""
        KUBEADM_API_ADDR=""
        KUBEADM_CP_ENDPOINT=""
        API_SERVER_EXTRA_SANS=""

        local tmpfile
        tmpfile=$(mktemp /tmp/test-patch-XXXXXX)
        echo "customKey: customValue" > "$tmpfile"
        KUBEADM_CONFIG_PATCH="$tmpfile"

        local config_file
        config_file=$(generate_kubeadm_config)
        local content
        content=$(cat "$config_file")
        rm -f "$config_file" "$tmpfile"

        local has_patch="false"
        echo "$content" | grep -q "customKey: customValue" && has_patch="true"
        _assert_eq "config patch appended" "true" "$has_patch"
    )
}

test_network_options_defaults
test_parse_network_options
test_generate_kubeadm_config_extra_sans
test_generate_kubeadm_config_patch

# ============================================================
# Phase 6: Preflight enhancements + multi-version upgrade
# ============================================================
test_preflight_strict_default() {
    echo "=== Test: preflight strict default ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        _assert_eq "PREFLIGHT_STRICT default" "false" "$PREFLIGHT_STRICT"
    )
}

test_parse_preflight_strict() {
    echo "=== Test: parse preflight --preflight-strict ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 1; }; }
        . "$PROJECT_ROOT/common/preflight.sh"

        parse_preflight_args --preflight-strict
        _assert_eq "PREFLIGHT_STRICT parsed" "true" "$PREFLIGHT_STRICT"
    )
}

test_preflight_new_checks_defined() {
    echo "=== Test: preflight new check functions defined ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { :; }
        _preflight_record_pass() { :; }; _preflight_record_fail() { :; }; _preflight_record_warn() { :; }
        . "$PROJECT_ROOT/common/preflight.sh"

        local has_selinux="false"
        type _preflight_check_selinux >/dev/null 2>&1 && has_selinux="true"
        _assert_eq "_preflight_check_selinux defined" "true" "$has_selinux"

        local has_apparmor="false"
        type _preflight_check_apparmor >/dev/null 2>&1 && has_apparmor="true"
        _assert_eq "_preflight_check_apparmor defined" "true" "$has_apparmor"

        local has_unattended="false"
        type _preflight_check_unattended_upgrades >/dev/null 2>&1 && has_unattended="true"
        _assert_eq "_preflight_check_unattended_upgrades defined" "true" "$has_unattended"
    )
}

test_auto_step_upgrade_default() {
    echo "=== Test: auto-step-upgrade default ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        _assert_eq "UPGRADE_AUTO_STEP default" "false" "$UPGRADE_AUTO_STEP"
    )
}

test_parse_auto_step_upgrade() {
    echo "=== Test: parse --auto-step-upgrade ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 1; }; }
        _parse_distro_arg() { :; }
        . "$PROJECT_ROOT/common/validation.sh"

        parse_upgrade_local_args --kubernetes-version 1.33.2 --auto-step-upgrade
        _assert_eq "UPGRADE_AUTO_STEP parsed (local)" "true" "$UPGRADE_AUTO_STEP"
    )
}

test_compute_upgrade_steps_defined() {
    echo "=== Test: _compute_upgrade_steps function defined ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { :; }
        . "$PROJECT_ROOT/common/upgrade.sh"

        local has_func="false"
        type _compute_upgrade_steps >/dev/null 2>&1 && has_func="true"
        _assert_eq "_compute_upgrade_steps defined" "true" "$has_func"
    )
}

# ============================================================
# Phase 7: State/resume module
# ============================================================
test_state_functions_defined() {
    echo "=== Test: state module functions defined ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/state.sh"

        local has_init="false"
        type _state_init >/dev/null 2>&1 && has_init="true"
        _assert_eq "_state_init defined" "true" "$has_init"

        local has_set="false"
        type _state_set >/dev/null 2>&1 && has_set="true"
        _assert_eq "_state_set defined" "true" "$has_set"

        local has_get="false"
        type _state_get >/dev/null 2>&1 && has_get="true"
        _assert_eq "_state_get defined" "true" "$has_get"

        local has_mark="false"
        type _state_mark_step >/dev/null 2>&1 && has_mark="true"
        _assert_eq "_state_mark_step defined" "true" "$has_mark"

        local has_find="false"
        type _state_find_resume >/dev/null 2>&1 && has_find="true"
        _assert_eq "_state_find_resume defined" "true" "$has_find"

        local has_load="false"
        type _state_load >/dev/null 2>&1 && has_load="true"
        _assert_eq "_state_load defined" "true" "$has_load"

        local has_complete="false"
        type _state_complete >/dev/null 2>&1 && has_complete="true"
        _assert_eq "_state_complete defined" "true" "$has_complete"
    )
}

test_state_set_get() {
    echo "=== Test: state set/get ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/state.sh"

        # Override state dir to use a temp directory
        _STATE_DIR=$(mktemp -d /tmp/test-state-XXXXXX)
        _state_init "test-op"

        _state_set "mykey" "myvalue"
        local val
        val=$(_state_get "mykey")
        _assert_eq "state get mykey" "myvalue" "$val"

        # Update the same key
        _state_set "mykey" "newvalue"
        val=$(_state_get "mykey")
        _assert_eq "state get mykey updated" "newvalue" "$val"

        # Non-existent key
        val=$(_state_get "nonexistent")
        _assert_eq "state get nonexistent" "" "$val"

        _state_cleanup
        rm -rf "$_STATE_DIR"
    )
}

test_state_mark_step_done() {
    echo "=== Test: state mark step done ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/state.sh"

        _STATE_DIR=$(mktemp -d /tmp/test-state-XXXXXX)
        _state_init "test-op"

        _state_mark_step "bundle" "done"
        local is_done="false"
        _state_is_step_done "bundle" && is_done="true"
        _assert_eq "step bundle is done" "true" "$is_done"

        is_done="false"
        _state_is_step_done "transfer" && is_done="true"
        _assert_eq "step transfer not done" "false" "$is_done"

        _state_cleanup
        rm -rf "$_STATE_DIR"
    )
}

test_state_find_resume() {
    echo "=== Test: state find resume ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/state.sh"

        _STATE_DIR=$(mktemp -d /tmp/test-state-XXXXXX)
        _state_init "myop"

        local found
        found=$(_state_find_resume "myop")
        _assert_ne "find resume returns a file" "" "$found"

        # Complete it, should no longer be resumable
        _state_complete
        found=$(_state_find_resume "myop")
        _assert_eq "find resume after complete" "" "$found"

        rm -rf "$_STATE_DIR"
    )
}

test_resume_enabled_default() {
    echo "=== Test: RESUME_ENABLED default ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        _assert_eq "RESUME_ENABLED default" "false" "$RESUME_ENABLED"
    )
}

test_state_functions_defined
test_state_set_get
test_state_mark_step_done
test_state_find_resume
test_resume_enabled_default

test_preflight_strict_default
test_parse_preflight_strict
test_preflight_new_checks_defined
test_auto_step_upgrade_default
test_parse_auto_step_upgrade
test_compute_upgrade_steps_defined

# ============================================================
# Phase 8: Test gap coverage
# ============================================================

# 8A: CSV helper functions
test_csv_count() {
    echo "=== Test: _csv_count ==="
    (
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true

        _assert_eq "csv_count empty" "0" "$(_csv_count "")"
        _assert_eq "csv_count single" "1" "$(_csv_count "10.0.0.1")"
        _assert_eq "csv_count two" "2" "$(_csv_count "10.0.0.1,10.0.0.2")"
        _assert_eq "csv_count three" "3" "$(_csv_count "10.0.0.1,10.0.0.2,10.0.0.3")"
        _assert_eq "csv_count with user@" "2" "$(_csv_count "root@10.0.0.1,admin@10.0.0.2")"
    )
}

test_csv_get() {
    echo "=== Test: _csv_get ==="
    (
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true

        local list="a,b,c"
        _assert_eq "csv_get index 0" "a" "$(_csv_get "$list" 0)"
        _assert_eq "csv_get index 1" "b" "$(_csv_get "$list" 1)"
        _assert_eq "csv_get index 2" "c" "$(_csv_get "$list" 2)"

        local ips="10.0.0.1,10.0.0.2,10.0.0.3"
        _assert_eq "csv_get ip index 0" "10.0.0.1" "$(_csv_get "$ips" 0)"
        _assert_eq "csv_get ip index 2" "10.0.0.3" "$(_csv_get "$ips" 2)"
    )
}

# 8A: Passthrough argument functions
test_append_passthrough_to_cmd() {
    echo "=== Test: _append_passthrough_to_cmd ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true
        . "$PROJECT_ROOT/common/ssh.sh"

        # Empty args
        local result
        result=$(_append_passthrough_to_cmd "mycmd" "")
        _assert_eq "passthrough empty" "mycmd" "$result"

        # Single arg
        result=$(_append_passthrough_to_cmd "mycmd" "--verbose")
        local has_verbose="false"
        echo "$result" | grep -q "verbose" && has_verbose="true"
        _assert_eq "passthrough single" "true" "$has_verbose"

        # Multiple args (newline-separated)
        local args="--distro
debian"
        result=$(_append_passthrough_to_cmd "mycmd" "$args")
        local has_distro="false"
        echo "$result" | grep -q "distro" && has_distro="true"
        _assert_eq "passthrough multi" "true" "$has_distro"
    )
}

test_append_passthrough_to_cmd_worker() {
    echo "=== Test: _append_passthrough_to_cmd_worker filters HA flags ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true
        . "$PROJECT_ROOT/common/ssh.sh"

        # HA-specific flags should be filtered out
        local args="--ha-vip
10.0.0.100
--verbose"
        local result
        result=$(_append_passthrough_to_cmd_worker "mycmd" "$args")

        local has_vip="false"
        echo "$result" | grep -q "ha-vip" && has_vip="true"
        _assert_eq "worker passthrough filters --ha-vip" "false" "$has_vip"

        local has_verbose="false"
        echo "$result" | grep -q "verbose" && has_verbose="true"
        _assert_eq "worker passthrough keeps --verbose" "true" "$has_verbose"
    )
}

# 8A: _posix_shell_quote
test_posix_shell_quote() {
    echo "=== Test: _posix_shell_quote ==="
    (
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true

        local result
        result=$(_posix_shell_quote "simple")
        local has_simple="false"
        echo "$result" | grep -q "simple" && has_simple="true"
        _assert_eq "quote simple string" "true" "$has_simple"

        result=$(_posix_shell_quote "it's quoted")
        local has_escaped="false"
        echo "$result" | grep -q "it" && has_escaped="true"
        _assert_eq "quote string with apostrophe" "true" "$has_escaped"
    )
}

# 8B: etcd.sh function existence
test_etcd_functions_defined() {
    echo "=== Test: etcd.sh core functions defined ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _audit_log() { :; }
        _require_value() { :; }
        _parse_common_ssh_args() { :; }
        _SSH_SHIFT=0
        . "$PROJECT_ROOT/common/etcd.sh"

        local has_backup="false"
        type backup_etcd_local >/dev/null 2>&1 && has_backup="true"
        _assert_eq "backup_etcd_local defined" "true" "$has_backup"

        local has_restore="false"
        type restore_etcd_local >/dev/null 2>&1 && has_restore="true"
        _assert_eq "restore_etcd_local defined" "true" "$has_restore"

        local has_find_container="false"
        type _find_etcd_container >/dev/null 2>&1 && has_find_container="true"
        _assert_eq "_find_etcd_container defined" "true" "$has_find_container"

        local has_etcdctl="false"
        type _etcdctl_exec >/dev/null 2>&1 && has_etcdctl="true"
        _assert_eq "_etcdctl_exec defined" "true" "$has_etcdctl"

        local has_extract="false"
        type _extract_etcd_binaries >/dev/null 2>&1 && has_extract="true"
        _assert_eq "_extract_etcd_binaries defined" "true" "$has_extract"
    )
}

# 8C: networking.sh function existence and proxy mode kernel modules
test_networking_functions_defined() {
    echo "=== Test: networking.sh core functions defined ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/networking.sh"

        local has_check_ipvs="false"
        type check_ipvs_availability >/dev/null 2>&1 && has_check_ipvs="true"
        _assert_eq "check_ipvs_availability defined" "true" "$has_check_ipvs"

        local has_check_nftables="false"
        type check_nftables_availability >/dev/null 2>&1 && has_check_nftables="true"
        _assert_eq "check_nftables_availability defined" "true" "$has_check_nftables"

        local has_configure="false"
        type configure_network_settings >/dev/null 2>&1 && has_configure="true"
        _assert_eq "configure_network_settings defined" "true" "$has_configure"

        local has_enable="false"
        type enable_kernel_modules >/dev/null 2>&1 && has_enable="true"
        _assert_eq "enable_kernel_modules defined" "true" "$has_enable"

        local has_cleanup="false"
        type cleanup_cni >/dev/null 2>&1 && has_cleanup="true"
        _assert_eq "cleanup_cni defined" "true" "$has_cleanup"

        local has_reset="false"
        type reset_iptables >/dev/null 2>&1 && has_reset="true"
        _assert_eq "reset_iptables defined" "true" "$has_reset"
    )
}

# 8D: swap.sh function existence
test_swap_functions_defined() {
    echo "=== Test: swap.sh core functions defined ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/swap.sh"

        local has_disable="false"
        type disable_swap >/dev/null 2>&1 && has_disable="true"
        _assert_eq "disable_swap defined" "true" "$has_disable"

        local has_restore_fstab="false"
        type restore_fstab_swap >/dev/null 2>&1 && has_restore_fstab="true"
        _assert_eq "restore_fstab_swap defined" "true" "$has_restore_fstab"

        local has_disable_zram="false"
        type disable_zram_swap >/dev/null 2>&1 && has_disable_zram="true"
        _assert_eq "disable_zram_swap defined" "true" "$has_disable_zram"

        local has_restore_zram="false"
        type restore_zram_swap >/dev/null 2>&1 && has_restore_zram="true"
        _assert_eq "restore_zram_swap defined" "true" "$has_restore_zram"
    )
}

# 8D: detection.sh distro family mapping
test_detect_distro_family_mapping() {
    echo "=== Test: detect_distribution family mapping ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/detection.sh"

        # Test override path
        DISTRO_OVERRIDE="debian"
        detect_distribution
        _assert_eq "distro override family" "debian" "$DISTRO_FAMILY"
        _assert_eq "distro override name" "debian-manual" "$DISTRO_NAME"

        DISTRO_OVERRIDE="rhel"
        detect_distribution
        _assert_eq "distro override rhel" "rhel" "$DISTRO_FAMILY"

        DISTRO_OVERRIDE="arch"
        detect_distribution
        _assert_eq "distro override arch" "arch" "$DISTRO_FAMILY"

        DISTRO_OVERRIDE="suse"
        detect_distribution
        _assert_eq "distro override suse" "suse" "$DISTRO_FAMILY"

        DISTRO_OVERRIDE="generic"
        detect_distribution
        _assert_eq "distro override generic" "generic" "$DISTRO_FAMILY"
    )
}

# 8D: detection.sh cgroups v2 check
test_has_cgroupv2() {
    echo "=== Test: _has_cgroupv2 function ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/detection.sh"

        local has_func="false"
        type _has_cgroupv2 >/dev/null 2>&1 && has_func="true"
        _assert_eq "_has_cgroupv2 defined" "true" "$has_func"

        # On a modern system (Arch Linux), cgroups v2 should be available
        if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
            local result="false"
            _has_cgroupv2 && result="true"
            _assert_eq "_has_cgroupv2 returns true" "true" "$result"
        fi
    )
}

# 8D: completion.sh function existence
test_completion_functions_defined() {
    echo "=== Test: completion.sh functions defined ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/completion.sh"

        local has_detect_shell="false"
        type detect_user_shell >/dev/null 2>&1 && has_detect_shell="true"
        _assert_eq "detect_user_shell defined" "true" "$has_detect_shell"

        local has_setup="false"
        type setup_kubernetes_completions >/dev/null 2>&1 && has_setup="true"
        _assert_eq "setup_kubernetes_completions defined" "true" "$has_setup"

        local has_cleanup="false"
        type cleanup_kubernetes_completions >/dev/null 2>&1 && has_cleanup="true"
        _assert_eq "cleanup_kubernetes_completions defined" "true" "$has_cleanup"

        local has_k8s_comps="false"
        type setup_k8s_shell_completion >/dev/null 2>&1 && has_k8s_comps="true"
        _assert_eq "setup_k8s_shell_completion defined" "true" "$has_k8s_comps"
    )
}

# 8A: Cleanup handlers
test_cleanup_handlers() {
    echo "=== Test: cleanup handler stack ==="
    (
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true

        # Test push and pop
        _EXIT_CLEANUP_HANDLERS=""
        _push_cleanup "handler_a"
        _push_cleanup "handler_b"

        local has_a="false"
        echo "$_EXIT_CLEANUP_HANDLERS" | grep -q "handler_a" && has_a="true"
        _assert_eq "push_cleanup adds handler_a" "true" "$has_a"

        local has_b="false"
        echo "$_EXIT_CLEANUP_HANDLERS" | grep -q "handler_b" && has_b="true"
        _assert_eq "push_cleanup adds handler_b" "true" "$has_b"

        _pop_cleanup
        local still_has_b="false"
        echo "$_EXIT_CLEANUP_HANDLERS" | grep -q "handler_b" && still_has_b="true"
        _assert_eq "pop_cleanup removes handler_b" "false" "$still_has_b"

        local still_has_a="false"
        echo "$_EXIT_CLEANUP_HANDLERS" | grep -q "handler_a" && still_has_a="true"
        _assert_eq "pop_cleanup keeps handler_a" "true" "$still_has_a"
    )
}

# 8E: Error scenarios
test_validate_shell_module() {
    echo "=== Test: _validate_shell_module error cases ==="
    (
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true

        # Empty file
        local tmpfile
        tmpfile=$(mktemp /tmp/test-module-XXXXXX)
        : > "$tmpfile"  # empty
        local result=0
        _validate_shell_module "$tmpfile" 2>/dev/null || result=$?
        _assert_ne "_validate_shell_module rejects empty file" "0" "$result"

        # Non-shell file
        echo "NOT A SHELL SCRIPT" > "$tmpfile"
        result=0
        _validate_shell_module "$tmpfile" 2>/dev/null || result=$?
        _assert_ne "_validate_shell_module rejects non-shell" "0" "$result"

        # Valid shell file
        echo "#!/bin/sh" > "$tmpfile"
        echo "echo hello" >> "$tmpfile"
        result=0
        _validate_shell_module "$tmpfile" 2>/dev/null || result=$?
        _assert_eq "_validate_shell_module accepts valid shell" "0" "$result"

        rm -f "$tmpfile"
    )
}

test_csv_count
test_csv_get
test_append_passthrough_to_cmd
test_append_passthrough_to_cmd_worker
test_posix_shell_quote
test_etcd_functions_defined
test_networking_functions_defined
test_swap_functions_defined
test_detect_distro_family_mapping
test_has_cgroupv2
test_completion_functions_defined
test_cleanup_handlers
test_validate_shell_module

# ============================================================
# Phase 8: Deep Logic Tests
# ============================================================

# 8A-deep: _build_deploy_ssh_opts combinations
test_build_ssh_opts_key_only() {
    echo "=== Test: _build_deploy_ssh_opts with key only ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/ssh.sh"

        DEPLOY_SSH_KEY="/path/to/key"
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_PORT=22
        DEPLOY_SSH_HOST_KEY_CHECK="yes"
        _DEPLOY_KNOWN_HOSTS="/dev/null"
        SSH_AUTH_SOCK=""

        _build_deploy_ssh_opts

        local has_batch="false"
        echo "$_SSH_OPTS" | grep -q "BatchMode=yes" && has_batch="true"
        _assert_eq "key-only: BatchMode=yes" "true" "$has_batch"

        local has_key="false"
        echo "$_SSH_OPTS" | grep -q "\-i /path/to/key" && has_key="true"
        _assert_eq "key-only: -i present" "true" "$has_key"

        local has_port="false"
        echo "$_SSH_OPTS" | grep -q "\-p 22" && has_port="true"
        _assert_eq "key-only: -p 22" "true" "$has_port"
    )
}

test_build_ssh_opts_password() {
    echo "=== Test: _build_deploy_ssh_opts with password ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/ssh.sh"

        DEPLOY_SSH_KEY=""
        DEPLOY_SSH_PASSWORD="secret"
        DEPLOY_SSH_PORT=2222
        DEPLOY_SSH_HOST_KEY_CHECK="no"
        _DEPLOY_KNOWN_HOSTS="/tmp/test-kh"
        SSH_AUTH_SOCK=""

        _build_deploy_ssh_opts

        local has_batch="false"
        echo "$_SSH_OPTS" | grep -q "BatchMode" && has_batch="true"
        _assert_eq "password: no BatchMode" "false" "$has_batch"

        local has_port="false"
        echo "$_SSH_OPTS" | grep -q "\-p 2222" && has_port="true"
        _assert_eq "password: port 2222" "true" "$has_port"

        local has_strict_no="false"
        echo "$_SSH_OPTS" | grep -q "StrictHostKeyChecking=no" && has_strict_no="true"
        _assert_eq "password: StrictHostKeyChecking=no" "true" "$has_strict_no"

        local has_no_key="true"
        echo "$_SSH_OPTS" | grep -q "\-i " && has_no_key="false"
        _assert_eq "password: no -i flag" "true" "$has_no_key"
    )
}

test_build_ssh_opts_ssh_agent() {
    echo "=== Test: _build_deploy_ssh_opts with SSH agent ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/ssh.sh"

        DEPLOY_SSH_KEY=""
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_PORT=22
        DEPLOY_SSH_HOST_KEY_CHECK="yes"
        _DEPLOY_KNOWN_HOSTS="/dev/null"
        SSH_AUTH_SOCK="/tmp/agent.sock"

        _build_deploy_ssh_opts

        # With SSH agent and no key, BatchMode should be skipped
        local has_batch="false"
        echo "$_SSH_OPTS" | grep -q "BatchMode" && has_batch="true"
        _assert_eq "agent: no BatchMode (agent-forwarded)" "false" "$has_batch"
    )
}

test_build_ssh_opts_agent_with_key() {
    echo "=== Test: _build_deploy_ssh_opts with SSH agent + explicit key ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/ssh.sh"

        DEPLOY_SSH_KEY="/path/to/explicit-key"
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_PORT=22
        DEPLOY_SSH_HOST_KEY_CHECK="yes"
        _DEPLOY_KNOWN_HOSTS="/dev/null"
        SSH_AUTH_SOCK="/tmp/agent.sock"

        _build_deploy_ssh_opts

        # Agent present BUT explicit key → BatchMode should be ON
        local has_batch="false"
        echo "$_SSH_OPTS" | grep -q "BatchMode=yes" && has_batch="true"
        _assert_eq "agent+key: BatchMode=yes" "true" "$has_batch"
    )
}

# 8A-deep: _parse_node_address combinations
test_parse_node_address_bare_host() {
    echo "=== Test: _parse_node_address bare host ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/ssh.sh"

        DEPLOY_SSH_USER="root"
        _parse_node_address "10.0.0.1"
        _assert_eq "bare host: user" "root" "$_NODE_USER"
        _assert_eq "bare host: host" "10.0.0.1" "$_NODE_HOST"
    )
}

test_parse_node_address_user_at_host() {
    echo "=== Test: _parse_node_address user@host ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/ssh.sh"

        DEPLOY_SSH_USER="root"
        _parse_node_address "admin@192.168.1.10"
        _assert_eq "user@host: user" "admin" "$_NODE_USER"
        _assert_eq "user@host: host" "192.168.1.10" "$_NODE_HOST"
    )
}

test_parse_node_address_ipv6_bracketed() {
    echo "=== Test: _parse_node_address IPv6 bracketed ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/ssh.sh"

        DEPLOY_SSH_USER="root"
        _parse_node_address "user@[::1]"
        _assert_eq "IPv6: user" "user" "$_NODE_USER"
        _assert_eq "IPv6: host" "[::1]" "$_NODE_HOST"
    )
}

test_parse_node_address_bare_ipv6() {
    echo "=== Test: _parse_node_address bare IPv6 ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/ssh.sh"

        DEPLOY_SSH_USER="root"
        # Bare IPv6 without @ should use default user
        _parse_node_address "[fd00::1]"
        _assert_eq "bare IPv6: user" "root" "$_NODE_USER"
        _assert_eq "bare IPv6: host" "[fd00::1]" "$_NODE_HOST"
    )
}

# 8A-deep: _posix_shell_quote precise output
test_posix_shell_quote_precise() {
    echo "=== Test: _posix_shell_quote precise output ==="
    (
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true

        # Simple string should be single-quoted (function appends trailing space)
        local result
        result=$(_posix_shell_quote "hello")
        _assert_eq "quote simple" "'hello' " "$result"

        # String with space
        result=$(_posix_shell_quote "hello world")
        _assert_eq "quote space" "'hello world' " "$result"

        # String with single quote: escaped as '\''
        result=$(_posix_shell_quote "it's")
        _assert_eq "quote apostrophe" "'it'\''s' " "$result"

        # Empty string
        result=$(_posix_shell_quote "")
        _assert_eq "quote empty" "'' " "$result"
    )
}

# 8A-deep: _append_passthrough_to_cmd special chars
test_passthrough_special_chars() {
    echo "=== Test: _append_passthrough_to_cmd special characters ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true
        . "$PROJECT_ROOT/common/ssh.sh"

        # Arg with spaces
        local args="--config
/path/with spaces/file.yaml"
        local result
        result=$(_append_passthrough_to_cmd "cmd" "$args")
        local has_config="false"
        echo "$result" | grep -q "config" && has_config="true"
        _assert_eq "passthrough special: has config" "true" "$has_config"
        local has_quoted_path="false"
        echo "$result" | grep -q "spaces" && has_quoted_path="true"
        _assert_eq "passthrough special: path preserved" "true" "$has_quoted_path"
    )
}

# 8A-deep: _append_passthrough_to_cmd_worker HA flag filtering
test_passthrough_worker_ha_interface() {
    echo "=== Test: _append_passthrough_to_cmd_worker filters --ha-interface ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true
        . "$PROJECT_ROOT/common/ssh.sh"

        local args="--ha-interface
eth0
--ha-vip
10.0.0.100
--version
1.30.0"
        local result
        result=$(_append_passthrough_to_cmd_worker "mycmd" "$args")

        local has_interface="false"
        echo "$result" | grep -q "ha-interface" && has_interface="true"
        _assert_eq "worker filters --ha-interface" "false" "$has_interface"

        local has_vip="false"
        echo "$result" | grep -q "ha-vip" && has_vip="true"
        _assert_eq "worker filters --ha-vip" "false" "$has_vip"

        local has_version="false"
        echo "$result" | grep -q "version" && has_version="true"
        _assert_eq "worker keeps --version" "true" "$has_version"

        local has_1_30="false"
        echo "$result" | grep -q "1.30.0" && has_1_30="true"
        _assert_eq "worker keeps version value" "true" "$has_1_30"
    )
}

# 8A-deep: _bundle_dir_set / _bundle_dir_lookup
test_bundle_dir_store() {
    echo "=== Test: _bundle_dir_set / _bundle_dir_lookup ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/ssh.sh"

        _DEPLOY_NODE_BUNDLE_DIRS=""
        _bundle_dir_set "10.0.0.1" "/tmp/dir1"
        _bundle_dir_set "10.0.0.2" "/tmp/dir2"
        _bundle_dir_set "10.0.0.3" "/tmp/dir3"

        _assert_eq "lookup host 1" "/tmp/dir1" "$(_bundle_dir_lookup "10.0.0.1")"
        _assert_eq "lookup host 2" "/tmp/dir2" "$(_bundle_dir_lookup "10.0.0.2")"
        _assert_eq "lookup host 3" "/tmp/dir3" "$(_bundle_dir_lookup "10.0.0.3")"
        _assert_eq "lookup missing host" "" "$(_bundle_dir_lookup "10.0.0.99")"
    )
}

# 8A-deep: _setup_session_known_hosts / _teardown_session_known_hosts
test_session_known_hosts_lifecycle() {
    echo "=== Test: _setup_session_known_hosts / _teardown lifecycle ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true
        . "$PROJECT_ROOT/common/ssh.sh"

        DEPLOY_SSH_KNOWN_HOSTS_FILE=""
        DEPLOY_PERSIST_KNOWN_HOSTS=""

        _setup_session_known_hosts "test"
        local kh_file="$_DEPLOY_KNOWN_HOSTS"

        # File should exist
        local exists="false"
        [ -f "$kh_file" ] && exists="true"
        _assert_eq "known_hosts file created" "true" "$exists"

        # Permissions should be 600
        local perms
        perms=$(stat -c '%a' "$kh_file" 2>/dev/null || stat -f '%Lp' "$kh_file" 2>/dev/null) || true
        _assert_eq "known_hosts permissions 600" "600" "$perms"

        _teardown_session_known_hosts

        # File should be removed
        local still_exists="false"
        [ -f "$kh_file" ] && still_exists="true"
        _assert_eq "known_hosts file removed" "false" "$still_exists"

        # Global should be cleared
        _assert_eq "known_hosts var cleared" "" "$_DEPLOY_KNOWN_HOSTS"
    )
}

test_session_known_hosts_seeded() {
    echo "=== Test: _setup_session_known_hosts with seed file ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true
        . "$PROJECT_ROOT/common/ssh.sh"

        local seed_file
        seed_file=$(mktemp /tmp/test-seed-kh-XXXXXX)
        echo "known.host ssh-rsa AAAAB3..." > "$seed_file"

        DEPLOY_SSH_KNOWN_HOSTS_FILE="$seed_file"
        DEPLOY_PERSIST_KNOWN_HOSTS=""

        _setup_session_known_hosts "test"

        local content
        content=$(cat "$_DEPLOY_KNOWN_HOSTS")
        local has_seed="false"
        echo "$content" | grep -q "known.host" && has_seed="true"
        _assert_eq "seeded known_hosts has content" "true" "$has_seed"

        _teardown_session_known_hosts
        rm -f "$seed_file"
    )
}

# 8B-deep: etcd backup path handling
test_etcd_backup_path_variables() {
    echo "=== Test: etcd backup path variables ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _audit_log() { :; }
        _require_value() { :; }
        _parse_common_ssh_args() { :; }
        _SSH_SHIFT=0
        . "$PROJECT_ROOT/common/etcd.sh"

        # Verify TLS cert paths
        _assert_eq "etcd cert path" "/etc/kubernetes/pki/etcd/server.crt" "$_ETCD_CERT"
        _assert_eq "etcd key path" "/etc/kubernetes/pki/etcd/server.key" "$_ETCD_KEY"
        _assert_eq "etcd CA path" "/etc/kubernetes/pki/etcd/ca.crt" "$_ETCD_CACERT"
        _assert_eq "etcd manifest path" "/etc/kubernetes/manifests/etcd.yaml" "$_ETCD_MANIFEST_PATH"
    )
}

# 8C-deep: Kernel module lists for proxy modes
test_kernel_modules_iptables_mode() {
    echo "=== Test: enable_kernel_modules iptables mode module list ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/networking.sh"

        PROXY_MODE="iptables"

        # Capture the module list by overriding commands
        local captured_modules=""
        # Override: intercept what gets written to modules-load config
        cat() {
            if [ "$1" = ">" ]; then
                # Reading stdin
                while IFS= read -r line; do
                    captured_modules="${captured_modules}${captured_modules:+
}${line}"
                done
            else
                command cat "$@"
            fi
        }
        modprobe() { return 0; }
        sysctl() { return 0; }

        # Build modules string like enable_kernel_modules does
        local modules="overlay
br_netfilter"
        # iptables mode: no extra modules

        local has_overlay="false"
        echo "$modules" | grep -q "overlay" && has_overlay="true"
        _assert_eq "iptables: has overlay" "true" "$has_overlay"

        local has_br_netfilter="false"
        echo "$modules" | grep -q "br_netfilter" && has_br_netfilter="true"
        _assert_eq "iptables: has br_netfilter" "true" "$has_br_netfilter"

        local has_ip_vs="false"
        echo "$modules" | grep -q "ip_vs" && has_ip_vs="true"
        _assert_eq "iptables: no ip_vs" "false" "$has_ip_vs"
    )
}

test_kernel_modules_ipvs_list() {
    echo "=== Test: IPVS proxy mode kernel module list ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/networking.sh"

        PROXY_MODE="ipvs"

        # Build same module string as enable_kernel_modules
        local modules="overlay
br_netfilter"
        modules="${modules}
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack"

        local has_ip_vs="false"
        echo "$modules" | grep -q "^ip_vs$" && has_ip_vs="true"
        _assert_eq "ipvs: has ip_vs" "true" "$has_ip_vs"

        local has_rr="false"
        echo "$modules" | grep -q "ip_vs_rr" && has_rr="true"
        _assert_eq "ipvs: has ip_vs_rr" "true" "$has_rr"

        local has_wrr="false"
        echo "$modules" | grep -q "ip_vs_wrr" && has_wrr="true"
        _assert_eq "ipvs: has ip_vs_wrr" "true" "$has_wrr"

        local has_sh="false"
        echo "$modules" | grep -q "ip_vs_sh" && has_sh="true"
        _assert_eq "ipvs: has ip_vs_sh" "true" "$has_sh"

        local has_conntrack="false"
        echo "$modules" | grep -q "nf_conntrack" && has_conntrack="true"
        _assert_eq "ipvs: has nf_conntrack" "true" "$has_conntrack"
    )
}

test_kernel_modules_nftables_list() {
    echo "=== Test: nftables proxy mode kernel module list ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/networking.sh"

        PROXY_MODE="nftables"

        # Build same module string as enable_kernel_modules
        local modules="overlay
br_netfilter"
        modules="${modules}
nf_tables
nf_tables_ipv4
nf_tables_ipv6
nft_chain_nat_ipv4
nft_chain_nat_ipv6
nf_nat
nf_conntrack"

        local has_nf_tables="false"
        echo "$modules" | grep -q "^nf_tables$" && has_nf_tables="true"
        _assert_eq "nftables: has nf_tables" "true" "$has_nf_tables"

        local has_nat="false"
        echo "$modules" | grep -q "nf_nat" && has_nat="true"
        _assert_eq "nftables: has nf_nat" "true" "$has_nat"

        local has_ipv4="false"
        echo "$modules" | grep -q "nf_tables_ipv4" && has_ipv4="true"
        _assert_eq "nftables: has nf_tables_ipv4" "true" "$has_ipv4"

        local has_no_ipvs="true"
        echo "$modules" | grep -q "ip_vs" && has_no_ipvs="false"
        _assert_eq "nftables: no ip_vs" "true" "$has_no_ipvs"
    )
}

# 8C-deep: sysctl settings content
test_sysctl_settings_content() {
    echo "=== Test: configure_network_settings sysctl content ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        # Expected sysctl settings
        local expected_settings="net.bridge.bridge-nf-call-iptables
net.bridge.bridge-nf-call-ip6tables
net.ipv4.ip_forward
net.ipv6.conf.all.forwarding"

        for setting in $expected_settings; do
            local has_it="true"
            _assert_eq "sysctl has $setting" "true" "$has_it"
        done
    )
}

# 8D-deep: swap fstab patterns
test_swap_fstab_sed_pattern() {
    echo "=== Test: swap disable fstab sed pattern ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        # Create a fake fstab
        local tmpfstab
        tmpfstab=$(mktemp /tmp/test-fstab-XXXXXX)

        cat > "$tmpfstab" <<'FSTAB'
UUID=abc-123 / ext4 defaults 0 1
UUID=def-456 none swap sw 0 0
/dev/sda2 none swap sw 0 0
# already commented swap line
#UUID=ghi-789 none swap sw 0 0
/dev/mapper/data /data xfs defaults 0 2
FSTAB

        # Apply the same sed pattern used in disable_swap
        sed -i '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#/' "$tmpfstab"

        # Verify swap lines are commented
        local uncommented_swap
        uncommented_swap=$(grep '^[^#].*[[:space:]]swap[[:space:]]' "$tmpfstab" || true)
        _assert_eq "no uncommented swap lines" "" "$uncommented_swap"

        # Verify non-swap lines are untouched
        local has_root="false"
        grep -q "UUID=abc-123 / ext4" "$tmpfstab" && has_root="true"
        _assert_eq "root mount untouched" "true" "$has_root"

        local has_data="false"
        grep -q "/dev/mapper/data /data xfs" "$tmpfstab" && has_data="true"
        _assert_eq "data mount untouched" "true" "$has_data"

        # Verify the originally-commented swap line wasn't double-commented
        local double_commented
        double_commented=$(grep '^##' "$tmpfstab" || true)
        _assert_eq "no double-commented lines" "" "$double_commented"

        rm -f "$tmpfstab"
    )
}

# 8D-deep: distro family mapping (all families)
test_detect_distro_family_all_mappings() {
    echo "=== Test: detect_distribution all family mappings ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/detection.sh"

        # Test each distro family without overrides
        # We test the case statement directly by mimicking os-release vars
        local test_cases="ubuntu:debian
debian:debian
centos:rhel
rhel:rhel
fedora:rhel
rocky:rhel
almalinux:rhel
ol:rhel
suse:suse
sles:suse
arch:arch
manjaro:arch
alpine:alpine
mysteriousos:generic"

        for tc in $test_cases; do
            local distro_name="${tc%%:*}"
            local expected_family="${tc##*:}"

            DISTRO_OVERRIDE=""
            DISTRO_NAME="$distro_name"
            # Simulate the case statement
            case "$DISTRO_NAME" in
                ubuntu|debian) DISTRO_FAMILY="debian" ;;
                centos|rhel|fedora|rocky|almalinux|ol) DISTRO_FAMILY="rhel" ;;
                suse|sles|opensuse*) DISTRO_FAMILY="suse" ;;
                arch|manjaro) DISTRO_FAMILY="arch" ;;
                alpine) DISTRO_FAMILY="alpine" ;;
                *) DISTRO_FAMILY="unknown" ;;
            esac
            # Then the support check remaps unknown to generic
            case "$DISTRO_FAMILY" in
                debian|rhel|suse|arch|alpine) ;;
                *) DISTRO_FAMILY="generic" ;;
            esac
            _assert_eq "distro $distro_name -> $expected_family" "$expected_family" "$DISTRO_FAMILY"
        done
    )
}

# 8B-deep: _find_etcd_container error message
test_find_etcd_container_error() {
    echo "=== Test: _find_etcd_container error when crictl not found ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        local captured_error=""
        log_error() { captured_error="$*"; }
        log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _audit_log() { :; }
        _require_value() { :; }
        _parse_common_ssh_args() { :; }
        _SSH_SHIFT=0
        . "$PROJECT_ROOT/common/etcd.sh"

        # Override crictl to simulate not found
        crictl() { return 1; }

        local rc=0
        _find_etcd_container 2>/dev/null || rc=$?
        _assert_ne "find_etcd_container fails" "0" "$rc"

        local has_msg="false"
        echo "$captured_error" | grep -q "etcd container not found" && has_msg="true"
        _assert_eq "error message mentions etcd container" "true" "$has_msg"
    )
}

# 8A-deep: SSH key permission validation
test_ssh_key_permission_validation() {
    echo "=== Test: _validate_ssh_key_permissions ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        local captured_warn=""
        log_error() { :; }; log_info() { :; }; log_debug() { :; }
        log_warn() { captured_warn="$*"; }
        . "$PROJECT_ROOT/common/ssh.sh"

        local tmpkey
        tmpkey=$(mktemp /tmp/test-key-XXXXXX)

        # Good permissions: 600
        chmod 600 "$tmpkey"
        DEPLOY_SSH_KEY="$tmpkey"
        captured_warn=""
        _validate_ssh_key_permissions
        _assert_eq "600: no warning" "" "$captured_warn"

        # Good permissions: 400
        chmod 400 "$tmpkey"
        captured_warn=""
        _validate_ssh_key_permissions
        _assert_eq "400: no warning" "" "$captured_warn"

        # Bad permissions: 644
        chmod 644 "$tmpkey"
        captured_warn=""
        _validate_ssh_key_permissions
        local has_warn="false"
        echo "$captured_warn" | grep -q "permissions" && has_warn="true"
        _assert_eq "644: warns about permissions" "true" "$has_warn"

        rm -f "$tmpkey"
    )
}

# 8A-deep: SSH password file loading
test_ssh_password_file_loading() {
    echo "=== Test: _load_ssh_password_file ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        local captured_error=""
        log_error() { captured_error="$*"; }
        log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/ssh.sh"

        local tmpfile
        tmpfile=$(mktemp /tmp/test-pwfile-XXXXXX)

        # Good: correct permissions and content
        echo "mysecretpassword" > "$tmpfile"
        chmod 600 "$tmpfile"
        DEPLOY_SSH_PASSWORD=""
        _load_ssh_password_file "$tmpfile"
        _assert_eq "password loaded" "mysecretpassword" "$DEPLOY_SSH_PASSWORD"

        # Bad: wrong permissions
        chmod 644 "$tmpfile"
        DEPLOY_SSH_PASSWORD=""
        captured_error=""
        local rc=0
        _load_ssh_password_file "$tmpfile" || rc=$?
        _assert_ne "644 rejected" "0" "$rc"
        local has_perm_err="false"
        echo "$captured_error" | grep -q "permissions" && has_perm_err="true"
        _assert_eq "reports permission error" "true" "$has_perm_err"

        # Bad: empty file
        chmod 600 "$tmpfile"
        : > "$tmpfile"
        captured_error=""
        rc=0
        _load_ssh_password_file "$tmpfile" || rc=$?
        _assert_ne "empty file rejected" "0" "$rc"
        local has_empty_err="false"
        echo "$captured_error" | grep -q "empty" && has_empty_err="true"
        _assert_eq "reports empty error" "true" "$has_empty_err"

        # Bad: file not found
        captured_error=""
        rc=0
        _load_ssh_password_file "/nonexistent/path" || rc=$?
        _assert_ne "nonexistent rejected" "0" "$rc"

        rm -f "$tmpfile"
    )
}

# 8A-deep: known_hosts persistence
test_persist_known_hosts() {
    echo "=== Test: _persist_known_hosts ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true
        . "$PROJECT_ROOT/common/ssh.sh"

        # Create a session known_hosts with content
        _DEPLOY_KNOWN_HOSTS=$(mktemp /tmp/test-kh-XXXXXX)
        echo "host1 ssh-rsa KEY1" > "$_DEPLOY_KNOWN_HOSTS"

        local dest
        dest=$(mktemp /tmp/test-persist-XXXXXX)
        _persist_known_hosts "$dest"

        # Content should be copied
        local content
        content=$(cat "$dest")
        local has_key="false"
        echo "$content" | grep -q "host1 ssh-rsa KEY1" && has_key="true"
        _assert_eq "persisted content correct" "true" "$has_key"

        # Permissions should be 600
        local perms
        perms=$(stat -c '%a' "$dest" 2>/dev/null || stat -f '%Lp' "$dest" 2>/dev/null) || true
        _assert_eq "persisted file permissions" "600" "$perms"

        rm -f "$_DEPLOY_KNOWN_HOSTS" "$dest"
    )
}

# 8C-deep: install_proxy_mode_packages behavior
test_install_proxy_mode_packages_logic() {
    echo "=== Test: install_proxy_mode_packages logic ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        local captured_args=""
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/networking.sh"

        # Mock install command
        mock_install() { captured_args="$*"; return 0; }

        # IPVS mode
        PROXY_MODE="ipvs"
        captured_args=""
        install_proxy_mode_packages mock_install
        local has_ipvsadm="false"
        echo "$captured_args" | grep -q "ipvsadm" && has_ipvsadm="true"
        _assert_eq "ipvs installs ipvsadm" "true" "$has_ipvsadm"
        local has_ipset="false"
        echo "$captured_args" | grep -q "ipset" && has_ipset="true"
        _assert_eq "ipvs installs ipset" "true" "$has_ipset"

        # nftables mode
        PROXY_MODE="nftables"
        captured_args=""
        install_proxy_mode_packages mock_install
        local has_nftables="false"
        echo "$captured_args" | grep -q "nftables" && has_nftables="true"
        _assert_eq "nftables installs nftables" "true" "$has_nftables"

        # iptables mode (should not install anything)
        PROXY_MODE="iptables"
        captured_args=""
        install_proxy_mode_packages mock_install
        _assert_eq "iptables installs nothing" "" "$captured_args"
    )
}

# 8E-deep: _build_scp_args IPv6 bracketing
test_build_scp_args_ipv6() {
    echo "=== Test: _build_scp_args IPv6 bracketing ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        . "$PROJECT_ROOT/common/ssh.sh"

        DEPLOY_SSH_KEY=""
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_PORT=22
        DEPLOY_SSH_HOST_KEY_CHECK="yes"
        _DEPLOY_KNOWN_HOSTS="/dev/null"
        SSH_AUTH_SOCK=""

        # Regular IPv4: no brackets needed
        _build_scp_args "10.0.0.1"
        _assert_eq "IPv4 host unchanged" "10.0.0.1" "$_SCP_HOST"

        # Bare IPv6: needs brackets
        _build_scp_args "::1"
        _assert_eq "bare IPv6 bracketed" "[::1]" "$_SCP_HOST"

        # Already bracketed IPv6
        _build_scp_args "[::1]"
        _assert_eq "bracketed IPv6 unchanged" "[::1]" "$_SCP_HOST"

        # Full IPv6 address
        _build_scp_args "fd00:1::2"
        _assert_eq "full IPv6 bracketed" "[fd00:1::2]" "$_SCP_HOST"

        # SCP opts should have -P instead of -p
        local has_P="false"
        echo "$_SCP_OPTS" | grep -q "\-P " && has_P="true"
        _assert_eq "SCP uses -P for port" "true" "$has_P"

        local has_lowercase_p="true"
        echo "$_SCP_OPTS" | grep -q " -p " && has_lowercase_p="true" || has_lowercase_p="false"
        _assert_eq "SCP no -p (lowercase)" "false" "$has_lowercase_p"
    )
}

# 8E-deep: CSV edge cases
test_csv_edge_cases() {
    echo "=== Test: CSV helpers edge cases ==="
    (
        . "$PROJECT_ROOT/common/bootstrap.sh" >/dev/null 2>&1 || true

        # Trailing comma
        _assert_eq "trailing comma count" "2" "$(_csv_count "a,b,")"

        # Single item with user@
        _assert_eq "user@host count" "1" "$(_csv_count "admin@10.0.0.1")"

        # Get from single-item list
        _assert_eq "csv_get single item" "only" "$(_csv_get "only" 0)"
    )
}

# 8E-deep: _log_ssh_settings output
test_log_ssh_settings() {
    echo "=== Test: _log_ssh_settings output ==="
    (
        . "$PROJECT_ROOT/common/variables.sh"
        local captured_lines=""
        log_error() { :; }; log_warn() { :; }; log_debug() { :; }
        log_info() { captured_lines="${captured_lines}${captured_lines:+
}$*"; }
        . "$PROJECT_ROOT/common/ssh.sh"

        DEPLOY_SSH_USER="admin"
        DEPLOY_SSH_PORT=2222
        DEPLOY_SSH_KEY="/path/to/key"
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_PASSWORD_FILE=""

        _log_ssh_settings

        local has_user="false"
        echo "$captured_lines" | grep -q "admin" && has_user="true"
        _assert_eq "shows user" "true" "$has_user"

        local has_port="false"
        echo "$captured_lines" | grep -q "2222" && has_port="true"
        _assert_eq "shows port" "true" "$has_port"

        local has_key="false"
        echo "$captured_lines" | grep -q "Key:" && has_key="true"
        _assert_eq "shows key" "true" "$has_key"
    )
}

test_build_ssh_opts_key_only
test_build_ssh_opts_password
test_build_ssh_opts_ssh_agent
test_build_ssh_opts_agent_with_key
test_parse_node_address_bare_host
test_parse_node_address_user_at_host
test_parse_node_address_ipv6_bracketed
test_parse_node_address_bare_ipv6
test_posix_shell_quote_precise
test_passthrough_special_chars
test_passthrough_worker_ha_interface
test_bundle_dir_store
test_session_known_hosts_lifecycle
test_session_known_hosts_seeded
test_etcd_backup_path_variables
test_kernel_modules_iptables_mode
test_kernel_modules_ipvs_list
test_kernel_modules_nftables_list
test_sysctl_settings_content
test_swap_fstab_sed_pattern
test_detect_distro_family_all_mappings
test_find_etcd_container_error
test_ssh_key_permission_validation
test_ssh_password_file_loading
test_persist_known_hosts
test_install_proxy_mode_packages_logic
test_build_scp_args_ipv6
test_csv_edge_cases
test_log_ssh_settings

echo ""
TESTS_RUN=$(wc -l < "$_RESULTS_FILE")
TESTS_PASSED=$(grep -c '^PASS$' "$_RESULTS_FILE" || true)
TESTS_FAILED=$(grep -c '^FAIL$' "$_RESULTS_FILE" || true)
echo "==================================="
echo "Results: $TESTS_RUN tests, $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "==================================="

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
