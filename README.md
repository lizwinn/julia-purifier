# julia-purifier

julia-purifier builds Julia projects in the Nix sandbox from their
Manifest.toml. A lock run records every file Pkg downloads for the project in
`julia-purifier.lock.toml`: package sources, artifacts such as JLL binaries,
and the test environment Pkg resolves. Nix then fetches those files, builds a
depot from them, precompiles in the sandbox, and runs the project's commands
and tests offline. The project commits no generated Nix files; Nix reads the
lockfile and the Project.toml files at evaluation time.

## Quickstart

In a Julia project (a directory with a Project.toml):

```zsh
nix run github:nix-purifiers/julia-purifier -- lock
```

This writes `julia-purifier.lock.toml` beside the manifest. A project without
a manifest gets one: the lock resolves the project first. Commit both files.

To run Julia on the locked dependencies, offline:

```zsh
nix run github:nix-purifiers/julia-purifier -- julia
```

`nix develop github:nix-purifiers/julia-purifier` gives a shell with the
`julia-purifier` command.

## Using it in a flake

The flake's `overlays.default` adds `buildJuliaProject` to a package set:

```nix
{
  inputs.julia-purifier.url = "github:nix-purifiers/julia-purifier";
  inputs.nixpkgs.follows = "julia-purifier/nixpkgs";

  outputs = { nixpkgs, julia-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ julia-purifier.overlays.default ];
      };
      project = pkgs.buildJuliaProject { src = ./.; };
    in
    {
      packages.${system}.default = project.packages.MyPackage;
      checks.${system}.tests = project.tests.MyPackage;
    };
}
```

`buildJuliaProject` takes

- `src`, the project root: the directory with the manifest (the root of a
  workspace)
- `lockFile` and `manifestFile`, when they are not in `src`. Julia packages
  often keep Manifest.toml out of version control; a flake can keep the
  manifest and the lockfile beside the package instead
- `julia`, the Julia to build with. The default is the nixpkgs
  `julia_1XY-bin` of the major and minor version the lock was made with
- `doCheck`, which makes building each package run its tests

## Outputs

Every output is known at evaluation time, from the Project.toml files and the
lockfile:

- `packages.<Name>`: one per project that is a Julia package, which is the
  root and each package in the `[workspace]` of a workspace. It has
  `bin/<app>` for each entry of the package's `[apps]` table, which runs the
  package's `main` (Julia 1.12 and newer), and
  `share/julia-purifier/project`, the package's source
- `tests.<Name>`: a run of the package's tests, offline. A package whose test
  dependencies are in `[extras]` or a `test/Project.toml` runs in the
  environment the lock recorded from Pkg.test; a test project in the
  workspace runs as itself
- `environment`: `bin/julia` with the project active
- `depot`: the depot of the project's dependencies, with their sources,
  artifacts, the output of their `deps/build.jl` scripts, and their
  precompiled caches. It depends only on the manifest and the lockfile
- `compiled`: the precompiled caches of the project's own packages

The commands and `environment` put the user's own depot first in
`JULIA_DEPOT_PATH`, where Julia writes, and the store depots after it. They
start without compiling anything the build already compiled.

## Commands

- `julia-purifier lock [dir]` runs the lock with the network, in a fresh
  depot, with the Julia of the manifest's version. It honors
  `JULIA_PKG_SERVER`.
- `julia-purifier julia [args...]` runs Julia on the locked dependencies, with
  `JULIA_PKG_OFFLINE=true`. It builds the depot through Nix the first time and
  after the lockfile changes, and keeps it alive with a GC root under
  `$XDG_CACHE_HOME/julia-purifier`. Without a lockfile, or with
  `JULIA_PURIFIER=0`, it is plain Julia.
- `julia-purifier env` prints that environment as shell exports
  (`JULIA_DEPOT_PATH`, `JULIA_PKG_OFFLINE`, `JULIA_PROJECT` and `PATH`). An
  editor, a language server or direnv that starts `julia` itself gets the
  locked dependencies this way, for example with `eval "$(julia-purifier env)"`
  in an `.envrc`.
