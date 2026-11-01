# SPDX-License-Identifier: MIT
#
# What `julia-purifier julia` builds for a project: the depot of the
# project's dependencies and the Julia the lock was made with, as `depot`
# and `julia` links in one store path. The depot depends only on the
# manifest and the lockfile, so editing the project's own sources does not
# rebuild it. The wrapper evaluates this file with the project root's
# absolute path and keeps the result alive with a GC root.
{
  pkgs,
  src,
}:
let
  project = pkgs.callPackage ./build-julia-project.nix { } { inherit src; };
in
pkgs.runCommand "julia-purifier-interactive" { } ''
  mkdir -p "$out"
  ln -s ${project.depot} "$out/depot"
  ln -s ${project.julia} "$out/julia"
''
