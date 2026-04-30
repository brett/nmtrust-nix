{
  pkgs,
  lib,
  nixosModule,
}:

let
  # Helper: evaluate a NixOS configuration with the trust module loaded
  evalConfig =
    modules:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ nixosModule ] ++ modules;
    }).config;

  # Minimal base config that every test needs to make NixOS evaluation happy
  baseModule =
    { config, pkgs, ... }:
    {
      boot.loader.grub.device = "nodev";
      fileSystems."/" = {
        device = "/dev/sda1";
        fsType = "ext4";
      };
      system.stateVersion = "25.11";
      networking.networkmanager.enable = true;
    };

  # Helper: check whether all assertions pass for a given config
  # Returns true if the config evaluates and all assertions hold.
  # Returns false if any assertion fails (assertion = false).
  # Throws if eval itself fails (e.g., type error).
  assertionsPassing =
    modules:
    let
      cfg = evalConfig ([ baseModule ] ++ modules);
      asserts = cfg.assertions;
    in
    builtins.all (a: a.assertion) asserts;

  # Helper: check whether evaluation itself succeeds (catches type errors)
  # Forces deep evaluation of the trust config to trigger type errors.
  evalSucceeds =
    modules:
    let
      cfg = evalConfig ([ baseModule ] ++ modules);
      result = builtins.tryEval (builtins.deepSeq cfg.services.nmtrust true);
    in
    result.success;

  # A sample ensureProfiles entry with a UUID, used by multiple tests
  sampleProfileModule =
    { config, ... }:
    {
      networking.networkmanager.ensureProfiles.profiles.home-wifi = {
        connection = {
          id = "home-wifi";
          uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";
          type = "wifi";
        };
        wifi.ssid = "HomeNetwork";
      };
    };

  # A sample ensureProfiles entry WITHOUT a uuid field
  profileNoUUIDModule =
    { config, ... }:
    {
      networking.networkmanager.ensureProfiles.profiles.broken-wifi = {
        connection = {
          id = "broken-wifi";
          type = "wifi";
        };
        wifi.ssid = "BrokenNetwork";
      };
    };

  # Reference config: enabled with a valid trusted connection
  refConfig = evalConfig [
    baseModule
    sampleProfileModule
    (
      { config, ... }:
      {
        services.nmtrust = {
          enable = true;
          trustedConnections = [ "home-wifi" ];
        };
      }
    )
  ];

  # Reference config: enabled with userUnits (linger user)
  userRefConfig = evalConfig [
    baseModule
    sampleProfileModule
    (
      { config, ... }:
      {
        users.users.alice = {
          isNormalUser = true;
          linger = true;
        };
        services.nmtrust = {
          enable = true;
          trustedConnections = [ "home-wifi" ];
          userUnits.alice."syncthing.service" = {
            allowOffline = false;
          };
        };
      }
    )
  ];

  # Reference config: system unit with allowOffline=true
  offlineRefConfig = evalConfig [
    baseModule
    sampleProfileModule
    (
      { config, ... }:
      {
        services.nmtrust = {
          enable = true;
          trustedConnections = [ "home-wifi" ];
          systemUnits."my-sync.service" = {
            allowOffline = true;
          };
        };
      }
    )
  ];

  # Reference config: system unit with allowOffline=false
  noOfflineRefConfig = evalConfig [
    baseModule
    sampleProfileModule
    (
      { config, ... }:
      {
        services.nmtrust = {
          enable = true;
          trustedConnections = [ "home-wifi" ];
          systemUnits."my-sync.service" = {
            allowOffline = false;
          };
        };
      }
    )
  ];

  # Disabled config
  disabledConfig = evalConfig [
    baseModule
    (
      { config, ... }:
      {
        services.nmtrust.enable = false;
      }
    )
  ];

