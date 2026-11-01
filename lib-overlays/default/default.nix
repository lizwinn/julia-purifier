# SPDX-License-Identifier: MIT
#
# The `julia-purifier` library namespace:
#
#   readLock           the lock in memory of a project (nix/lib/lock.nix)
#   buildJuliaProject  the builder (nix/lib/build-julia-project.nix), which
#                      takes the package set as its `pkgs` argument
#
# Both use the shared purifier library, which this flake lists in
# `projects`, so the library has `purifier`.
{ ... }:
{

  overlay = final: prev: {
    julia-purifier = (prev.julia-purifier or { }) // {
      readLock = import ../../nix/lib/lock.nix { lib = final; };
      buildJuliaProject = import ../../nix/lib/build-julia-project.nix {
        lib = final;
        inherit (final) purifier;
      };
    };
  };

}
