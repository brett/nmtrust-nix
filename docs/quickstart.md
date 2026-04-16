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

> **Before nixpkgs merge:** You also need to add the flake input and import the
> module. See the [README](../README.md#installation) for instructions.

## 3. Rebuild and verify

```bash
sudo nixos-rebuild switch

# Check the current trust state
sudo nmtrust state

# See which target is active and what units are bound
sudo nmtrust status
```

## 4. Test a transition

```bash
# Connect to your trusted network
nmcli connection up home-wifi

# Wait a few seconds for the debounced evaluation
sleep 3

# Verify
sudo nmtrust state
# State: trusted
# Active target: nmtrust-trusted.target

sudo systemctl is-active mailsync.timer
# active

# Disconnect
nmcli connection down home-wifi
sleep 3

sudo nmtrust state
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