in
{

  # -----------------------------------------------------------------------
  # E1: trustedConnections references nonexistent profile -> assertion failure
  # -----------------------------------------------------------------------
  eval-e1-missing-profile =
    let
      passes = assertionsPassing [
        (
          { config, ... }:
          {
            services.nmtrust = {
              enable = true;
              trustedConnections = [ "nonexistent-profile" ];
            };
          }
        )
      ];
    in
    assert !passes;
    pkgs.runCommand "eval-e1-missing-profile" { } ''
      echo "PASS: assertion fires for missing profile"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E2: trustedConnections references profile without UUID -> assertion failure
  # -----------------------------------------------------------------------
  eval-e2-profile-no-uuid =
    let
      passes = assertionsPassing [
        profileNoUUIDModule
        (
          { config, ... }:
          {
            services.nmtrust = {
              enable = true;
              trustedConnections = [ "broken-wifi" ];
            };
          }
        )
      ];
    in
    assert !passes;
    pkgs.runCommand "eval-e2-profile-no-uuid" { } ''
      echo "PASS: assertion fires for profile without UUID"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E3: trustedUUIDsExtra with malformed UUID -> type error at eval
  # -----------------------------------------------------------------------
  eval-e3-malformed-uuid =
    let
      succeeds = evalSucceeds [
        (
          { config, ... }:
          {
            services.nmtrust = {
              enable = true;
              trustedUUIDsExtra = [ "not-a-uuid" ];
            };
          }
        )
      ];
    in
    assert !succeeds;
    pkgs.runCommand "eval-e3-malformed-uuid" { } ''
      echo "PASS: type error for malformed UUID"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E4: trustedUUIDsExtra with valid UUID -> passes
  # -----------------------------------------------------------------------
  eval-e4-valid-uuid =
    let
      passes = assertionsPassing [
        (
          { config, ... }:
          {
            services.nmtrust = {
              enable = true;
              trustedUUIDsExtra = [ "a1b2c3d4-e5f6-7890-abcd-ef1234567890" ];
            };
          }
        )
      ];
    in
    assert passes;
    pkgs.runCommand "eval-e4-valid-uuid" { } ''
      echo "PASS: valid UUID accepted"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E5: userUnits references nonexistent user -> assertion failure
  # -----------------------------------------------------------------------
  eval-e5-missing-user =
    let
      passes = assertionsPassing [
        sampleProfileModule
        (
          { config, ... }:
          {
            services.nmtrust = {
              enable = true;
              trustedConnections = [ "home-wifi" ];
              userUnits.ghost-user."foo.service" = { };
            };
          }
        )
      ];
    in
    assert !passes;
    pkgs.runCommand "eval-e5-missing-user" { } ''
      echo "PASS: assertion fires for nonexistent user"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E6: userUnits user exists but linger not enabled -> assertion failure
  # -----------------------------------------------------------------------
  eval-e6-no-linger =
    let
      passes = assertionsPassing [
        sampleProfileModule
        (
          { config, ... }:
          {
            users.users.bob = {
              isNormalUser = true;
              # linger defaults to false
            };
            services.nmtrust = {
              enable = true;
              trustedConnections = [ "home-wifi" ];
              userUnits.bob."foo.service" = { };
            };
          }
        )
      ];
    in
    assert !passes;
    pkgs.runCommand "eval-e6-no-linger" { } ''
      echo "PASS: assertion fires for user without linger"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E7: userUnits user with linger=true -> passes; user targets generated
  # -----------------------------------------------------------------------
  eval-e7-user-linger =
    let
      passes = assertionsPassing [
        sampleProfileModule
        (
          { config, ... }:
          {
            users.users.alice = {
              isNormalUser = true;
              linger = true;
            };
            services.nmtrust = {
              enable = true;
              trustedConnections = [ "home-wifi" ];
              userUnits.alice."syncthing.service" = { };
            };
          }
        )
      ];
      # Check user targets are generated
      hasUserTargets =
        userRefConfig.systemd.user.targets ? "nmtrust-trusted"
        && userRefConfig.systemd.user.targets ? "nmtrust-untrusted"
        && userRefConfig.systemd.user.targets ? "nmtrust-offline";
    in
    assert passes;
    assert hasUserTargets;
    pkgs.runCommand "eval-e7-user-linger" { } ''
      echo "PASS: user with linger accepted, user targets generated"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E8: systemUnits with allowOffline=true -> bound to trusted + offline
  # -----------------------------------------------------------------------
  eval-e8-allow-offline =
    let
      svc = offlineRefConfig.systemd.services."my-sync";
      wantedBy = svc.wantedBy;
      stopWhenUnneeded = svc.unitConfig.StopWhenUnneeded;
      hasTrusted = builtins.elem "nmtrust-trusted.target" wantedBy;
      hasOffline = builtins.elem "nmtrust-offline.target" wantedBy;
    in
    assert stopWhenUnneeded;
    assert hasTrusted;
    assert hasOffline;
    pkgs.runCommand "eval-e8-allow-offline" { } ''
      echo "PASS: allowOffline=true binds to trusted + offline targets with StopWhenUnneeded"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E9: systemUnits with allowOffline=false -> only bound to trusted
  # -----------------------------------------------------------------------
  eval-e9-no-offline =
    let
      svc = noOfflineRefConfig.systemd.services."my-sync";
      wantedBy = svc.wantedBy;
      stopWhenUnneeded = svc.unitConfig.StopWhenUnneeded;
      hasTrusted = builtins.elem "nmtrust-trusted.target" wantedBy;
      noOffline = !(builtins.elem "nmtrust-offline.target" wantedBy);
    in
    assert stopWhenUnneeded;
    assert hasTrusted;
    assert noOffline;
    pkgs.runCommand "eval-e9-no-offline" { } ''
      echo "PASS: allowOffline=false only binds to trusted target with StopWhenUnneeded"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E10: System targets have mutual Conflicts=
  # -----------------------------------------------------------------------
  eval-e10-system-target-conflicts =
    let
      targets = refConfig.systemd.targets;
      trusted = targets."nmtrust-trusted".unitConfig.Conflicts;
      untrusted = targets."nmtrust-untrusted".unitConfig.Conflicts;
      offline = targets."nmtrust-offline".unitConfig.Conflicts;

      # trusted conflicts with untrusted + offline
      trustedOk =
        builtins.elem "nmtrust-untrusted.target" trusted && builtins.elem "nmtrust-offline.target" trusted;
      # untrusted conflicts with trusted + offline
      untrustedOk =
        builtins.elem "nmtrust-trusted.target" untrusted
        && builtins.elem "nmtrust-offline.target" untrusted;
      # offline conflicts with trusted + untrusted
      offlineOk =
        builtins.elem "nmtrust-trusted.target" offline && builtins.elem "nmtrust-untrusted.target" offline;
    in
    assert trustedOk;
    assert untrustedOk;
    assert offlineOk;
    pkgs.runCommand "eval-e10-system-target-conflicts" { } ''
      echo "PASS: system targets have mutual Conflicts="
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E11: User targets have mutual Conflicts=
  # -----------------------------------------------------------------------
  eval-e11-user-target-conflicts =
    let
      targets = refConfig.systemd.user.targets;
      trusted = targets."nmtrust-trusted".unitConfig.Conflicts;
      untrusted = targets."nmtrust-untrusted".unitConfig.Conflicts;
      offline = targets."nmtrust-offline".unitConfig.Conflicts;

      trustedOk =
        builtins.elem "nmtrust-untrusted.target" trusted && builtins.elem "nmtrust-offline.target" trusted;
      untrustedOk =
        builtins.elem "nmtrust-trusted.target" untrusted
        && builtins.elem "nmtrust-offline.target" untrusted;
      offlineOk =
        builtins.elem "nmtrust-trusted.target" offline && builtins.elem "nmtrust-untrusted.target" offline;
    in
    assert trustedOk;
    assert untrustedOk;
    assert offlineOk;
    pkgs.runCommand "eval-e11-user-target-conflicts" { } ''
      echo "PASS: user targets have mutual Conflicts="
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E12: tmpfiles rule exact match
  # -----------------------------------------------------------------------
  eval-e12-tmpfiles-rule =
    let
      rules = refConfig.systemd.tmpfiles.rules;
      hasRule = builtins.elem "d /run/nmtrust 0700 root root -" rules;
    in
    assert hasRule;
    pkgs.runCommand "eval-e12-tmpfiles-rule" { } ''
      echo "PASS: tmpfiles rule matches exactly"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E13: Dispatcher contains systemd-run --on-active (not direct call)
  # -----------------------------------------------------------------------
  eval-e13-dispatcher-debounce =
    let
      dispatchers = refConfig.networking.networkmanager.dispatcherScripts;
      scriptPath = (builtins.head dispatchers).source;
    in
    pkgs.runCommand "eval-e13-dispatcher-debounce"
      {
        script = scriptPath;
      }
      ''
        # Check for debounce pattern: systemd-run --on-active
        if ! grep -q "systemd-run" "$script" || ! grep -q "\-\-on-active" "$script"; then
          echo "FAIL: dispatcher does not use systemd-run --on-active"
          exit 1
        fi
        # Verify it does NOT call nmtrust directly (it goes through systemctl)
        if grep -q "bin/nmtrust" "$script"; then
          echo "FAIL: dispatcher calls nmtrust binary directly instead of via systemctl"
          exit 1
        fi
        echo "PASS: dispatcher uses systemd-run --on-active debounce"
        touch $out
      '';

  # -----------------------------------------------------------------------
  # E14: Generated /etc/nmtrust/config contains trusted UUIDs
  # -----------------------------------------------------------------------
  eval-e14-helper-uuids =
    let
      cfg = evalConfig [
        baseModule
        sampleProfileModule
        (
          { config, ... }:
          {
            services.nmtrust = {
              enable = true;
              trustedConnections = [ "home-wifi" ];
              trustedUUIDsExtra = [ "deadbeef-1234-5678-9abc-def012345678" ];
            };
          }
        )
      ];
      configText = cfg.environment.etc."nmtrust/config".text;
    in
    pkgs.runCommand "eval-e14-helper-uuids"
      {
        config = configText;
      }
      ''
        if ! echo "$config" | grep -q "a1b2c3d4-e5f6-7890-abcd-ef1234567890"; then
          echo "FAIL: profile UUID not found in /etc/nmtrust/config"
          exit 1
        fi
        if ! echo "$config" | grep -q "deadbeef-1234-5678-9abc-def012345678"; then
          echo "FAIL: extra UUID not found in /etc/nmtrust/config"
          exit 1
        fi
        echo "PASS: /etc/nmtrust/config contains trusted UUIDs"
        touch $out
      '';

  # -----------------------------------------------------------------------
  # E15: enable=false produces nothing
  # -----------------------------------------------------------------------
  eval-e15-disabled =
    let
      # With enable=false, none of the trust-related config should be set
      hasNoTargets =
        !(disabledConfig.systemd.targets ? "nmtrust-trusted")
        && !(disabledConfig.systemd.targets ? "nmtrust-untrusted")
        && !(disabledConfig.systemd.targets ? "nmtrust-offline");
      hasNoUserTargets =
        !(disabledConfig.systemd.user.targets ? "nmtrust-trusted")
        && !(disabledConfig.systemd.user.targets ? "nmtrust-untrusted")
        && !(disabledConfig.systemd.user.targets ? "nmtrust-offline");
      hasNoDispatcher = disabledConfig.networking.networkmanager.dispatcherScripts == [ ];
      hasNoApplyService = !(disabledConfig.systemd.services ? "nmtrust-apply");
      hasNoEvalService = !(disabledConfig.systemd.services ? "nmtrust-eval");
      hasNoTmpfiles =
        !(builtins.elem "d /run/nmtrust 0700 root root -" disabledConfig.systemd.tmpfiles.rules);
      hasNoEtcConfig = !(disabledConfig.environment.etc ? "nmtrust/config");
    in
    assert hasNoTargets;
    assert hasNoUserTargets;
    assert hasNoDispatcher;
    assert hasNoApplyService;
    assert hasNoEvalService;
    assert hasNoTmpfiles;
    assert hasNoEtcConfig;
    pkgs.runCommand "eval-e15-disabled" { } ''
      echo "PASS: enable=false produces no trust-related config"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E16: enable=true without NetworkManager -> assertion failure
  # -----------------------------------------------------------------------
  eval-e16-no-networkmanager =
    let
      baseNoNM =
        { config, pkgs, ... }:
        {
          boot.loader.grub.device = "nodev";
          fileSystems."/" = {
            device = "/dev/sda1";
            fsType = "ext4";
          };
          system.stateVersion = "25.11";
          # NetworkManager deliberately NOT enabled
        };
      passes =
        let
          cfg = evalConfig [
            baseNoNM
            (
              { config, ... }:
              {
                services.nmtrust.enable = true;
              }
            )
          ];
        in
        builtins.all (a: a.assertion) cfg.assertions;
    in
    assert !passes;
    pkgs.runCommand "eval-e16-no-networkmanager" { } ''
      echo "PASS: assertion fires when NetworkManager is not enabled"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E17: Config file contains all settings with correct values
  # -----------------------------------------------------------------------
  eval-e17-config-completeness =
    let
      cfg = evalConfig [
        baseModule
        sampleProfileModule
        (
          { config, ... }:
          {
            users.users.testuser = {
              isNormalUser = true;
              linger = true;
            };
            services.nmtrust = {
              enable = true;
              trustedConnections = [ "home-wifi" ];
              trustedUUIDsExtra = [ "deadbeef-1234-5678-9abc-def012345678" ];
              excludedConnectionPatterns = [
                "docker*"
                "virbr*"
              ];
              mixedPolicy = "trusted";
              evalFailurePolicy = "offline";
              userUnits.testuser."foo.service" = { };
            };
          }
        )
      ];
      configText = cfg.environment.etc."nmtrust/config".text;
    in
    pkgs.runCommand "eval-e17-config-completeness"
      {
        config = configText;
      }
      ''
        # Verify all 5 settings are present
        echo "$config" | grep -q 'TRUSTED_UUIDS=' || { echo "FAIL: missing TRUSTED_UUIDS"; exit 1; }
        echo "$config" | grep -q 'EXCLUDED_PATTERNS=' || { echo "FAIL: missing EXCLUDED_PATTERNS"; exit 1; }
        echo "$config" | grep -q 'MIXED_POLICY=' || { echo "FAIL: missing MIXED_POLICY"; exit 1; }
        echo "$config" | grep -q 'EVAL_FAILURE_POLICY=' || { echo "FAIL: missing EVAL_FAILURE_POLICY"; exit 1; }
        echo "$config" | grep -q 'MANAGED_USERS=' || { echo "FAIL: missing MANAGED_USERS"; exit 1; }

        # Verify specific values
        echo "$config" | grep -q 'a1b2c3d4-e5f6-7890-abcd-ef1234567890' || { echo "FAIL: profile UUID missing"; exit 1; }
        echo "$config" | grep -q 'deadbeef-1234-5678-9abc-def012345678' || { echo "FAIL: extra UUID missing"; exit 1; }
        echo "$config" | grep -q 'docker\*' || { echo "FAIL: excluded pattern 'docker*' missing"; exit 1; }
        echo "$config" | grep -q 'virbr\*' || { echo "FAIL: excluded pattern 'virbr*' missing"; exit 1; }
        echo "$config" | grep -q 'MIXED_POLICY=.*trusted' || { echo "FAIL: mixedPolicy value missing"; exit 1; }
        echo "$config" | grep -q 'EVAL_FAILURE_POLICY=.*offline' || { echo "FAIL: evalFailurePolicy value missing"; exit 1; }
        echo "$config" | grep -q 'testuser' || { echo "FAIL: managed user missing"; exit 1; }

        # Verify it's valid bash (can be sourced without error)
        bash -n <(echo "$config") || { echo "FAIL: config is not valid bash"; exit 1; }

        echo "PASS: config file contains all settings with correct values and valid bash syntax"
        touch $out
      '';

  # -----------------------------------------------------------------------
  # E18: systemd hardening directives present on services
  # -----------------------------------------------------------------------
  eval-e18-service-hardening =
    let
      applySvc = refConfig.systemd.services."nmtrust-apply".serviceConfig;
      evalSvc = refConfig.systemd.services."nmtrust-eval".serviceConfig;
    in
    assert applySvc.ProtectSystem == "strict";
    assert applySvc.ProtectHome == true;
    assert applySvc.NoNewPrivileges == true;
    assert applySvc.PrivateTmp == true;
    assert builtins.elem "/run/nmtrust" applySvc.ReadWritePaths;
    assert applySvc.Restart == "on-failure";
    assert evalSvc.ProtectSystem == "strict";
    assert evalSvc.ProtectHome == true;
    assert evalSvc.NoNewPrivileges == true;
    assert evalSvc.PrivateTmp == true;
    assert builtins.elem "/run/nmtrust" evalSvc.ReadWritePaths;
    assert evalSvc.Restart == "on-failure";
    pkgs.runCommand "eval-e18-service-hardening" { } ''
      echo "PASS: systemd hardening directives and retry policy present on both services"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E19: nmtrust-eval has restartTriggers linked to config
  # -----------------------------------------------------------------------
  eval-e19-restart-triggers =
    let
      evalSvc = refConfig.systemd.services."nmtrust-eval";
      hasRestartTriggers = evalSvc.restartTriggers != [ ];
    in
    assert hasRestartTriggers;
    pkgs.runCommand "eval-e19-restart-triggers" { } ''
      echo "PASS: nmtrust-eval has restartTriggers for config changes"
      touch $out
    '';

  # -----------------------------------------------------------------------
  # E20: same unit under multiple users with differing allowOffline -> wantedBy unioned
  # -----------------------------------------------------------------------
  eval-e20-userunit-shared =
    let
      cfg = evalConfig [
        baseModule
        sampleProfileModule
        (
          { config, ... }:
          {
            users.users.alice = { isNormalUser = true; linger = true; };
            users.users.bob = { isNormalUser = true; linger = true; };
            services.nmtrust = {
              enable = true;
              trustedConnections = [ "home-wifi" ];
              userUnits.alice."syncthing.service" = { allowOffline = false; };
              userUnits.bob."syncthing.service" = { allowOffline = true; };
            };
          }
        )
      ];
      svc = cfg.systemd.user.services."syncthing";
      wantedBy = svc.wantedBy;
      hasTrusted = builtins.elem "nmtrust-trusted.target" wantedBy;
      hasOffline = builtins.elem "nmtrust-offline.target" wantedBy;
    in
    assert hasTrusted;
    assert hasOffline;
    pkgs.runCommand "eval-e20-userunit-shared" { } ''
      echo "PASS: shared unit wantedBy is the union of all users' declarations"
      touch $out
    '';
}
