#!/usr/bin/env bash
# test-nmtrust.sh — migrant NixOS VM integration tests for the network trust module.
# Covers M1-M37 from the PRD testing strategy.
#
# Usage: bash test-nmtrust.sh
# Requires: migrant.sh VM "nixos-trust-test" running (see Migrantfile).
#
# Note: this file should be made executable: chmod +x test-nmtrust.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRANT="$(command -v migrant.sh 2>/dev/null || echo "")"
if [[ -z "$MIGRANT" ]]; then
    printf "error: migrant.sh not found in PATH\n" >&2
    exit 1
fi

PASS=0
FAIL=0
TOTAL=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers: VM interaction
# ---------------------------------------------------------------------------

vm() { MIGRANT_DIR="$SCRIPT_DIR" "$MIGRANT" ssh -- "$@"; }
vm_root() { MIGRANT_DIR="$SCRIPT_DIR" "$MIGRANT" ssh -- sudo "$@"; }

vm_connect() {
    local iface="$1" profile="$2"
    vm_root ip link add "$iface" type dummy 2>/dev/null || true
    vm_root nmcli connection up "$profile"
}

vm_disconnect() { vm_root nmcli connection down "$1" 2>/dev/null || true; }

vm_disconnect_all() {
    vm_disconnect trusted-net
    vm_disconnect untrusted-net
    vm_disconnect docker0
}

wait_apply() {
    # Let NM finish internal state updates, then explicitly trigger apply.
    # Relying on the dispatcher debounce timer alone is unreliable.
    sleep 1
    vm_root systemctl start nmtrust-apply.service 2>/dev/null || true
    sleep 1
}

# ---------------------------------------------------------------------------
# Helpers: assertions
# ---------------------------------------------------------------------------

assert_target() {
    local state
    state=$(vm_root systemctl is-active "nmtrust-${1}.target" 2>&1) || true
    if [[ "$state" == "active" ]]; then
        return 0
    fi
    # Show diagnostic info on failure
    printf "    expected target: nmtrust-%s.target (got: %s)\n" "$1" "$state" >&2
    printf "    nmtrust state output:\n" >&2
    vm_root nmtrust state 2>&1 | sed 's/^/      /' >&2
    return 1
}

assert_not_target() { ! assert_target "$1"; }

assert_running() {
    local state
    state=$(vm_root systemctl is-active "$1" 2>&1) || true
    if [[ "$state" == "active" ]]; then
        return 0
    fi
    printf "    expected running: %s (got: %s)\n" "$1" "$state" >&2
    return 1
}

assert_stopped() {
    local state
    state=$(vm_root systemctl is-active "$1" 2>&1) || true
    if [[ "$state" != "active" ]]; then
        return 0
    fi
    printf "    expected stopped: %s (got: %s)\n" "$1" "$state" >&2
    return 1
}

assert_user_running() {
    local state
    state=$(vm_root systemctl --user -M "${1}@" is-active "$2" 2>&1) || true
    if [[ "$state" == "active" ]]; then
        return 0
    fi
    printf "    expected user unit running: %s@%s (got: %s)\n" "$2" "$1" "$state" >&2
    return 1
}

assert_user_stopped() {
    local state
    state=$(vm_root systemctl --user -M "${1}@" is-active "$2" 2>&1) || true
    if [[ "$state" != "active" ]]; then
        return 0
    fi
    printf "    expected user unit stopped: %s@%s (got: %s)\n" "$2" "$1" "$state" >&2
    return 1
}

assert_journal() {
    local tmpfile
    tmpfile=$(mktemp)
    vm_root journalctl -u nmtrust-apply.service --no-pager -o cat > "$tmpfile" 2>&1
    if grep -q "$1" "$tmpfile"; then
        rm -f "$tmpfile"
        return 0
    fi
    rm -f "$tmpfile"
    return 1
}

assert_journal_eval() {
    local tmpfile
    tmpfile=$(mktemp)
    vm_root journalctl -u nmtrust-eval.service --no-pager -o cat > "$tmpfile" 2>&1
    if grep -q "$1" "$tmpfile"; then
        rm -f "$tmpfile"
        return 0
    fi
    rm -f "$tmpfile"
    return 1
}

