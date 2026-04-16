# Submitting to nixpkgs

This directory contains nixpkgs-ready versions of the package and module.
They are functionally identical to the flake's `package.nix` and `module.nix`
but follow nixpkgs conventions.

## Files

| File | nixpkgs destination | Purpose |
|---|---|---|
| `package.nix` | `pkgs/by-name/nm/nmtrust/package.nix` | The `nmtrust` CLI tool |
| `module.nix` | `nixos/modules/services/networking/nmtrust.nix` | The `services.nmtrust` NixOS module |

## Key differences from the flake versions

### package.nix

- Uses `fetchFromGitHub` to pull source from a tagged release (update
  `version` and `hash` when bumping)
- Adds `meta` attributes (`description`, `longDescription`, `homepage`,
  `license`, `maintainers`, `mainProgram`, `platforms`)
- The package installs `nmtrust.sh` verbatim with no config baked in;
  configuration is read at runtime from `/etc/nmtrust/config`

### module.nix

- References the package as `pkgs.nmtrust` (assumes the package is in nixpkgs)
- Generates `/etc/nmtrust/config` via `environment.etc` with bash variable
  assignments sourced by the script at runtime (store symlink, world-readable)
- Uses nixpkgs-style option documentation (nixos-render-docs markup)
- Includes `meta.maintainers`

## Version bumps

To bump the version in the nixpkgs package:

1. Tag a new release in the GitHub repo (`git tag v0.2.0 && git push --tags`)
2. Update `version` in `package.nix` (`rev` derives from it via `v${version}`)
3. Replace the `hash` with `""` and build -- the error message will show the
   correct hash
4. Commit: `nmtrust: 0.1.0 -> 0.2.0`

## Before submitting

1. Add your nixpkgs maintainer handle to `maintainers` in both files
2. Register the module in `nixos/modules/module-list.nix`:
   ```
   ./services/networking/nmtrust.nix
   ```
3. Test with `nixos-rebuild build` against a local nixpkgs checkout
4. Run the NixOS VM tests (adapt `tests/vm.nix` for the nixpkgs test
   framework if needed)
5. Write a commit message following the nixpkgs convention:
   ```
   nmtrust: init at 0.1.0
   ```

## Using the flake before merge

See the [main README](../README.md#installation) for flake input instructions.
