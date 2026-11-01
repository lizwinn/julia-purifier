# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.julia-purifier` (`.julia-purifier`), and the builder
# `pkgs.buildJuliaProject` (nix/lib/build-julia-project.nix) beside them,
# where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. A consumer that lists this flake in
# `projects` holds it as `julia-purifier/default`, which its package sets
# apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "julia-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildJuliaProject = final.callPackage ../../nix/lib/build-julia-project.nix { };
    };
}