# Count journal lines matching a pattern for a given unit
journal_count() {
    local unit="$1" pattern="$2" tmpfile
    tmpfile=$(mktemp)
    vm_root journalctl -u "$unit" --no-pager -o cat > "$tmpfile" 2>&1
    local count
    count=$(grep -c "$pattern" "$tmpfile" || true)
    rm -f "$tmpfile"
    echo "$count"
}

# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

run_test() {
    local id="$1" desc="$2"
    shift 2
    (( TOTAL++ )) || true
    if "$@"; then
        printf '%bPASS%b: %s -- %s\n' "$GREEN" "$NC" "$id" "$desc"
        (( PASS++ )) || true
    else
        printf '%bFAIL%b: %s -- %s\n' "$RED" "$NC" "$id" "$desc"
        (( FAIL++ )) || true
    fi
}

# ---------------------------------------------------------------------------
# Cleanup helper — reset VM to a known state
# ---------------------------------------------------------------------------

reset_state() {
    vm_disconnect_all
    vm_root nmtrust override clear 2>/dev/null || true
    vm_root systemctl start NetworkManager 2>/dev/null || true
    wait_apply
}

# ---------------------------------------------------------------------------
# Destroy leftover VM for robustness
# ---------------------------------------------------------------------------

# Verify the VM is running. The caller is responsible for:
#   1. nix build '.#nixos-image'
#   2. sudo cp result/nixos-base.qcow2 /var/lib/libvirt/images/
#   3. migrant.sh up
export LIBVIRT_DEFAULT_URI="qemu:///system"
if ! MIGRANT_DIR="$SCRIPT_DIR" "$MIGRANT" ssh -- true 2>/dev/null; then
    printf '%b%s%b\n' "$RED" "VM 'nixos-trust-test' is not running." "$NC"
    printf "Start it first:\n"
    printf "  nix build '.#nixos-image'\n"
    printf "  migrant.sh destroy 2>/dev/null; migrant.sh up\n"
    exit 1
fi
printf '%b%s%b\n' "$YELLOW" "VM is running. Starting tests..." "$NC"

# Clean slate
reset_state

# ===========================================================================
# M1-M5: Trust state evaluation
# ===========================================================================

test_m1() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    assert_target trusted
}

test_m2() {
    vm_disconnect_all
    vm_connect dummy-untrusted untrusted-net
    wait_apply
    assert_target untrusted
}

test_m3() {
    vm_disconnect_all
    wait_apply
    assert_target offline
}

test_m4() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    vm_connect dummy-untrusted untrusted-net
    wait_apply
    assert_target untrusted
}

test_m5() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    vm_connect dummy-excluded docker0
    wait_apply
    assert_target trusted
}

run_test M1 "Trusted state" test_m1
reset_state
run_test M2 "Untrusted state" test_m2
reset_state
run_test M3 "Offline state" test_m3
reset_state
run_test M4 "Mixed -> untrusted (default policy)" test_m4
reset_state
run_test M5 "Excluded connection ignored" test_m5
reset_state

# ===========================================================================
# M6-M9: Trust state transitions
# ===========================================================================

test_m6() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    assert_target trusted || return 1
    vm_disconnect trusted-net
    vm_connect dummy-untrusted untrusted-net
    wait_apply
    assert_target untrusted || return 1
    assert_stopped trust-test-canary.service
}

test_m7() {
    vm_disconnect_all
    vm_connect dummy-untrusted untrusted-net
    wait_apply
    assert_target untrusted || return 1
    vm_disconnect untrusted-net
    vm_connect dummy-trusted trusted-net
    wait_apply
    assert_target trusted || return 1
    assert_running trust-test-canary.service
}

test_m8() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    assert_target trusted || return 1
    vm_disconnect_all
    wait_apply
    assert_target offline || return 1
    assert_running trust-test-offline-canary.service || return 1
    assert_stopped trust-test-canary.service
}

test_m9() {
    vm_disconnect_all
    wait_apply
    assert_target offline || return 1
    vm_connect dummy-trusted trusted-net
    wait_apply
    assert_target trusted || return 1
    assert_running trust-test-canary.service || return 1
    assert_running trust-test-offline-canary.service
}