- `julia-purifier register <registry> [--push] [dir]` publishes a version. It
  builds and tests the committed tree of the project with Nix, and then
  registers the version in the project's Project.toml with
  [LocalRegistry.jl](https://github.com/GunnarFarneback/LocalRegistry.jl).
  `registry` is the name or URL of a registry. The registry then records the
  tree Nix built and tested. For the General registry, which accepts versions
  through its Registrator bot, register the commit that this command has
  built.

## The everyday loop

- Edit the project's own code and run it with `julia-purifier julia`; the
  depot of dependencies stays as it is.
- To add or upgrade a dependency, run Pkg with the network:
  `JULIA_PKG_OFFLINE=false julia-purifier julia -e 'using Pkg; Pkg.add("X")'`.
  The next run says the lockfile is stale; `julia-purifier lock` renews it.
- A build or a run with a stale lockfile, a lockfile that lacks a package the
  manifest pins, or a malformed lockfile fails with a message that names the
  file and says to run `julia-purifier lock`. A tampered hash fails the
  download of that file with Nix's hash mismatch.

## The lockfile

The lockfile is TOML, which both Pkg and Nix read. It holds

- `downloads` holds each package source as an entry of the shared
  [purifier](https://github.com/nix-purifiers/purifier) library, which
  fetches the entries and lays them out. A package the package server serves is an archive entry
  (`{ path, archive = { url, mirrors, stripTop }, hash }`) at
  `packages/<Name>/<slug>`, with the storage server as a mirror. A package
  from a git repository is a git entry (`{ path, git = { url, rev,
  submodules, leaveDotGit }, hash }`) of the commit whose tree is the
  package's tree, and `links` places the package's directory of that checkout
  in the depot. That covers a package with a `repo-url` in the manifest and a
  package of a registry the package server does not serve. TOML has no null,
  so git entries leave out the `commitObject` field of the shared shape,
  which is null for them
- `artifacts`: per Nix system (x86_64-linux, aarch64-linux and
  aarch64-darwin), the artifacts the packages select there, including lazy
  ones, as archive entries with the URL and hash of their Artifacts.toml
- `builds`: the packages with a `deps/build.jl`, which the depot build runs
- `tests`: the Project.toml and Manifest.toml of each test environment
  Pkg.test resolves
- `inputs`: the SHA-256 of the manifest and each Project.toml, which make a
  changed project fail with a message to relock

A relock of an unchanged project writes the same lockfile.

## Limits

- The manifest has to be manifest format 2, which Julia 1.7 and newer write,
  and the Julia version it names has to be in nixpkgs (1.10 to 1.13 today) or
  passed as `julia`.
- A `deps/build.jl` that downloads files itself fails in the sandbox. Pkg
  records nothing of such downloads, and the lock does not watch the network
  of a build script. Current packages fetch binaries as artifacts instead,
  which the lock records.
- A git dependency with a local path as its URL cannot be fetched by Nix; the
  lock stops with a message. SSH URLs are recorded as the HTTPS URL of the
  same host, since the sandbox has no SSH keys; a private repository then
  needs a `fetchgit` with credentials.
- The flake builds and checks on x86_64-linux and aarch64-linux. The lock
  also records aarch64-darwin artifacts.

## Projects tried

- [JSON3.jl](https://github.com/quinnj/JSON3.jl) v1.14.4 (commit 15061b1).
  Its whole test suite, with Arrow, its LZ4 and Zstd artifacts and JSON3's
  ArrowTypes extension, runs offline as the `realworld-json3-tests` check; the
  lock takes about 20 seconds.
- [CSV.jl](https://github.com/JuliaData/CSV.jl) v1.3.0 (commit 1f684f5), which
  has no committed manifest and a `test/Project.toml`: the lock resolves its
  manifest, records its sandboxed test environment and takes about 16 seconds.

## Tests

`nix flake check` builds the fixtures in `tests/fixtures` (an application with
a git dependency, a JLL artifact, a command and a test-only dependency; a
workspace with a package from a repository subdirectory and a workspace test
project; an environment whose dependency has a build script), JSON3.jl, the
lock run's unit tests and the lockfile reader's error checks. `bash
tests/cli.sh` runs the command with the network: relocks reproduce the
committed lockfiles byte for byte, the offline `julia`, the everyday loop,
damaged lockfiles and `register`. CI runs both on x86_64-linux and
aarch64-linux.

## Credit

The design comes from sbt-nix-backend, now
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier). The purifier
idea was inspired by nixcloud's [cargo (libnix)](https://github.com/nixcloud/cargo).

## License

MIT
