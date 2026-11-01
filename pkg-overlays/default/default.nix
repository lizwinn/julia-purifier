# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.julia-purifier`, made from the packages of pkgs/. The
# scope holds the builder `buildJuliaProject` (nix/lib/build-julia-project.nix)
# and the command `julia-purifier`. A consumer that lists this flake in
# `projects` holds the overlay as `julia-purifier/default`, which its package
# sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "julia-purifier";
}