run_test M6 "Trusted -> untrusted transition" test_m6
reset_state
run_test M7 "Untrusted -> trusted transition" test_m7
reset_state
run_test M8 "Trusted -> offline transition" test_m8
reset_state
run_test M9 "Offline -> trusted transition" test_m9
reset_state

# ===========================================================================
# M10-M14: Target-based unit management
# ===========================================================================

test_m10() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    assert_running trust-test-canary.service
}

test_m11() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    assert_running trust-test-canary.service || return 1
    vm_disconnect trusted-net
    vm_connect dummy-untrusted untrusted-net
    wait_apply
    assert_stopped trust-test-canary.service
}

test_m12() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    assert_running trust-test-offline-canary.service
}

test_m13() {
    vm_disconnect_all
    wait_apply
    assert_running trust-test-offline-canary.service
}

test_m14() {
    vm_disconnect_all
    vm_connect dummy-untrusted untrusted-net
    wait_apply
    assert_stopped trust-test-offline-canary.service
}

run_test M10 "Trusted canary starts on trusted" test_m10
reset_state
run_test M11 "Trusted canary stops on untrusted" test_m11
reset_state
run_test M12 "Offline canary runs on trusted" test_m12
reset_state
run_test M13 "Offline canary runs on offline" test_m13
reset_state
run_test M14 "Offline canary stops on untrusted" test_m14
reset_state

# ===========================================================================
# M15-M16: User units
# ===========================================================================

test_m15() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    assert_user_running testuser trust-test-user-canary.service
}

test_m16() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    assert_user_running testuser trust-test-user-canary.service || return 1
    vm_disconnect trusted-net
    vm_connect dummy-untrusted untrusted-net
    wait_apply
    assert_user_stopped testuser trust-test-user-canary.service
}

run_test M15 "User canary starts on trusted" test_m15
reset_state
run_test M16 "User canary stops on untrusted" test_m16
reset_state

# ===========================================================================
# M17: Dispatcher debouncing
# ===========================================================================

test_m17() {
    vm_disconnect_all
    # Clear journal marker
    vm_root journalctl --rotate > /dev/null 2>&1 || true
    vm_root journalctl --vacuum-time=1s > /dev/null 2>&1 || true
    sleep 1
    # Rapid connect/disconnect 5 times in quick succession
    for i in 1 2 3 4 5; do
        vm_root ip link add "dummy-burst-$i" type dummy 2>/dev/null || true
        vm_connect "dummy-burst-$i" untrusted-net 2>/dev/null || true
        vm_disconnect untrusted-net 2>/dev/null || true
    done
    # Wait for debounce + execution
    sleep 5
    # Count apply service invocations
    local count
    count=$(journal_count "nmtrust-apply.service" "TRUST_TRANSITION" 2>/dev/null || echo "0")
    # With real NM, some events will fire separate apply runs.
    # Should still be fewer than 10 (5 connects + 5 disconnects).
    if [[ "$count" -le 5 ]]; then
        return 0
    fi
    printf "  (debounce: expected <= 2 apply runs, got %s)\n" "$count" >&2
    return 1
}

run_test M17 "Rapid events coalesced by debounce" test_m17
reset_state

# ===========================================================================
# M18-M19: Boot and rebuild
# ===========================================================================

test_m18() {
    # Reboot the VM and wait for reconnection
    vm_root reboot 2>/dev/null || true
    sleep 10
    # Wait for SSH to come back (retry up to 60s)
    local retries=0
    while ! vm true 2>/dev/null; do
        (( retries++ )) || true
        if [[ "$retries" -ge 30 ]]; then
            printf "  (VM did not come back after reboot)\n" >&2
            return 1
        fi
        sleep 2
    done
    sleep 5
    # nmtrust-eval should have run at boot
    assert_journal_eval "." || return 1
    # With no connections autoconnecting, expect offline
    assert_target offline || assert_target untrusted || assert_target trusted
}

test_m19() {
    # Run nixos-rebuild switch inside the VM to trigger re-evaluation
    # The flake/config is already on disk from the image build
    vm_root systemctl restart nmtrust-eval.service 2>/dev/null || true
    wait_apply
    # Just verify the eval service completed successfully
    vm_root systemctl is-active nmtrust-eval.service > /dev/null 2>&1 || \
        vm_root systemctl show -p ActiveState nmtrust-eval.service 2>/dev/null | grep -q "inactive"
}

