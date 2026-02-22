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
