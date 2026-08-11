# Quickstart

Get network trust management running in under 5 minutes.

## Prerequisites

- NixOS 25.11+
- NetworkManager managing your connections
- Connection profiles configured via `ensureProfiles` with UUIDs

## 1. Define your trusted connections

Your NM profiles need to exist in `ensureProfiles` with explicit UUIDs. If you
don't already have them, generate a UUID with `uuidgen` and add the profile:

```nix
# configuration.nix
networking.networkmanager.ensureProfiles.profiles = {
  home-wifi = {
    connection = {
      id = "home-wifi";
      uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";  # uuidgen
      type = "wifi";
    };
    wifi.ssid = "MyHomeNetwork";
    wifi-security = {
      key-mgmt = "wpa-psk";
      psk = "your-password-here";  # or use a secrets manager
    };
    ipv4.method = "auto";
    ipv6.method = "auto";
  };
};
```

## 2. Enable the trust module

```nix
services.nmtrust = {
  enable = true;

  # Profile names from ensureProfiles — UUIDs are resolved automatically
  trustedConnections = [ "home-wifi" ];

  # Ignore virtual interfaces when computing trust state
  excludedConnectionPatterns = [
    "virbr*"
    "docker*"
    "veth*"
    "br-*"
    "tailscale*"
  ];

  # Services that should only run on trusted networks
  systemUnits = {
    "mailsync.timer" = {};
  };
};
```

## 3. Rebuild and verify

```bash
sudo nixos-rebuild switch

# Check the current trust state
nmtrust state

# See which target is active and what units are bound
nmtrust status
```

## 4. Test a transition

```bash
# Connect to your trusted network
nmcli connection up home-wifi

# Wait a few seconds for the debounced evaluation
sleep 3

# Verify
nmtrust state
# State: trusted
# Active target: nmtrust-trusted.target

sudo systemctl is-active mailsync.timer
# active

# Disconnect
nmcli connection down home-wifi
sleep 3

nmtrust state
# State: offline
# Active target: nmtrust-offline.target

sudo systemctl is-active mailsync.timer
# inactive
```

## Common tasks

### Allow a service to run offline

```nix
services.nmtrust.systemUnits = {
  "restic-backup.service" = { allowOffline = true; };
};
```

This binds the unit to both the trusted and offline targets. It stops only on
untrusted networks.

### Run a service only on untrusted networks

The inverse case — a VPN or a stricter resolver that should come up precisely
when you are on a network you do not control:

```nix
services.nmtrust.systemUnits = {
  "mullvad-connect.service" = { states = [ "untrusted" ]; };
};
```

If the unit is one another module already enables (most are, via
`wantedBy = [ "multi-user.target" ]`), nmtrust overrides that `WantedBy=` so the
unit can actually stop — replacing every other `wantedBy` it had. If a bound
unit still refuses to stop, some *other* unit is likely pulling it in with
`Wants=`/`Requires=`; check with `systemctl list-dependencies --reverse <unit>`.

Two rules apply to every VPN you manage this way:

1. **Bind a wrapper unit, not the daemon.** Stopping `mullvad-daemon` or
   `tailscaled` tears down far more than the tunnel. A `RemainAfterExit` oneshot
   that connects on start and disconnects on stop leaves the daemon alone.
