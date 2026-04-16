{
  description = "nmtrust-nix: declarative network trust management for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      nixosModules.default = import ./module.nix;
      nixosModules.nmtrust = import ./module.nix;

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          nmtrust = pkgs.callPackage ./package.nix { };
          default = self.packages.${system}.nmtrust;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = nixpkgs.lib;

          # pkgs extended with nmtrust so the nixpkgs module (which references
          # pkgs.nmtrust) can be evaluated locally without a full nixpkgs checkout.
          pkgsWithNmtrust = pkgs.extend (
            _: prev: { nmtrust = prev.callPackage ./package.nix { }; }
          );

          # Wrap a nixpkgs-format test (no module import) for local use by
          # injecting the nixpkgs module and the nmtrust overlay into each node.
          wrapNixpkgsTest =
            testFile:
            let
              testDef = import testFile { inherit lib; pkgs = pkgsWithNmtrust; };
            in
            pkgsWithNmtrust.testers.nixosTest {
              inherit (testDef) name testScript;
              nodes = lib.mapAttrs (
                _: nodeCfg: {
                  imports = [ nodeCfg ./nixpkgs/module.nix ];
                  nixpkgs.overlays = [ (_: prev: { nmtrust = prev.callPackage ./package.nix { }; }) ];
                }
              ) testDef.nodes;
            };
        in
        (import ./tests/eval.nix {
          inherit pkgs lib;
          nixosModule = self.nixosModules.default;
        })
        // (import ./tests/vm.nix {
          inherit pkgs lib;
          nixosModule = self.nixosModules.default;
          system = system;
        })
        // {
          nixpkgs-test-nmtrust = wrapNixpkgsTest ./nixpkgs/tests/nmtrust.nix;
        }
      );
    };
}
