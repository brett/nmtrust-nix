{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nmtrust;

  # Resolve trusted UUIDs from ensureProfiles + extra
  profileUUIDs = map (
    name: config.networking.networkmanager.ensureProfiles.profiles.${name}.connection.uuid
  ) cfg.trustedConnections;

  trustedUUIDs = profileUUIDs ++ cfg.trustedUUIDsExtra;

  userNames = builtins.attrNames cfg.userUnits;

  # Unit names across all users, deduplicated: systemd.user.services is
  # system-wide, so the same unit named by two users is one unit.
  sharedUserUnitNames = lib.unique (
    lib.concatMap (username: builtins.attrNames cfg.userUnits.${username}) userNames
  );

  # Build the helper package (reads config from /etc/nmtrust/config at runtime)
  trustHelper = pkgs.callPackage ./package.nix { };

  # Trust states, and the target names derived from them
  trustStates = [
    "trusted"
    "untrusted"
    "offline"
  ];

  trustTargets = map (state: "nmtrust-${state}") trustStates;

  # Fully-qualified target unit names, used to tell nmtrust's own
  # dependencies apart from foreign ones in assertions.
  trustTargetUnits = map (t: "${t}.target") trustTargets;

  # Generate Conflicts= for a target (all other trust targets)
  conflictsFor = target: map (t: "${t}.target") (builtins.filter (t: t != target) trustTargets);

  # NixOS appends the .service/.timer/.socket suffix itself, so unit
  # names given in systemUnits/userUnits are stripped before use as
  # systemd.services attribute names.
  stripUnitSuffix =
    name: lib.removeSuffix ".service" (lib.removeSuffix ".timer" (lib.removeSuffix ".socket" name));

  # States a unit entry resolves to; allowOffline is sugar for adding
  # "offline" to states.
  unitStates = unitCfg: lib.unique (unitCfg.states ++ lib.optional unitCfg.allowOffline "offline");

  # Uses StopWhenUnneeded instead of PartOf to avoid same-transaction
  # issues: when transitioning between targets that both want a unit
  # (e.g. offline -> trusted for allowOffline units), PartOf on the
  # old target would stop the unit before WantedBy on the new target
  # can restart it. StopWhenUnneeded only stops the unit when NO
  # active target wants it.
  #
  # wantedBy is mkForce'd for two reasons. Most units worth binding are
  # already `wantedBy = [ "multi-user.target" ]` in the module that
  # defines them; left in place, that keeps the unit "needed" in every
  # trust state and silently reduces the binding to a no-op. Forcing it
  # also means a user's own `wantedBy = lib.mkForce [ ]` merges with this
  # definition at equal priority (list definitions at the winning
  # priority are concatenated) instead of clobbering the trust binding.
  mkUnitOverrides = states: {
    unitConfig.StopWhenUnneeded = true;
    wantedBy = lib.mkForce (map (state: "nmtrust-${state}.target") states);
  };

  # Options shared by systemUnits and userUnits entries.
  unitSubmodule = lib.types.submodule {
    options = {
      states = lib.mkOption {
        type = lib.types.nonEmptyListOf (lib.types.enum trustStates);
        default = [ "trusted" ];
        example = [ "untrusted" ];
        description = ''
          Trust states in which this unit should run. The unit is bound to
          the corresponding `nmtrust-<state>.target`s and stops in every
          state not listed.

          The default `[ "trusted" ]` runs the unit only on trusted
          networks. Use `[ "untrusted" ]` for the inverse case — a unit
          that should run only on networks you do not control, such as a
          VPN or Tailscale bring-up unit. Listing all three states means
          the unit always runs, which makes the binding pointless.
        '';
      };

      allowOffline = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether this unit should also run when offline. Shorthand for
          adding `"offline"` to {option}`states`; the two are unioned.
        '';
      };
    };
  };

  # StopWhenUnneeded= only stops a unit when nothing *active* needs it.
  # Foreign wantedBy is handled by mkForce above, but requiredBy and
  # upheldBy are contributed to other units' Requires=/Upholds= and
  # cannot be overridden from here — they keep the unit running in every
  # trust state and silently reduce the binding to a no-op. Catch them at
  # eval time rather than letting the binding quietly do nothing.
  foreignDeps = unit: lib.subtractLists trustTargetUnits (unit.requiredBy ++ unit.upheldBy);

  mkForeignDepAssertion =
    {
      unit,
      optionPath,
      attrPath,
    }:
    let
      foreign = foreignDeps unit;
    in
    {
      assertion = foreign == [ ];
      message =
        "${optionPath} is also pulled in by ${lib.concatStringsSep ", " foreign} "
        + "via requiredBy/upheldBy. nmtrust stops units with StopWhenUnneeded=, which "
        + "only takes effect when nothing active needs the unit, so it would stay "
        + "running in every trust state and the trust binding would have no effect. "
        + "Clear the other dependency, e.g. ${attrPath}.requiredBy = lib.mkForce [ ]; "
        + "(nmtrust force-overrides wantedBy itself, so plain WantedBy= dependencies "
        + "from other modules need no action).";
    };

  # NM dispatcher script
  dispatcherScript = pkgs.writeShellScript "nmtrust-dispatcher" ''
    case "$2" in
      up|down|vpn-up|vpn-down|connectivity-change)
        ${config.systemd.package}/bin/systemd-run \
          --no-block \
          --on-active=1s \
          --unit=nmtrust-apply-debounce \
          ${config.systemd.package}/bin/systemctl start nmtrust-apply.service \
          2>/dev/null || true
        ;;
    esac
  '';

