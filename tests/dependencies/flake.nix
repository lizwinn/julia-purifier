# SPDX-License-Identifier: MIT
{
  inputs.caisson.url = "github:nix-caisson/caisson";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  # Same channel as the main flake, so dev-partition evals agree with the
  # exported pkgSet.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.treefmt-nix.url = "github:numtide/treefmt-nix";
  inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  # A real-world package for the integration check: JSON3.jl at v1.14.4. It
  # keeps no manifest in its repository; tests/realworld/JSON3 holds the
  # manifest and the lockfile.
  inputs.json3 = {
    url = "github:quinnj/JSON3.jl/15061b1226f85fdc9c6665b9342e6ec01b5cb768";
    flake = false;
  };
  outputs = { ... }: { };
}