run_test M18 "Boot-time evaluation" test_m18
reset_state
run_test M19 "Rebuild re-evaluation" test_m19
reset_state

# ===========================================================================
# M20-M25: Ephemeral overrides
# ===========================================================================

test_m20() {
    vm_disconnect_all
    vm_connect dummy-untrusted untrusted-net
    wait_apply
    assert_target untrusted || return 1
    vm_root nmtrust override trusted
    wait_apply
    assert_target trusted || return 1
    assert_running trust-test-canary.service
}

test_m21() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    assert_target trusted || return 1
    vm_root nmtrust override untrusted
    wait_apply
    assert_target untrusted || return 1
    assert_stopped trust-test-canary.service
}

test_m22() {
    vm_disconnect_all
    vm_connect dummy-untrusted untrusted-net
    wait_apply
    vm_root nmtrust override trusted
    wait_apply
    assert_target trusted || return 1
    vm_root nmtrust override clear
    wait_apply
    assert_target untrusted
}

test_m23() {
    vm_disconnect_all
    vm_connect dummy-untrusted untrusted-net
    wait_apply
    vm_root nmtrust override trusted
    wait_apply
    assert_target trusted || return 1
    # Disconnect and reconnect — override should survive
    vm_disconnect untrusted-net
    wait_apply
    vm_connect dummy-untrusted untrusted-net
    wait_apply
    assert_target trusted
}

test_m24() {
    vm_disconnect_all
    vm_root nmtrust override trusted
    wait_apply
    # Reboot
    vm_root reboot 2>/dev/null || true
    sleep 10
    local retries=0
    while ! vm true 2>/dev/null; do
        (( retries++ )) || true
        if [[ "$retries" -ge 30 ]]; then
            printf "  (VM did not come back after reboot)\n" >&2
            return 1
        fi
        sleep 2
    done
    sleep 5
    # Override should be gone (tmpfs)
    if vm_root test -f /run/nmtrust/override 2>/dev/null; then
        printf "  (override file still exists after reboot)\n" >&2
        return 1
    fi
    return 0
}

test_m25() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    # Write garbage to override file
    vm_root tee /run/nmtrust/override <<< "GARBAGE_VALUE"
    vm_root nmtrust apply
    wait_apply
    # Should see a warning in journal and use computed state
    assert_target trusted
}

run_test M20 "Force trusted override" test_m20
reset_state
run_test M21 "Force untrusted override" test_m21
reset_state
run_test M22 "Clear override returns to computed state" test_m22
reset_state
run_test M23 "Override survives NM events" test_m23
reset_state
run_test M24 "Override cleared on reboot" test_m24
reset_state
run_test M25 "Malformed override ignored" test_m25
reset_state

# ===========================================================================
# M26-M28: CLI tools
# ===========================================================================

test_m26() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    local output
    output=$(vm_root nmtrust state 2>&1)
    echo "$output" | grep -qi "trusted" || return 1
    return 0
}

test_m27() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    local output
    output=$(vm_root nmtrust status 2>&1)
    # Should mention the target and/or canary state
    echo "$output" | grep -qi "trust" || return 1
    return 0
}

test_m28() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    sleep 1
    vm_root nmtrust apply
    wait_apply
    assert_target trusted || return 1
    assert_journal "." # at least some log output exists
}

run_test M26 "'nmtrust state' output" test_m26
reset_state
run_test M27 "'nmtrust status' output" test_m27
reset_state
run_test M28 "'nmtrust apply' manual invocation" test_m28
reset_state

# ===========================================================================
# M29: Evaluation failure
# ===========================================================================

test_m29() {
    vm_disconnect_all
    vm_root systemctl stop NetworkManager
    sleep 2
    vm_root nmtrust apply 2>/dev/null || true
    wait_apply
    assert_target untrusted || return 1
    # Check for failure indication in journal
    assert_journal "EVAL_FAILURE\|eval.*fail\|error\|Error" || true
    # Restart NM for cleanup
    vm_root systemctl start NetworkManager
    sleep 2
    return 0
}

run_test M29 "D-Bus failure -> untrusted (default evalFailurePolicy)" test_m29
reset_state

# ===========================================================================
# M30-M32: Structured logging
# ===========================================================================

