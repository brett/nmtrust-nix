{
  pkgs,
  lib,
  nixosModule,
  system,
}:

let
  # ── Base VM config shared by most tests ──────────────────────────────
  baseConfig =
    { config, pkgs, ... }:
    {
      imports = [ nixosModule ];
      networking.networkmanager.enable = true;

      # Tell NM to ignore the VM's built-in test interfaces so they
      # don't pollute trust state with uncontrolled connections.
      networking.networkmanager.unmanaged = [
        "eth0"
        "eth1"
        "lo"
      ];

      networking.networkmanager.ensureProfiles.profiles = {
        trusted-net = {
          connection = {
            id = "trusted-net";
            uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
            type = "dummy";
            interface-name = "dummy-trusted";
            autoconnect = "false";
          };
          ipv4.method = "manual";
          ipv4.addresses = "10.99.1.1/24";
        };
        untrusted-net = {
          connection = {
            id = "untrusted-net";
            uuid = "11111111-2222-3333-4444-555555555555";
            type = "dummy";
            interface-name = "dummy-untrusted";
            autoconnect = "false";
          };
          ipv4.method = "manual";
          ipv4.addresses = "10.99.2.1/24";
        };
        excluded-net = {
          connection = {
            id = "docker0";
            uuid = "99999999-8888-7777-6666-555555555555";
            type = "dummy";
            interface-name = "dummy-excluded";
            autoconnect = "false";
          };
          ipv4.method = "manual";
          ipv4.addresses = "10.99.3.1/24";
        };
      };

      services.nmtrust = {
        enable = true;
        trustedConnections = [ "trusted-net" ];
        excludedConnectionPatterns = [ "docker*" ];
        mixedPolicy = "untrusted";
        evalFailurePolicy = "untrusted";
        systemUnits = {
          "trust-test-canary.service" = { };
          "trust-test-offline-canary.service" = {
            allowOffline = true;
          };
        };
      };

      systemd.services.trust-test-canary = {
        description = "Trust test canary (trusted-only)";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      };
      systemd.services.trust-test-offline-canary = {
        description = "Trust test canary (trusted + offline)";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      };
    };

  # ── Shared Python helpers injected into every testScript ─────────────
  helpers = ''
    import time

    def connect(machine, iface, profile):
        """Bring up an NM dummy connection. NM creates the interface itself."""
        machine.succeed(f"nmcli connection up {profile}")

    def disconnect(machine, profile):
        """Disconnect an NM connection."""
        machine.succeed(f"nmcli connection down {profile}")

    def wait_apply(machine):
        """Explicitly trigger apply and wait for it to finish.

        Relying on the NM dispatcher debounce timer is flaky in VM tests
        due to variable boot/scheduling latency. Instead, directly start
        the apply service (which is idempotent) and wait for completion.
        """
        time.sleep(1)  # let NM finish its internal state updates
        machine.succeed("systemctl start nmtrust-apply.service")
        machine.wait_until_succeeds(
            "systemctl show nmtrust-apply.service -p ActiveState --value | grep -q inactive",
            timeout=10,
        )

    def assert_target(machine, state):
        """Assert the given trust target is active."""
        machine.succeed(f"systemctl is-active nmtrust-{state}.target")

    def assert_target_inactive(machine, state):
        """Assert the given trust target is NOT active."""
        machine.fail(f"systemctl is-active nmtrust-{state}.target")

    def assert_running(machine, unit):
        """Assert a systemd unit is active."""
        machine.succeed(f"systemctl is-active {unit}")

    def assert_stopped(machine, unit):
        """Assert a systemd unit is NOT active."""
        machine.fail(f"systemctl is-active {unit}")

    def assert_user_running(machine, user, unit):
        """Assert a user systemd unit is active."""
        machine.succeed(f"systemctl --user -M {user}@ is-active {unit}")

    def assert_user_stopped(machine, user, unit):
        """Assert a user systemd unit is NOT active."""
        machine.fail(f"systemctl --user -M {user}@ is-active {unit}")
  '';