2. **Exclude the VPN's own interface** from trust evaluation, or the tunnel it
   brings up feeds back into the state that started it. See
   [Avoiding feedback loops](#avoiding-feedback-loops).

### Example: Mullvad on untrusted networks

```nix
services.mullvad-vpn.enable = true;

systemd.services.mullvad-connect = {
  after = [ "mullvad-daemon.service" ];
  wants = [ "mullvad-daemon.service" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = "${pkgs.mullvad}/bin/mullvad connect --wait";
    ExecStop = "${pkgs.mullvad}/bin/mullvad disconnect --wait";
  };
};

services.nmtrust = {
  excludedConnectionPatterns = [ "wg-mullvad*" "tun*" ];
  systemUnits."mullvad-connect.service" = { states = [ "untrusted" ]; };
};
```

> **Mullvad's lockdown mode conflicts with this setup.**
> `mullvad lockdown-mode set on` requires a VPN connection in order to reach the
> internet, so it blocks ordinary internet access whenever the VPN is
> disconnected. Since nmtrust disconnects Mullvad on trusted networks, that is
> exactly when you would be left without it. Two categories are exempt and keep
> working: traffic from split-tunnelled applications, and local network traffic
> if `mullvad lan set allow` is on — so this is a loss of general internet
> access, not a total blackout. Either keep lockdown mode off, or leave Mullvad
> permanently connected and unmanaged by nmtrust; the two features solve the
> same problem in incompatible ways.

Mullvad's auto-connect setting (`mullvad auto-connect set on`) is likewise
redundant here and will fight the trust binding. Leave it off.

### Example: Tailscale

Tailscale is usually the wrong thing to bind. It is an overlay network you reach
*the machine* on, so stopping it on trusted networks means losing SSH and
MagicDNS to your own laptop from your own tailnet. Prefer leaving `tailscaled`
unmanaged and always on.

If you do want it trust-driven, bind a wrapper rather than the daemon:

```nix
systemd.services.tailscale-up = {
  after = [ "tailscaled.service" ];
  wants = [ "tailscaled.service" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = "${pkgs.tailscale}/bin/tailscale up";
    ExecStop = "${pkgs.tailscale}/bin/tailscale down";
  };
};

services.nmtrust = {
  excludedConnectionPatterns = [ "tailscale*" ];
  systemUnits."tailscale-up.service" = { states = [ "untrusted" ]; };
};
```

### Running Mullvad and Tailscale together

The recommended split is **Mullvad trust-driven, Tailscale always on**. They
have different jobs: Mullvad hides your traffic from the local network, while
Tailscale is how you reach the machine. Only the first is a function of trust.

```nix
services.mullvad-vpn.enable = true;
services.tailscale.enable = true;          # deliberately not in systemUnits

services.nmtrust = {
  excludedConnectionPatterns = [ "wg-mullvad*" "tun*" "tailscale*" ];
  systemUnits."mullvad-connect.service" = { states = [ "untrusted" ]; };
};
```

Three interactions to be aware of:

- **Allow LAN.** Set `mullvad lan set allow`. With LAN sharing blocked, Mullvad
  also blocks the local subnet, which breaks Tailscale's direct peer discovery
  and any local services.
- **Expect degraded Tailscale connectivity.** Tailscale documents that running
  alongside another VPN often needs workarounds, because of firewall rules,
  address conflicts, or platform limits. Here the likely outcome is that direct
  peer-to-peer connections fail and Tailscale falls back to DERP relays — it
  keeps working, but slower. Verify rather than assume: check `tailscale status`
  for `relay` vs `direct`, and `tailscale ping <peer>`. `mullvad split-tunnel
  add <PID>` can exclude `tailscaled` from the tunnel, but it is keyed on PID
  and lost whenever `tailscaled` restarts, so it is not worth wiring into a
  unit.
- **One default route at a time.** Do not use a Tailscale exit node while
  Mullvad is connected — both want the default route and the result depends on
  ordering. Tailscale's built-in Mullvad exit nodes are the supported way to get
  both, and need neither this setup nor the Mullvad client.

If you nonetheless want both trust-driven, bind both and order them so the
tunnels come up deterministically. Use `after` only — a `wants` or `requires`
between them would make one unit "needed" by the other and prevent
`StopWhenUnneeded=` from stopping it:

```nix
systemd.services.tailscale-up.after = [ "mullvad-connect.service" ];

services.nmtrust.systemUnits = {
  "mullvad-connect.service" = { states = [ "untrusted" ]; };
  "tailscale-up.service" = { states = [ "untrusted" ]; };
};
```

### Avoiding feedback loops

A VPN that nmtrust starts creates a new interface. If NetworkManager manages it,
it becomes an active connection and re-enters trust evaluation — the tunnel
feeds back into the state that started it. Always exclude it:

```nix
services.nmtrust.excludedConnectionPatterns = [ "wg-mullvad*" "tun*" "tailscale*" ];
```

Excluding the interface is what makes this safe. The failure mode if you instead
mark a trust-managed VPN's own connection as *trusted* while running
`mixedPolicy = "trusted"` is a genuine oscillation: untrusted network → VPN
starts → now trusted → VPN stops → untrusted again, repeating at the debounce
interval. The default `mixedPolicy = "untrusted"` is stable, but exclusion is
the real fix.

### Add user-level units

User units require the target user to have lingering enabled:

```nix
users.users.alice.linger = true;

services.nmtrust.userUnits.alice = {
  "ssh-tunnel.service" = {};
  "irc-bouncer.service" = { allowOffline = true; };
};
```

### Temporarily force trust state

```bash
# Force trusted (survives NM events, cleared on reboot)
sudo nmtrust override trusted

# Return to automatic evaluation
sudo nmtrust override clear
```

### Treat mixed networks as trusted

By default, if some connections are trusted and some aren't, the system treats
this as untrusted. To change that:

```nix
services.nmtrust.mixedPolicy = "trusted";
```

### Trust connections not in ensureProfiles

If you have connections whose profiles aren't managed declaratively, add their
UUIDs directly:

```bash
# Find the UUID
nmcli -t -f UUID,NAME connection show
```

```nix
services.nmtrust.trustedUUIDsExtra = [
  "12345678-abcd-efab-cdef-123456789abc"
];
```

## Next steps

- Read the full [README](../README.md) for architecture details, security model,
  and configuration reference
- Check `sudo journalctl -u nmtrust-apply.service` for structured
  transition logs