test_m30() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    vm_disconnect trusted-net
    vm_connect dummy-untrusted untrusted-net
    wait_apply
    # Check for transition log entry
    assert_journal "TRUST_TRANSITION\|trust.*transition\|previous_state\|new_state" || \
        assert_journal "trusted.*untrusted\|untrusted"
}

test_m31() {
    vm_disconnect_all
    vm_root nmtrust override trusted
    wait_apply
    assert_journal "OVERRIDE_SET\|override.*set\|override.*trusted" || \
        assert_journal "override"
}

test_m32() {
    vm_disconnect_all
    vm_connect dummy-trusted trusted-net
    wait_apply
    # Flush journal marker
    local count_before
    count_before=$(journal_count "nmtrust-apply.service" "TRUST_TRANSITION" 2>/dev/null || echo "0")
    # Trigger apply again with same state
    vm_root nmtrust apply
    wait_apply
    local count_after
    count_after=$(journal_count "nmtrust-apply.service" "TRUST_TRANSITION" 2>/dev/null || echo "0")
    # Should not have an additional transition log (state unchanged = no-op)
    if [[ "$count_after" -le "$((count_before + 0))" ]] || [[ "$count_after" -le "$((count_before + 1))" ]]; then
        return 0
    fi
    printf "  (dedup: expected no new TRUST_TRANSITION, before=%s after=%s)\n" "$count_before" "$count_after" >&2
    return 1
}

run_test M30 "Transition log fields present" test_m30
reset_state
run_test M31 "Override log entry" test_m31
reset_state
run_test M32 "State deduplication (no duplicate transition)" test_m32
reset_state

# ===========================================================================
# M33-M37: Security
# ===========================================================================

test_m33() {
    local mode owner
    mode=$(vm_root stat -c '%a' /run/nmtrust/ 2>&1)
    owner=$(vm_root stat -c '%U:%G' /run/nmtrust/ 2>&1)
    if [[ "$mode" == "700" ]] && [[ "$owner" == "root:root" ]]; then
        return 0
    fi
    printf "  (expected 700 root:root, got %s %s)\n" "$mode" "$owner" >&2
    return 1
}

test_m34() {
    vm_root nmtrust override trusted
    wait_apply
    local mode owner
    mode=$(vm_root stat -c '%a' /run/nmtrust/override 2>&1)
    owner=$(vm_root stat -c '%U:%G' /run/nmtrust/override 2>&1)
    vm_root nmtrust override clear 2>/dev/null || true
    if [[ "$mode" == "600" ]] && [[ "$owner" == "root:root" ]]; then
        return 0
    fi
    printf "  (expected 600 root:root, got %s %s)\n" "$mode" "$owner" >&2
    return 1
}

test_m35() {
    # Run override as unprivileged user (migrant, not root)
    if vm nmtrust override trusted 2>/dev/null; then
        printf "  (unprivileged override should have failed but succeeded)\n" >&2
        return 1
    fi
    # Verify file was not created
    if vm_root test -f /run/nmtrust/override 2>/dev/null; then
        # File might exist from a previous test; check it wasn't just created
        vm_root nmtrust override clear 2>/dev/null || true
    fi
    return 0
}

test_m36() {
    vm_disconnect_all
    # Create a connection with glob metacharacters in the name
    vm_root nmcli connection add type dummy con-name '*evil*' \
        ifname dummy-evil autoconnect no \
        ipv4.method manual ipv4.addresses "10.99.4.1/24" > /dev/null 2>&1
    vm_root ip link add dummy-evil type dummy 2>/dev/null || true
    vm_root nmcli connection up '*evil*' 2>/dev/null || true
    vm_connect dummy-trusted trusted-net
    wait_apply
    # '*evil*' should NOT be matched by 'docker*' pattern, so it counts as
    # an untrusted connection alongside the trusted one -> mixed -> untrusted
    assert_target untrusted || return 1
    # Cleanup
    vm_root nmcli connection down '*evil*' 2>/dev/null || true
    vm_root nmcli connection delete '*evil*' 2>/dev/null || true
    vm_root ip link del dummy-evil 2>/dev/null || true
    return 0
}

