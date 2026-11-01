# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The packages are the `default` entry of this flake's package overlay
    # registry (pkg-overlays/): the package set applies it by default, and
    # the flake exports it as `pkgOverlays` and as the plain
    # `overlays.default`.
    nixpkgs = {
      packages.export.enabled = true;
    };
  };

  # `nix run github:nix-purifiers/julia-purifier -- lock` locks the project
  # in the current directory. `nix develop github:nix-purifiers/julia-purifier`
  # gives a shell with the julia-purifier command.
  perSystem =
    { config, pkgs, ... }:
    {
      packages.default = config.packages.julia-purifier;
      devShells.default = pkgs.mkShell {
        packages = [ config.packages.julia-purifier ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              inherit (inputs) json3;
              readLock' = self.lib.julia-purifier.readLock;
              inherit (self.lib.purifier) checkLock;
              overlay = self.overlays.default;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
