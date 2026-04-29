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
      );
    };
}