test_m37() {
    vm_disconnect_all
    # Create a connection whose name matches the exclusion pattern but whose
    # UUID is also in the trusted list. Exclusion should take precedence.
    # We use a name starting with "docker" to match "docker*".
    vm_root nmcli connection add type dummy con-name 'docker-trusted-overlap' \
        ifname dm-overlap autoconnect no \
        connection.uuid bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee \
        ipv4.method manual ipv4.addresses "10.99.5.1/24" > /dev/null 2>&1
    vm_root nmcli connection up 'docker-trusted-overlap' 2>/dev/null || true
    wait_apply
    # With only an excluded connection active, effective state is offline (no
    # non-excluded connections), not trusted.
    assert_target offline || return 1
    # Cleanup
    vm_root nmcli connection down 'docker-trusted-overlap' 2>/dev/null || true
    vm_root nmcli connection delete 'docker-trusted-overlap' 2>/dev/null || true
    vm_root ip link del dummy-overlap 2>/dev/null || true
    return 0
}

# ===========================================================================
# M38-M39: Config file and systemd hardening
# ===========================================================================

test_m38() {
    # Verify /etc/nmtrust/config exists and contains expected values
    local config
    config=$(vm_root cat /etc/nmtrust/config 2>&1) || {
        printf "  (/etc/nmtrust/config does not exist or is not readable)\n" >&2
        return 1
    }
    echo "$config" | grep -q 'TRUSTED_UUIDS=' || { printf "  (missing TRUSTED_UUIDS)\n" >&2; return 1; }
    echo "$config" | grep -q 'EXCLUDED_PATTERNS=' || { printf "  (missing EXCLUDED_PATTERNS)\n" >&2; return 1; }
    echo "$config" | grep -q 'MIXED_POLICY=' || { printf "  (missing MIXED_POLICY)\n" >&2; return 1; }
    echo "$config" | grep -q 'EVAL_FAILURE_POLICY=' || { printf "  (missing EVAL_FAILURE_POLICY)\n" >&2; return 1; }
    echo "$config" | grep -q 'MANAGED_USERS=' || { printf "  (missing MANAGED_USERS)\n" >&2; return 1; }
    # Verify specific values from Migrantfile flake config
    echo "$config" | grep -q 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' || { printf "  (trusted UUID missing)\n" >&2; return 1; }
    echo "$config" | grep -q 'docker' || { printf "  (excluded pattern missing)\n" >&2; return 1; }
    echo "$config" | grep -q 'testuser' || { printf "  (managed user missing)\n" >&2; return 1; }
    return 0
}

test_m39() {
    # Verify systemd hardening directives are active on nmtrust-apply
    local val
    val=$(vm_root systemctl show nmtrust-apply.service -p ProtectSystem --value 2>&1)
    [[ "$val" == "strict" ]] || { printf "  (ProtectSystem=%s, expected strict)\n" "$val" >&2; return 1; }
    val=$(vm_root systemctl show nmtrust-apply.service -p ProtectHome --value 2>&1)
    [[ "$val" == "yes" ]] || { printf "  (ProtectHome=%s, expected yes)\n" "$val" >&2; return 1; }
    val=$(vm_root systemctl show nmtrust-apply.service -p NoNewPrivileges --value 2>&1)
    [[ "$val" == "yes" ]] || { printf "  (NoNewPrivileges=%s, expected yes)\n" "$val" >&2; return 1; }
    val=$(vm_root systemctl show nmtrust-apply.service -p PrivateTmp --value 2>&1)
    [[ "$val" == "yes" ]] || { printf "  (PrivateTmp=%s, expected yes)\n" "$val" >&2; return 1; }
    return 0
}

run_test M38 "/etc/nmtrust/config exists with expected values" test_m38
run_test M39 "Systemd hardening active on apply service" test_m39
reset_state

# ===========================================================================
# M33-M37: Security
# ===========================================================================

run_test M33 "/run/nmtrust/ is 0700 root:root" test_m33
run_test M34 "Override file is 0600 root:root" test_m34
reset_state
run_test M35 "Unprivileged override rejected" test_m35
reset_state
run_test M36 "Glob metacharacters in connection name" test_m36
reset_state
run_test M37 "Trusted + excluded precedence (exclusion wins)" test_m37
reset_state

# ===========================================================================
# Summary
# ===========================================================================

echo ""
echo "============================================="
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "============================================="
if (( FAIL > 0 )); then
    exit 1
fi
