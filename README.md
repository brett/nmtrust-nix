# nmtrust-nix

Declarative network trust management for NixOS. Automatically start and stop
systemd services based on whether your active network connections are trusted,
untrusted, or offline.

A NixOS-native replacement for
[nmtrust](https://github.com/pigmonkey/nmtrust) by
[Peter Hogg](https://github.com/pigmonkey), built on systemd targets and the
NetworkManager D-Bus API rather than mutable state files and shell scripts.

## How it works

When a NetworkManager event fires (connect, disconnect, VPN up/down), the
module evaluates the trust state of your active connections:

| State | Meaning |
|---|---|
| **trusted** | All active connections have trusted UUIDs |
| **untrusted** | No active connections are trusted |
| **mixed** | Some trusted, some not (resolved via `mixedPolicy`) |
| **offline** | No active connections |

The evaluated state activates a corresponding systemd target:

- `nmtrust-trusted.target`
- `nmtrust-untrusted.target`
- `nmtrust-offline.target`

Services you configure are bound to these targets via `WantedBy=` and
`StopWhenUnneeded=`.
When the active target changes, systemd starts and stops the bound services
automatically. The targets are mutually exclusive (`Conflicts=`), so activating
one atomically deactivates the others.

```
NM event → dispatcher → debounce (1s) → nmtrust-apply.service
                                              │
                                              ├─ read override file
                                              ├─ query NM D-Bus API
                                              ├─ filter excluded connections
                                              ├─ compare UUIDs against trusted set
                                              ├─ resolve mixed/error policy
                                              ├─ log structured transition
                                              └─ systemctl start nmtrust-{state}.target
                                                    │
                                                    └─ systemd starts/stops bound units
```

## Installation

The module and package are available in nixpkgs. No extra inputs needed.

See [docs/quickstart.md](docs/quickstart.md) for a step-by-step setup guide.

## Configuration

### Minimal example

```nix
networking.networkmanager.ensureProfiles.profiles.home-wifi = {
  connection = {
    id = "home-wifi";
    uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";
    type = "wifi";
  };
  wifi.ssid = "MyHomeNetwork";
  ipv4.method = "auto";
};

services.nmtrust = {
  enable = true;
  trustedConnections = [ "home-wifi" ];
  excludedConnectionPatterns = [ "virbr*" "docker*" "veth*" "br-*" ];
  systemUnits = {
    "mailsync.timer" = {};
  };
};
```

### Full example

```nix
services.nmtrust = {
  enable = true;

  # Profile names from ensureProfiles — UUIDs resolved at eval time
  trustedConnections = [
    "home-wifi"
    "phone-hotspot"
    "office-ethernet"
  ];

  # UUIDs for connections not managed via ensureProfiles
  trustedUUIDsExtra = [
    "12345678-abcd-efab-cdef-123456789abc"
  ];

  # Glob patterns — matched connections are ignored in trust computation
  excludedConnectionPatterns = [
    "virbr*"
    "docker*"
    "veth*"
    "br-*"
    "tailscale*"
  ];

  # How to handle mixed state (some trusted, some not)
  # "untrusted" (default) or "trusted"
  mixedPolicy = "untrusted";

  # How to handle evaluation failures (NM down, D-Bus error)
  # "untrusted" (default, fail-closed) or "offline"
  evalFailurePolicy = "untrusted";

  # System units bound to the trusted target
  systemUnits = {
    "mailsync.timer" = {};                                    # trusted only
    "restic-backup.service" = { allowOffline = true; };         # trusted + offline
  };

  # Per-user units (requires linger)
  userUnits.brett = {
    "ssh-tunnel.service" = {};                                # trusted only
    "git-annex.service" = { allowOffline = true; };           # trusted + offline
  };
};

# Required for userUnits — explicitly opted in due to side effects
users.users.brett.linger = true;
```

### Option reference

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable network trust management |
| `trustedConnections` | list of str | `[]` | NM profile names from `ensureProfiles`. UUIDs resolved at eval time. |
| `trustedUUIDsExtra` | list of UUID str | `[]` | Additional trusted UUIDs (format-validated). |
| `excludedConnectionPatterns` | list of str | `[]` | Glob patterns for connections to ignore. Matched via `fnmatch(3)` with `FNM_NOESCAPE`. |
| `mixedPolicy` | `"trusted"` or `"untrusted"` | `"untrusted"` | How to resolve mixed trust state. |
| `evalFailurePolicy` | `"untrusted"` or `"offline"` | `"untrusted"` | How to resolve evaluation failures. |
| `systemUnits` | attrs of submodule | `{}` | System units to bind to the trusted target. Keys are unit names. |
| `systemUnits.<name>.allowOffline` | bool | `false` | Also bind to the offline target. |
| `userUnits` | attrs of attrs of submodule | `{}` | Per-user units. Outer key = username, inner key = unit name. |
| `userUnits.<user>.<name>.allowOffline` | bool | `false` | Also bind to the offline target. |

### Build-time assertions

The module validates your config at `nixos-rebuild` time:

- `networking.networkmanager.enable` must be `true`
- Each `trustedConnections` entry must have a matching `ensureProfiles` profile
  with a `uuid` field
- Each `trustedUUIDsExtra` entry must be a valid UUID format
- Each user in `userUnits` must exist in `users.users`
- Each user in `userUnits` must have `linger = true` (the error message explains
  why and what side effects to expect)

If any assertion fails, the build stops with a clear, specific error message.

## CLI

All commands require root.

### `nmtrust state`

Print the current trust state, active connections with their classification,
override status, and which target is active.

```
$ sudo nmtrust state
State: trusted
Override: none
Active target: nmtrust-trusted.target
Connections:
  home-wifi (a1b2c3d4-e5f6-7890-abcd-ef1234567890) [trusted]
  docker0 (99999999-8888-7777-6666-555555555555) [excluded]
```

### `nmtrust status`

Show the active trust target and all units bound to each target with their
current state.

```
$ sudo nmtrust status
Active target: nmtrust-trusted.target

=== nmtrust-trusted.target ===
  mailsync.timer (active)
  restic-backup.service (active)

=== nmtrust-untrusted.target ===
  mailsync.timer (inactive)

=== nmtrust-offline.target ===
  restic-backup.service (inactive)
```

### `nmtrust apply`

Re-evaluate trust state and activate the appropriate target. This is what the
NM dispatcher and boot service call. Normally you don't need to run this
manually.

```
$ sudo nmtrust apply
```

### `nmtrust override`

Manage ephemeral trust state overrides.

```bash
# Force trusted state regardless of actual connections
sudo nmtrust override trusted

# Force untrusted state
sudo nmtrust override untrusted

# Remove override, return to automatic evaluation
sudo nmtrust override clear
```

Overrides are stored in `/run/nmtrust/override` (tmpfs). They survive NM
events and manual apply runs, but are cleared on reboot. They are not part of
the declarative config.

## Architecture

### Components

| Component | Purpose |
|---|---|
| **NixOS module** (`module.nix`) | Defines options, generates systemd targets with `Conflicts=`, unit overrides, dispatcher script, services, tmpfiles rules, and build-time assertions |
| **Helper package** (`package.nix`) | `nmtrust` CLI. Queries NM via D-Bus, evaluates trust, manages state/override files, activates targets, logs transitions. Reads trust policy from `/etc/nmtrust/config` at runtime. |
| **Config file** (`/etc/nmtrust/config`) | Generated by the NixOS module via `environment.etc`. Contains bash variable assignments for trusted UUIDs, excluded patterns, and policies. Symlink to the Nix store (immutable). |
| **NM dispatcher** | Thin trigger script. Fires `systemd-run --on-active=1s` to debounce and coalesce rapid events into a single evaluation. |
| **Apply service** | `nmtrust-apply.service` (Type=oneshot). Runs `nmtrust apply`. systemd serializes concurrent invocations. |
| **Boot service** | `nmtrust-eval.service`. Runs after `NetworkManager.service` on boot to evaluate trust state without waiting for an NM event. |

### Target lifecycle

Trust targets use mutual `Conflicts=` directives. Activating one atomically
deactivates the others — there is no window where zero targets are active.

Services are bound to targets via:

- `WantedBy=` — systemd starts the service when the target activates
- `StopWhenUnneeded=` — systemd stops the service when no active target wants it

A service with `allowOffline = true` is bound to both
`nmtrust-trusted.target` and `nmtrust-offline.target`. It runs on
trusted networks and when offline, but stops on untrusted networks.

### Debouncing and serialization

NetworkManager can fire multiple dispatcher events in rapid succession (wifi
scanning, captive portal probes, VPN flapping). The dispatcher does not call
`nmtrust apply` directly. Instead:

1. Dispatcher fires `systemd-run --on-active=1s` to schedule a delayed start
2. Rapid events within the 1-second window are coalesced
3. `nmtrust-apply.service` is a oneshot — systemd ensures only one
   instance runs at a time

### State deduplication

The apply logic reads the previous state from `/run/nmtrust/state`. If
the computed state matches, it exits without logging or changing targets. This
prevents redundant systemd operations and journal noise.

### Connection data retrieval

The helper queries the NetworkManager D-Bus API via `busctl` rather than
parsing `nmcli -t` text output. NetworkManager connection names are
user-controlled strings that can contain delimiters; the D-Bus API returns
structured data, eliminating injection risks.

## Security

### Threat model

1. **Local privilege escalation via trust manipulation** — an unprivileged user
   forces trusted state to start services that expose attack surface
2. **Trust state confusion via crafted connection names** — NM connection names
   could manipulate evaluation
3. **Race conditions during state transitions** — concurrent events produce
   inconsistent target state

### Mitigations

| Threat | Mitigation |
|---|---|
| Trust manipulation | `/run/nmtrust/` is `0700 root:root`. Override file is `0600`. All CLI commands require root. |
| Connection name injection | D-Bus API returns structured data (no text parsing). Connection names are only used for exclusion filtering via `fnmatch`, never for trust decisions. Trust is UUID-based. |
| Race conditions | All evaluation runs inside a serialized oneshot service. Dispatcher debounces with 1s delay. Targets use `Conflicts=` for atomic transitions. |
| Linger side effects | Module asserts linger is explicitly enabled (not silently forced). Error message explains that linger causes all user services to become persistent. |
| Evaluation failure | Distinct `error` state with configurable policy. Default is `"untrusted"` (fail-closed). |
| D-Bus parsing | UUIDs parsed from `busctl` output are validated against UUID regex. Malformed responses trigger the eval failure path instead of silently producing wrong trust decisions. |
| Service hardening | `nmtrust-apply` and `nmtrust-eval` run with `ProtectSystem=strict`, `ProtectHome=true`, `NoNewPrivileges=true`, `PrivateTmp=true`. Filesystem access is limited to `/run/nmtrust`. |

### File permissions

| Path | Mode | Owner | Purpose |
|---|---|---|---|
| `/etc/nmtrust/config` | `0444` | `root:root` | Trust policy (store symlink, immutable) |
| `/run/nmtrust/` | `0700` | `root:root` | Runtime state directory (tmpfs) |
| `/run/nmtrust/state` | `0600` | `root:root` | Current trust state (for dedup) |
| `/run/nmtrust/override` | `0600` | `root:root` | Ephemeral override (when set) |

All file writes are atomic (write to temp file, `chmod`, `rename(2)`).

## Logging

All trust transitions and events are logged to the systemd journal in
structured `key=value` format:

```bash
# Watch trust transitions
journalctl -u nmtrust-apply.service -f

# Filter for transitions only
journalctl -u nmtrust-apply.service -g TRUST_TRANSITION

# Filter for evaluation failures
journalctl -u nmtrust-apply.service -g EVAL_FAILURE

# Filter for override events
journalctl -u nmtrust-apply.service -g OVERRIDE
```

### Log formats

**Trust transitions:**
```
nmtrust[1234]: TRUST_TRANSITION previous_state=trusted new_state=untrusted trigger=dispatcher event=down connections_active=1 connections_trusted=0 connections_excluded=0 override=none
```

**Override events:**
```
nmtrust[1234]: OVERRIDE_SET state=trusted user=root
nmtrust[1234]: OVERRIDE_CLEAR user=root
```

**Evaluation failures:**
```
nmtrust[1234]: EVAL_FAILURE reason="dbus_error: ..." policy=untrusted resolved_state=untrusted
```

### Transition log fields

| Field | Description |
|---|---|
| `previous_state` | State before this transition |
| `new_state` | State after this transition |
| `trigger` | What caused evaluation: `dispatcher`, `boot`, `override`, `manual` |
| `event` | NM event type (if dispatcher): `up`, `down`, `vpn-up`, `vpn-down`, `connectivity-change` |
| `connections_active` | Active non-excluded connections |
| `connections_trusted` | Connections with trusted UUIDs |
| `connections_excluded` | Connections filtered by exclusion patterns |
| `override` | `none`, `trusted`, or `untrusted` |

## Testing

The project has three test levels:

### Level 1: Nix evaluation tests

19 tests that validate module options, assertions, generated systemd
configuration, config file content, hardening directives, and restart
triggers. Pure Nix — no VM, no root, no network.

```bash
nix flake check
```

### Level 2: NixOS VM integration tests

27 tests across 12 `nixosTest` derivations. Boot QEMU VMs with dummy NM
interfaces and verify runtime behavior: state transitions, overrides,
debouncing, user units, eval failure, structured logging, security.

A separate nixpkgs-format test (`nixpkgs/tests/nmtrust.nix`) covers the
core state transitions in the format required for nixpkgs submission.

```bash
# Run all checks (includes both level 1 and 2)
nix flake check

# Run a specific VM test
nix build .#checks.x86_64-linux.vm-trust-states -L

# Run the nixpkgs-format test
nix build .#checks.x86_64-linux.nixpkgs-test-nmtrust -L
```

### Level 3: Migrant VM integration tests

39 end-to-end tests in a KVM VM with real NetworkManager, managed by
[migrant.sh](https://github.com/pigmonkey/migrant). Covers the full feature
set with real dispatcher events and D-Bus interactions.

```bash
cd tests/migrant
nix build .#nixos-image
migrant.sh destroy 2>/dev/null; migrant.sh up
bash test-nmtrust.sh
migrant.sh destroy
```

## Releasing

To publish a new version and update the nixpkgs package:

1. Tag the release: `git tag v0.2.0 && git push --tags`
2. In the nixpkgs tree, update `version` in `pkgs/by-name/nm/nmtrust/package.nix`
   (`rev` derives from it automatically via `v${version}`)
3. Clear the `hash` field and build — the error output shows the correct hash
4. Commit with the nixpkgs convention: `nmtrust: 0.1.0 -> 0.2.0`

## Compared to nmtrust

| | nmtrust | nmtrust-nix |
|---|---|---|
| Config | Mutable files in `/etc/nmtrust/` | Declarative Nix options |
| Unit control | Shell scripts calling `systemctl` per-unit | systemd targets + dependency graph |
| Connection data | `nmcli` text parsing | NM D-Bus API |
| State transitions | Script-driven (stop old, start new) | Atomic via `Conflicts=` |
| Concurrent events | Unprotected | Serialized oneshot + debounce |
| Overrides | Persistent files | Ephemeral (`/run/`, cleared on reboot) |
| Reproducibility | Drift between config and runtime | Identical across rebuilds |
| Validation | Runtime errors | Build-time assertions |

## Acknowledgments

This project is a NixOS-native reimplementation of
[nmtrust](https://github.com/pigmonkey/nmtrust), originally created by
[Peter Hogg (pigmonkey)](https://github.com/pigmonkey). The core trust model
-- trusted connections identified by UUID, excluded connection patterns,
`allowOffline` semantics, and the concept of dispatching on NetworkManager
events to control systemd units -- comes directly from his design.

## License

[Unlicense](UNLICENSE) (public domain)
