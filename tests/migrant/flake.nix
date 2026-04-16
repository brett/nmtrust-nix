{
  description = "NixOS qcow2 cloud image for network trust module testing";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      # NixOS system configuration for the cloud image
      nixosConfig = lib.nixosSystem {
        inherit system;
        modules = [
          # QEMU/KVM guest profile — loads virtio drivers and guest agent
          "${nixpkgs}/nixos/modules/profiles/qemu-guest.nix"

          # Import the network trust module from the parent repo
          ../../module.nix

          (
            {
              config,
              pkgs,
              modulesPath,
              ...
            }:
            {

              # --- Disk image builder ---
              system.build.qcow2 = import "${modulesPath}/../lib/make-disk-image.nix" {
                inherit lib config pkgs;
                baseName = "nixos-base";
                diskSize = "auto";
                format = "qcow2";
                partitionTableType = "legacy";
              };

              # --- Boot ---
              boot.loader.grub.enable = true;
              boot.loader.grub.device = "/dev/vda";
              boot.growPartition = true;

              fileSystems."/" = {
                device = "/dev/vda1";
                fsType = "ext4";
                autoResize = true;
              };

              # --- Serial console ---
              boot.kernelParams = [ "console=ttyS0,115200n8" ];
              systemd.services."serial-getty@ttyS0".enable = true;

              # --- virtiofs ---
              boot.initrd.availableKernelModules = [ "virtiofs" ];

              # --- Cloud-init ---
              services.cloud-init.enable = true;
              services.cloud-init.settings.ssh_genkeytypes = [ ];
              services.cloud-init.settings.cloud_final_modules = [
                "rightscale_userdata"
                "scripts-vendor"
                "scripts-per-once"
                "scripts-per-boot"
                "scripts-per-instance"
                "scripts-user"
                "ssh-authkey-fingerprints"
                "phone-home"
                "final-message"
                "power-state-change"
              ];

              # --- OpenSSH ---
              services.openssh = {
                enable = true;
                settings = {
                  PermitRootLogin = "prohibit-password";
                  PasswordAuthentication = true;
                };
              };

              # Allow passwordless sudo for wheel group members
              security.sudo.wheelNeedsPassword = false;

              # --- /bin/bash compatibility ---
              system.activationScripts.binbash = lib.stringAfter [ "stdio" ] ''
                ln -sfn ${pkgs.bash}/bin/bash /bin/bash
              '';

              # --- Nix flakes ---
              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];

              # --- NetworkManager ---
              networking.networkmanager.enable = true;

              # The VM's primary NIC and loopback are excluded at the trust
              # evaluation level (see excludedConnectionPatterns below).

              # --- Test connection profiles ---
              # Dummy interfaces simulate trusted/untrusted/excluded networks.
              # UUIDs are fixed so the trust module can reference them at eval time.
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

              # --- Trust module config ---
              services.nmtrust = {
                enable = true;
                trustedConnections = [ "trusted-net" ];
                # M37 test: this UUID is trusted but will be used with a docker* name
                trustedUUIDsExtra = [ "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee" ];
                excludedConnectionPatterns = [
                  "docker*"
                  "Wired*"
                  "lo"
                ];
                mixedPolicy = "untrusted";
                evalFailurePolicy = "untrusted";

                systemUnits = {
                  "trust-test-canary.service" = { };
                  "trust-test-offline-canary.service" = {
                    allowOffline = true;
                  };
                };

                userUnits.testuser = {
                  "trust-test-user-canary.service" = { };
                };
              };

              # --- Test canary services ---
              # Minimal services whose running/stopped state is the test assertion.
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
              systemd.user.services.trust-test-user-canary = {
                description = "Trust test canary (user, trusted-only)";
                serviceConfig = {
                  Type = "simple";
                  ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
                };
              };

              # --- Test user ---
              users.users.testuser = {
                isNormalUser = true;
                linger = true;
              };

              # --- Packages ---
              environment.systemPackages = with pkgs; [
                cloud-init
                git
                unzip
              ];

              # --- Disable unnecessary services ---
              systemd.timers.fstrim.enable = false;
              nix.gc.automatic = false;
              nix.optimise.automatic = false;

              networking.hostName = "nixos-trust-test";

              system.stateVersion = "25.11";
            }
          )
        ];
      };

    in
    {
      packages.${system} =
        let
          image = nixosConfig.config.system.build.qcow2;
        in
        {
          nixos-image = image;
          default = image;
        };
    };
}
