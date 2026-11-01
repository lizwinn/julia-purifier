# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.julia-purifier` (`.julia-purifier`, the command). The builder is in
# the library, as `lib.julia-purifier.buildJuliaProject`. A consumer that
# lists this flake in `projects` holds the overlay as
# `julia-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "julia-purifier";
}