in
{

  #
  # Options
  #

  options.services.nmtrust = {

    enable = lib.mkEnableOption "network trust management";

    trustedConnections = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        List of NetworkManager profile names from
        networking.networkmanager.ensureProfiles.
        UUIDs are resolved at evaluation time.
      '';
    };

    trustedUUIDsExtra = lib.mkOption {
      type = lib.types.listOf (
        lib.types.strMatching "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
      );
      default = [ ];
      description = ''
        Additional trusted connection UUIDs not managed via
        networking.networkmanager.ensureProfiles.
        Must be valid UUID format.
      '';
    };

    excludedConnectionPatterns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Glob patterns matched against connection names at runtime using
        fnmatch(3) with FNM_NOESCAPE. Connection names are treated as
        literal strings (no backslash interpretation).
        Matching connections are ignored when computing trust state.
      '';
    };

    mixedPolicy = lib.mkOption {
      type = lib.types.enum [
        "trusted"
        "untrusted"
      ];
      default = "untrusted";
      description = ''
        How to treat mixed trust state (some connections trusted,
        some untrusted).
      '';
    };

    evalFailurePolicy = lib.mkOption {
      type = lib.types.enum [
        "untrusted"
        "offline"
      ];
      default = "untrusted";
      description = ''
        How to handle trust evaluation failures (D-Bus errors, NM
        unavailable). "untrusted" (default) is fail-closed: trusted-only
        units stop. "offline" allows units with allowOffline to run.
      '';
    };

    systemUnits = lib.mkOption {
      type = lib.types.attrsOf unitSubmodule;
      default = { };
      example = lib.literalExpression ''
        {
          "my-sync.service" = { };
          "backup.service" = { allowOffline = true; };
          "tailscale-up.service" = { states = [ "untrusted" ]; };
        }
      '';
      description = ''
        System units to bind to the trust targets. Keys are systemd unit
        names; each entry selects the trust states the unit runs in via
        {option}`states` (default `[ "trusted" ]`).
      '';
    };

    userUnits = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf unitSubmodule);
      default = { };
      example = lib.literalExpression ''
        {
          alice = {
            "etesync-dav.service" = { };
            "syncthing.service" = { allowOffline = true; };
            "personal-vpn.service" = { states = [ "untrusted" ]; };
          };
        }
      '';
      description = ''
        Per-user units to bind to the trust targets.
        Outer keys are usernames, inner keys are systemd unit names.
        Users must have linger enabled (users.users.<name>.linger = true).
      '';
    };
  };

  #
  # Config
  #

  config = lib.mkIf cfg.enable {

    # --- Assertions ---

    assertions =
      # NetworkManager is required
      [
        {
          assertion = config.networking.networkmanager.enable;
          message = "services.nmtrust requires networking.networkmanager.enable = true.";
        }
      ]
      ++
        # trustedConnections -> ensureProfiles UUID resolution
        (map (name: {
          assertion =
            config.networking.networkmanager.ensureProfiles.profiles ? ${name}
            && config.networking.networkmanager.ensureProfiles.profiles.${name}.connection ? uuid;
          message =
            "services.nmtrust.trustedConnections references '${name}' "
            + "but no matching networking.networkmanager.ensureProfiles entry with a UUID exists.";
        }) cfg.trustedConnections)
      ++
        # userUnits -> user existence
        (map (username: {
          assertion = config.users.users ? ${username};
          message =
            "services.nmtrust.userUnits references user '${username}' "
            + "but no matching users.users entry exists.";
        }) userNames)
      ++
        # userUnits -> linger enabled
        (map (username: {
          assertion =
            let
              l = config.users.users.${username}.linger;
            in
            l != null && l;
          message =
            "services.nmtrust.userUnits references user '${username}' but "
            + "linger is not enabled. Set users.users.${username}.linger = true to "
            + "ensure the user's systemd instance is running for trust-based unit management. "
            + "Note: enabling linger causes ALL of this user's enabled user services to run "
            + "persistently, not just trust-managed units.";
        }) (builtins.filter (u: config.users.users ? ${u}) userNames))
      ++
        # systemUnits -> no foreign dependency defeating StopWhenUnneeded
        (lib.mapAttrsToList (
          unitName: _:
          let
            stripped = stripUnitSuffix unitName;
          in
          mkForeignDepAssertion {
            unit = config.systemd.services.${stripped};
            optionPath = "services.nmtrust.systemUnits.\"${unitName}\"";
            attrPath = "systemd.services.${stripped}";
          }
        ) cfg.systemUnits)
      ++
        # userUnits -> same check, deduplicated across users
        (map (
          unitName:
          let
            stripped = stripUnitSuffix unitName;
          in
          mkForeignDepAssertion {
            unit = config.systemd.user.services.${stripped};
            optionPath = "services.nmtrust.userUnits.*.\"${unitName}\"";
            attrPath = "systemd.user.services.${stripped}";
          }
        ) sharedUserUnitNames);

    # --- Helper package on PATH ---

    environment.systemPackages = [ trustHelper ];

    # --- Runtime config file ---

    environment.etc."nmtrust/config" = {
      text =
        let
          toBashArray = xs: "(" + lib.concatMapStringsSep " " (x: lib.escapeShellArg x) xs + ")";
        in
        ''
          # Generated by NixOS module — do not edit
          TRUSTED_UUIDS=${toBashArray trustedUUIDs}
          EXCLUDED_PATTERNS=${toBashArray (cfg.excludedConnectionPatterns)}
          MIXED_POLICY=${lib.escapeShellArg cfg.mixedPolicy}
          EVAL_FAILURE_POLICY=${lib.escapeShellArg cfg.evalFailurePolicy}
          MANAGED_USERS=${toBashArray userNames}
        '';
    };

    # --- tmpfiles.d ---

    systemd.tmpfiles.rules = [
      "d /run/nmtrust 0700 root root -"
    ];

    # --- System trust targets ---

    systemd.targets = lib.listToAttrs (
      map (target: {
        name = target;
        value = {
          description = "Network Trust State: ${
            if target == "nmtrust-trusted" then
              "Trusted"
            else if target == "nmtrust-untrusted" then
              "Untrusted"
            else
              "Offline"
          }";
          unitConfig.Conflicts = conflictsFor target;
        };
      }) trustTargets
    );

    # --- User trust targets ---

    systemd.user.targets = lib.listToAttrs (
      map (target: {
        name = target;
        value = {
          description = "Network Trust State: ${
            if target == "nmtrust-trusted" then
              "Trusted (User)"
            else if target == "nmtrust-untrusted" then
              "Untrusted (User)"
            else
              "Offline (User)"
          }";
          unitConfig.Conflicts = conflictsFor target;
        };
      }) trustTargets
    );

    # --- System unit overrides + services ---

    # Strip .service/.timer/.socket suffixes — NixOS appends them automatically
    systemd.services =
      lib.mapAttrs' (name: value: {
        name = stripUnitSuffix name;
        value = mkUnitOverrides (unitStates value);
      }) cfg.systemUnits
      // {
        nmtrust-apply = {
          description = "Evaluate and apply network trust state";
          after = [ "NetworkManager.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${trustHelper}/bin/nmtrust apply";
            Restart = "on-failure";
            RestartSec = "5";
            ProtectSystem = "strict";
            ReadWritePaths = [ "/run/nmtrust" ];
            ProtectHome = true;
            NoNewPrivileges = true;
            PrivateTmp = true;
          };
        };
        nmtrust-eval = {
          description = "Evaluate network trust state on boot";
          wantedBy = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          after = [
            "NetworkManager.service"
            "network-online.target"
          ];
          restartTriggers = [
            config.environment.etc."nmtrust/config".source
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${trustHelper}/bin/nmtrust apply";
            Restart = "on-failure";
            RestartSec = "5";
            ProtectSystem = "strict";
            ReadWritePaths = [ "/run/nmtrust" ];
            ProtectHome = true;
            NoNewPrivileges = true;
            PrivateTmp = true;
          };
        };
      };

    # --- User unit overrides ---

    # systemd.user.services is system-wide, so the same unit named by two
    # users is one unit. Union the states each user asked for before
    # building the overrides — the unit runs in any state some user wants.
    systemd.user.services =
      let
        statesByUnit = lib.foldl' (
          acc: username:
          lib.foldl' (
            acc': unitName:
            let
              strippedName = stripUnitSuffix unitName;
              incoming = unitStates cfg.userUnits.${username}.${unitName};
            in
            acc'
            // {
              ${strippedName} = lib.unique ((acc'.${strippedName} or [ ]) ++ incoming);
            }
          ) acc (builtins.attrNames cfg.userUnits.${username})
        ) { } userNames;
      in
      lib.mapAttrs (_: states: mkUnitOverrides states) statesByUnit;

    # --- NM dispatcher ---

    networking.networkmanager.dispatcherScripts = [
      {
        source = dispatcherScript;
        type = "basic";
      }
    ];
  };
}