in
{

  # ══════════════════════════════════════════════════════════════════════
  # vm-trust-states: V1, V2, V3, V4
  # Core state transitions in a single VM boot
  # ══════════════════════════════════════════════════════════════════════
  vm-trust-states = pkgs.testers.nixosTest {
    name = "vm-trust-states";
    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];
      };
    testScript = helpers + ''
      machine.wait_for_unit("multi-user.target")

      # ── V2: Boot offline ──────────────────────────────────────────────
      # No connections active on boot; NM is running but no interfaces up.
      # Trigger an initial apply so the trust system evaluates.
      machine.succeed("systemctl start nmtrust-apply.service")
      wait_apply(machine)

      assert_target(machine, "offline")
      assert_stopped(machine, "trust-test-canary.service")
      # allowOffline canary should be running in offline state
      assert_running(machine, "trust-test-offline-canary.service")

      # ── V1: Bring up trusted connection ───────────────────────────────
      connect(machine, "dummy-trusted", "trusted-net")
      wait_apply(machine)

      assert_target(machine, "trusted")
      assert_running(machine, "trust-test-canary.service")
      assert_running(machine, "trust-test-offline-canary.service")

      # ── V3: Trusted -> untrusted ──────────────────────────────────────
      # Disconnect trusted, bring up untrusted
      disconnect(machine, "trusted-net")
      connect(machine, "dummy-untrusted", "untrusted-net")
      wait_apply(machine)

      assert_target(machine, "untrusted")
      assert_stopped(machine, "trust-test-canary.service")
      assert_stopped(machine, "trust-test-offline-canary.service")

      # ── V4: Untrusted -> trusted ──────────────────────────────────────
      connect(machine, "dummy-trusted", "trusted-net")
      disconnect(machine, "untrusted-net")
      wait_apply(machine)

      assert_target(machine, "trusted")
      assert_running(machine, "trust-test-canary.service")
      assert_running(machine, "trust-test-offline-canary.service")
    '';
  };

  # ══════════════════════════════════════════════════════════════════════
  # vm-mixed-policy: V5, V6
  # Two VMs with different mixedPolicy settings
  # ══════════════════════════════════════════════════════════════════════
  vm-mixed-policy = pkgs.testers.nixosTest {
    name = "vm-mixed-policy";
    nodes.untrustedPolicy =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];
        # mixedPolicy = "untrusted" is already the default from baseConfig
      };
    nodes.trustedPolicy =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];
        services.nmtrust.mixedPolicy = lib.mkForce "trusted";
      };
    testScript = helpers + ''
      untrustedPolicy.wait_for_unit("multi-user.target")
      trustedPolicy.wait_for_unit("multi-user.target")

      # Bring up both trusted + untrusted on each VM to create mixed state
      for m in [untrustedPolicy, trustedPolicy]:
          connect(m, "dummy-trusted", "trusted-net")
          connect(m, "dummy-untrusted", "untrusted-net")

      wait_apply(untrustedPolicy)
      wait_apply(trustedPolicy)

      # ── V5: mixedPolicy = "untrusted" ────────────────────────────────
      assert_target(untrustedPolicy, "untrusted")
      assert_stopped(untrustedPolicy, "trust-test-canary.service")

      # ── V6: mixedPolicy = "trusted" ──────────────────────────────────
      assert_target(trustedPolicy, "trusted")
      assert_running(trustedPolicy, "trust-test-canary.service")
    '';
  };

  # ══════════════════════════════════════════════════════════════════════
  # vm-overrides: V7, V8, V10, V17
  # Override lifecycle tests
  # ══════════════════════════════════════════════════════════════════════
  vm-overrides = pkgs.testers.nixosTest {
    name = "vm-overrides";
    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];
      };
    testScript = helpers + ''
      machine.wait_for_unit("multi-user.target")

      # Start in untrusted state
      connect(machine, "dummy-untrusted", "untrusted-net")
      wait_apply(machine)
      assert_target(machine, "untrusted")

      # ── V7: Override force trusted ────────────────────────────────────
      machine.succeed("nmtrust override trusted")
      wait_apply(machine)

      assert_target(machine, "trusted")
      assert_running(machine, "trust-test-canary.service")

      # ── V8: Override clear ────────────────────────────────────────────
      machine.succeed("nmtrust override clear")
      wait_apply(machine)

      # Should return to computed state (untrusted, since only untrusted-net is up)
      assert_target(machine, "untrusted")
      assert_stopped(machine, "trust-test-canary.service")

      # ── V17: Malformed override file ──────────────────────────────────
      # Write garbage to the override file
      machine.succeed("echo 'garbage' > /run/nmtrust/override && chmod 0600 /run/nmtrust/override")
      machine.succeed("systemctl start nmtrust-apply.service")
      wait_apply(machine)

      # Override should be ignored; computed state used (untrusted)
      assert_target(machine, "untrusted")
      # Check journal for the warning
      machine.succeed("journalctl -u nmtrust-apply.service --no-pager -o cat | grep -q OVERRIDE_INVALID")

      # Clean up the malformed override
      machine.succeed("rm -f /run/nmtrust/override")

      # ── V10: Override cleared on reboot ───────────────────────────────
      # Set an override, then reboot
      machine.succeed("nmtrust override trusted")
      wait_apply(machine)
      assert_target(machine, "trusted")

      machine.shutdown()
      machine.start()
      machine.wait_for_unit("multi-user.target")

      # /run is tmpfs; override file should be gone after reboot
      machine.fail("test -f /run/nmtrust/override")

      # Bring up untrusted to establish a known state
      connect(machine, "dummy-untrusted", "untrusted-net")
      wait_apply(machine)

      # State should be computed from NM (untrusted), not overridden
      assert_target(machine, "untrusted")
    '';
  };

  # ══════════════════════════════════════════════════════════════════════
  # vm-debounce: V11
  # Rapid events should be coalesced
  # ══════════════════════════════════════════════════════════════════════
  vm-debounce = pkgs.testers.nixosTest {
    name = "vm-debounce";
    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];
      };
    testScript = helpers + ''
      machine.wait_for_unit("multi-user.target")

      # Count transitions before the burst
      before_count = int(machine.succeed(
          "journalctl -u nmtrust-apply.service --no-pager -o cat | grep -c TRUST_TRANSITION || echo 0"
      ).strip().split("\n")[-1])

      # Rapid-fire: create 5 dummy interfaces and up/down in quick succession
      for i in range(5):
          machine.succeed(f"ip link add dummy-rapid{i} type dummy || true")
      for i in range(5):
          machine.execute(f"nmcli connection add type dummy ifname dummy-rapid{i} con-name rapid{i} autoconnect no ipv4.method manual ipv4.addresses 10.99.10.{i+1}/24 2>/dev/null; nmcli connection up rapid{i} 2>/dev/null; nmcli connection down rapid{i} 2>/dev/null")

      # Wait for debounce to settle
      time.sleep(5)

      # Count transitions after the burst
      after_count = int(machine.succeed(
          "journalctl -u nmtrust-apply.service --no-pager -o cat | grep -c TRUST_TRANSITION || echo 0"
      ).strip().split("\n")[-1])

      new_transitions = after_count - before_count

      # With 1s debounce, rapid events should coalesce; we expect far fewer
      # than 5 transitions. Allow up to 3 to account for timing variance.
      assert new_transitions <= 3, f"Expected <=3 transitions from rapid events, got {new_transitions}"
    '';
  };

  # ══════════════════════════════════════════════════════════════════════
  # vm-eval-failure: V13, V14
  # Two VMs with different evalFailurePolicy settings
  # ══════════════════════════════════════════════════════════════════════
  vm-eval-failure = pkgs.testers.nixosTest {
    name = "vm-eval-failure";
    nodes.failUntrusted =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];
        # evalFailurePolicy = "untrusted" is the default
      };
    nodes.failOffline =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];
        services.nmtrust.evalFailurePolicy = lib.mkForce "offline";
      };
    testScript = helpers + ''
      # ── Setup: establish a known state first ──────────────────────────
      for m in [failUntrusted, failOffline]:
          m.wait_for_unit("multi-user.target")
          connect(m, "dummy-trusted", "trusted-net")
          wait_apply(m)
          assert_target(m, "trusted")

      # ── V13: evalFailurePolicy = "untrusted" ─────────────────────────
      # Stop NM to cause D-Bus eval failure, then trigger apply
      failUntrusted.succeed("systemctl stop NetworkManager.service")
      failUntrusted.succeed("systemctl start nmtrust-apply.service")
      wait_apply(failUntrusted)

      assert_target(failUntrusted, "untrusted")
      assert_stopped(failUntrusted, "trust-test-canary.service")
      failUntrusted.succeed("journalctl -u nmtrust-apply.service --no-pager -o cat | grep -q EVAL_FAILURE")

      # ── V14: evalFailurePolicy = "offline" ────────────────────────────
      failOffline.succeed("systemctl stop NetworkManager.service")
      failOffline.succeed("systemctl start nmtrust-apply.service")
      wait_apply(failOffline)

      assert_target(failOffline, "offline")
      # allowOffline canary should be running under offline policy
      assert_running(failOffline, "trust-test-offline-canary.service")
      failOffline.succeed("journalctl -u nmtrust-apply.service --no-pager -o cat | grep -q EVAL_FAILURE")
    '';
  };

  # ══════════════════════════════════════════════════════════════════════
  # vm-user-units: V15, V16
  # User unit management via trust targets
  # ══════════════════════════════════════════════════════════════════════
  vm-user-units = pkgs.testers.nixosTest {
    name = "vm-user-units";
    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];

        services.nmtrust.userUnits.testuser = {
          "trust-test-user-canary.service" = { };
        };

        users.users.testuser = {
          isNormalUser = true;
          linger = true;
        };

        systemd.user.services.trust-test-user-canary = {
          description = "Trust test canary (user)";
          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
          };
        };
      };
    testScript = helpers + ''
      machine.wait_for_unit("multi-user.target")

      # Wait for the user manager to be ready (linger)
      machine.wait_until_succeeds("systemctl --user -M testuser@ is-system-running 2>/dev/null | grep -E 'running|degraded'", timeout=30)

      # ── V15: User canary starts on trusted ────────────────────────────
      connect(machine, "dummy-trusted", "trusted-net")
      wait_apply(machine)

      assert_target(machine, "trusted")
      assert_user_running(machine, "testuser", "trust-test-user-canary.service")

      # ── V16: User canary stops on untrusted ───────────────────────────
      disconnect(machine, "trusted-net")
      connect(machine, "dummy-untrusted", "untrusted-net")
      wait_apply(machine)

      assert_target(machine, "untrusted")
      assert_user_stopped(machine, "testuser", "trust-test-user-canary.service")
    '';
  };

  # ══════════════════════════════════════════════════════════════════════
  # vm-logging: V18, V19
  # Deduplication and structured logging
  # ══════════════════════════════════════════════════════════════════════
  vm-logging = pkgs.testers.nixosTest {
    name = "vm-logging";
    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];
      };
    testScript = helpers + ''
      machine.wait_for_unit("multi-user.target")

      # Establish trusted state
      connect(machine, "dummy-trusted", "trusted-net")
      wait_apply(machine)
      assert_target(machine, "trusted")

      # Count transitions so far
      before_count = int(machine.succeed(
          "journalctl -u nmtrust-apply.service --no-pager -o cat | grep -c TRUST_TRANSITION || echo 0"
      ).strip().split("\n")[-1])

      # ── V18: State deduplication ──────────────────────────────────────
      # Trigger apply again with same state; should be no-op
      machine.succeed("systemctl start nmtrust-apply.service")
      wait_apply(machine)
      machine.succeed("systemctl start nmtrust-apply.service")
      wait_apply(machine)

      # No new TRUST_TRANSITION should be logged since state didn't change
      after_count = int(machine.succeed(
          "journalctl -u nmtrust-apply.service --no-pager -o cat | grep -c TRUST_TRANSITION || echo 0"
      ).strip().split("\n")[-1])
      assert after_count == before_count, f"Expected no new transitions (before={before_count}, after={after_count})"

      # ── V19: Structured journal log ───────────────────────────────────
      # Trigger an actual transition to get a log entry
      disconnect(machine, "trusted-net")
      connect(machine, "dummy-untrusted", "untrusted-net")
      wait_apply(machine)

      # Verify the TRUST_TRANSITION log has all required FR9 fields
      log_line = machine.succeed(
          "journalctl -u nmtrust-apply.service --no-pager -o cat | grep TRUST_TRANSITION | tail -1"
      ).strip()

      for field in ["previous_state=", "new_state=", "trigger=", "event=",
                     "connections_active=", "connections_trusted=",
                     "connections_excluded=", "override="]:
          assert field in log_line, f"Missing field '{field}' in log: {log_line}"
    '';
  };

  # ══════════════════════════════════════════════════════════════════════
  # vm-cli: V20, V21
  # CLI output tests for state and status subcommands
  # ══════════════════════════════════════════════════════════════════════
  vm-cli = pkgs.testers.nixosTest {
    name = "vm-cli";
    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];
      };
    testScript = helpers + ''
      machine.wait_for_unit("multi-user.target")

      # Establish trusted state with a known connection
      connect(machine, "dummy-trusted", "trusted-net")
      wait_apply(machine)
      assert_target(machine, "trusted")

      # ── V20: nmtrust state output ───────────────────────────────
      state_output = machine.succeed("nmtrust state")

      assert "State: trusted" in state_output, f"Expected 'State: trusted' in: {state_output}"
      assert "Override: none" in state_output, f"Expected 'Override: none' in: {state_output}"
      assert "Active target: nmtrust-trusted.target" in state_output, \
          f"Expected active target in: {state_output}"
      assert "trusted-net" in state_output, f"Expected connection name in: {state_output}"
      assert "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" in state_output, \
          f"Expected UUID in: {state_output}"

      # ── V21: nmtrust status output ──────────────────────────────
      status_output = machine.succeed("nmtrust status")

      assert "Active target: nmtrust-trusted.target" in status_output, \
          f"Expected active target in: {status_output}"
      assert "nmtrust-trusted.target" in status_output, \
          f"Expected trusted target section in: {status_output}"
      # The canary should appear in the trusted target dependencies
      assert "trust-test-canary" in status_output, \
          f"Expected canary unit in: {status_output}"
    '';
  };

  # ══════════════════════════════════════════════════════════════════════
  # vm-exclusions: V22, N4, N5
  # Excluded connection handling and edge cases
  # ══════════════════════════════════════════════════════════════════════
  vm-exclusions = pkgs.testers.nixosTest {
    name = "vm-exclusions";
    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];

        # N5: this UUID is trusted but will be used with a docker* name (excluded)
        services.nmtrust.trustedUUIDsExtra = [ "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee" ];

        # Add a profile with glob metacharacters in the name for N4
        networking.networkmanager.ensureProfiles.profiles.evil-net = {
          connection = {
            id = "*evil*";
            uuid = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee";
            type = "dummy";
            interface-name = "dummy-evil";
            autoconnect = "false";
          };
          ipv4.method = "manual";
          ipv4.addresses = "10.99.4.1/24";
        };
      };
    testScript = helpers + ''
      machine.wait_for_unit("multi-user.target")

      # ── V22: Excluded connection ignored ──────────────────────────────
      # Bring up trusted + excluded (docker0); excluded should not cause mixed
      connect(machine, "dummy-trusted", "trusted-net")
      connect(machine, "dummy-excluded", "docker0")
      wait_apply(machine)

      assert_target(machine, "trusted")
      assert_running(machine, "trust-test-canary.service")

      # Verify the excluded connection is listed as excluded in state output
      state_output = machine.succeed("nmtrust state")
      assert "excluded" in state_output, f"Expected 'excluded' label in: {state_output}"

      # Clean up
      disconnect(machine, "docker0")
      disconnect(machine, "trusted-net")
      wait_apply(machine)

      # ── N4: Glob metacharacters in connection name ────────────────────
      # Connection named "*evil*" should NOT be matched by "docker*" pattern
      # and should be treated as an untrusted connection
      connect(machine, "dummy-evil", "*evil*")
      wait_apply(machine)

      # *evil* is untrusted (not in trustedConnections, not matched by docker*)
      assert_target(machine, "untrusted")

      disconnect(machine, "*evil*")
      wait_apply(machine)

      # ── N5: Trusted + excluded overlap ────────────────────────────────
      # A connection that is both trusted by UUID and excluded by name pattern.
      # Exclusion takes precedence; connection is ignored in trust computation.
      # We use a unique UUID that is added to trustedUUIDsExtra in the test
      # config, with a connection name matching the "docker*" exclusion pattern.
      machine.succeed(
          "nmcli connection add type dummy ifname dm-dktrust "
          "con-name docker-trusted "
          "connection.uuid bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee "
          "autoconnect no "
          "ipv4.method manual ipv4.addresses 10.99.5.1/24"
      )

      # Bring up ONLY the docker-trusted connection (trusted UUID but docker* name)
      machine.succeed("nmcli connection up docker-trusted")
      wait_apply(machine)

      # Exclusion takes precedence: the connection is ignored, so we are offline
      assert_target(machine, "offline")
    '';
  };

  # ══════════════════════════════════════════════════════════════════════
  # vm-rebuild: V23
  # nixos-rebuild switch re-evaluates trust state
  # ══════════════════════════════════════════════════════════════════════
  vm-rebuild = pkgs.testers.nixosTest {
    name = "vm-rebuild";
    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];
      };
    testScript = helpers + ''
      machine.wait_for_unit("multi-user.target")

      # Establish trusted state
      connect(machine, "dummy-trusted", "trusted-net")
      wait_apply(machine)
      assert_target(machine, "trusted")
      assert_running(machine, "trust-test-canary.service")

      # Simulate a rebuild by restarting the eval service.
      # Clear state file first so eval service re-evaluates fresh.
      machine.succeed("rm -f /run/nmtrust/state")
      machine.succeed("systemctl restart nmtrust-eval.service")
      wait_apply(machine)

      # State should still be trusted (re-evaluation confirms current state)
      assert_target(machine, "trusted")
      assert_running(machine, "trust-test-canary.service")

      # Now disconnect and re-evaluate via the eval service
      disconnect(machine, "trusted-net")
      time.sleep(1)
      machine.succeed("rm -f /run/nmtrust/state")
      machine.succeed("systemctl restart nmtrust-eval.service")
      wait_apply(machine)

      assert_target(machine, "offline")
      assert_stopped(machine, "trust-test-canary.service")
      assert_running(machine, "trust-test-offline-canary.service")
    '';
  };

  # ══════════════════════════════════════════════════════════════════════
  # vm-security: N1, N2
  # Unprivileged access attempts
  # ══════════════════════════════════════════════════════════════════════
  vm-security = pkgs.testers.nixosTest {
    name = "vm-security";
    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];
        users.users.nobody-test = {
          isNormalUser = true;
          uid = 1099;
        };
      };
    testScript = helpers + ''
      machine.wait_for_unit("multi-user.target")

      # ── N1: Unprivileged override attempt ─────────────────────────────
      # nmtrust override requires root; running as unprivileged user should fail
      exit_code = machine.execute("su - nobody-test -c 'nmtrust override trusted'")[0]
      assert exit_code != 0, "Expected non-zero exit code for unprivileged override"

      # Verify no override file was created
      machine.fail("test -f /run/nmtrust/override")

      # ── N2: Unprivileged directory access ─────────────────────────────
      # /run/nmtrust/ is 0700 root:root; unprivileged user cannot list it
      machine.fail("su - nobody-test -c 'ls /run/nmtrust/'")

      # Also verify unprivileged user cannot read state file
      # First create one by triggering apply
      machine.succeed("systemctl start nmtrust-apply.service")
      wait_apply(machine)
      machine.fail("su - nobody-test -c 'cat /run/nmtrust/state'")
    '';
  };

  # ══════════════════════════════════════════════════════════════════════
  # vm-latency: P1
  # Transition latency measurement
  # ══════════════════════════════════════════════════════════════════════
  vm-latency = pkgs.testers.nixosTest {
    name = "vm-latency";
    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [ baseConfig ];
      };
    testScript = helpers + ''
      import time as pytime

      machine.wait_for_unit("multi-user.target")

      # Start from offline with known state
      machine.succeed("systemctl start nmtrust-apply.service")
      wait_apply(machine)

      # Measure transition: offline -> trusted
      connect(machine, "dummy-trusted", "trusted-net")

      start = pytime.monotonic()
      # Wait up to 5 seconds for the trusted target to become active
      machine.wait_until_succeeds(
          "systemctl is-active nmtrust-trusted.target",
          timeout=5
      )
      elapsed = pytime.monotonic() - start

      # After 1s debounce, target activation should happen quickly.
      # Total should be under 4 seconds (1s debounce + 3s generous margin).
      assert elapsed < 4, f"Transition took {elapsed:.1f}s, expected < 4s"

      # Log the actual latency for visibility
      machine.log(f"Transition latency: {elapsed:.2f}s")
    '';
  };

}
