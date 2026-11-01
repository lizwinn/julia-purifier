# julia-purifier

julia-purifier builds Julia projects in the Nix sandbox from their
Manifest.toml. The manifest names every package by its UUID and git tree
hash. A tree hash is not a hash that Nix can check a download against, so a
lock run records, in `julia-purifier.lock.json`, what the manifest cannot:
the Nix hash of each package source, the URL and hash of each artifact, the
registry snapshot, and the test and editor environments that Pkg resolves
apart from the manifest. Nix then fetches those files, builds a depot from
them, precompiles in the sandbox, and runs the commands and tests of the
project offline. The project commits no generated Nix files.

julia-purifier meets the [purifier contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md).

## Quickstart

In a Julia project (a directory with a Project.toml):

```zsh
nix run github:nix-purifiers/julia-purifier -- lock
```

This writes `julia-purifier.lock.json` beside the manifest. A project without
a manifest gets one, because the lock resolves the project first. Commit both
files.

To build the project in a flake, use the builder in the library of the flake:

```nix
{
  inputs.julia-purifier.url = "github:nix-purifiers/julia-purifier";
  inputs.nixpkgs.follows = "julia-purifier/nixpkgs";

  outputs = { nixpkgs, julia-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      project = julia-purifier.lib.julia-purifier.buildJuliaProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.${system}.default = project.packages.MyPackage;
      checks.${system}.tests = project.tests;
    };
}
```

`buildJuliaProject` takes

- `pkgs` and `src`, the package set and the project root: the directory with
  the manifest (the root of a workspace)
- `lockFile`, which defaults to `julia-purifier.lock.json` in `src`. A
  lockfile outside `src` takes the place of any lockfile in it
- `manifestFile`, when the manifest is not in `src`. Julia packages often keep
  Manifest.toml out of version control; a flake can keep the manifest and the
  lockfile beside the package instead
- `fetchers`, which goes unchanged to `fetchEntry` and `tree` of the shared
  library. A company mirror or credentials go into `fetchers.fetchurl`
- `julia`, the Julia to build with. The default is the nixpkgs
  `julia_1XY-bin` of the major and minor version the manifest names
- `doCheck`, which makes building each package run its tests
- `precompile`, which defaults to true. Julia stamps every precompiled cache
  with a build identifier, so two builds with precompiled caches differ in
  those files. `precompile = false` makes every output reproducible, and
  Julia then compiles on first use

The result has these attributes, all known at evaluation time:

- `packages.<Name>`: one per project that is a Julia package, which is the
  root and each package in the `[workspace]` of a workspace. It has
  `bin/<app>` for each entry of the `[apps]` table of the package, which runs
  the `main` of the package (Julia 1.12 and newer), and
  `share/julia-purifier/project`, the source of the package.
  `packages.<Name>.tests` is the run of the tests of that package, or null
  when it has none
- `tests`: the run of the tests of every package, offline. A package whose
  test dependencies are in `[extras]` or a `test/Project.toml` runs in the
  environment the lock recorded from `Pkg.test`; a test project in the
  workspace runs as itself
- `release`: what `julia-purifier publish` registers, which is the source of
  each package with its git tree hash. It depends on `tests`, so only a
  tested source is released
- `fetches`: the entries of the lock, as download entries of the shared
  [purifier](https://github.com/nix-purifiers/purifier) library. SBOM,
  license and vulnerability tools read this list
- `environment`: `bin/julia` with the project active
- `depot`: the depot of the dependencies, with their sources, artifacts,
  registries, the output of their `deps/build.jl` scripts and their
  precompiled caches. It depends only on the manifest and the lockfile
- `compiled`: the precompiled caches of the packages of the project
- `editor`: the environment of the language server (see Editor)

`lib.julia-purifier.readLock { src, lockFile ? ..., manifestFile ? null }`
reads the manifest and the lockfile into the shared shape
`{ purifier; entries; outputs; problems; }`. A stale, tampered, malformed or
incomplete lockfile shows up in `problems`, and the builder fails
evaluation with it.

`nix develop github:nix-purifiers/julia-purifier` gives a shell with the
`julia-purifier` command.

## Everyday loop

The everyday loop goes through Julia itself, on the locked downloads:

- `julia-purifier julia [args...]` runs Julia with `JULIA_PKG_OFFLINE=true`
  and the project active. Edit the code of the project and run it this way;
  the depot of dependencies stays as it is. Without a lockfile, or with
  `JULIA_PURIFIER=0`, it is plain Julia.
- To add or upgrade a dependency, run Pkg with the network:
  `JULIA_PKG_OFFLINE=false julia-purifier julia -e 'using Pkg; Pkg.add("X")'`.
  The next run says the lockfile is stale, and `julia-purifier lock` renews
  it.
- `julia-purifier update [package...]` updates the named packages, or every
  package, with `Pkg.update`, and then locks the result. `lock` keeps the
  resolution of the manifest as it is.
- `julia-purifier env` prints the environment of `julia` as shell exports
  (`JULIA_DEPOT_PATH`, `JULIA_PKG_OFFLINE`, `JULIA_PROJECT` and `PATH`). A
  tool that starts `julia` itself gets the locked dependencies this way, for
  example with `eval "$(julia-purifier env)"` in an `.envrc`.
- `julia-purifier publish <registry> [--push] [dir]` builds and tests the
  committed tree of the project with Nix, and then registers the version of
  each package with [LocalRegistry.jl](https://github.com/GunnarFarneback/LocalRegistry.jl).
  `registry` is the name or URL of a registry. The registry records the tree
  Nix built and tested; the command stops if the released tree differs from
  the committed one. For the General registry, which accepts versions
  through its Registrator bot, register the commit that this command has
  built.

A lockfile kept outside the project is named by `--lockfile <path>`, right
after the name of the command, or by the environment variable
`JULIA_PURIFIER_LOCKFILE`. The flag takes precedence over the variable, and
both take precedence over the lockfile beside the manifest.

## Offline work

```zsh
julia-purifier prefetch
```

`prefetch` realizes in the Nix store everything development needs for the
current system: the dependency sources, the test dependencies, the
registries, the Julia the manifest names and the language server. It keeps
them alive with a garbage-collector root at `.julia-purifier/prefetch`, next
to the lockfile. Add `.julia-purifier/` to `.gitignore`. After a prefetch,
`julia`, `Pkg.instantiate()`, `Pkg.test()` and the editor work with the
network cut off. `Pkg.test` resolves its environment against the registry
snapshot in the lockfile, so it needs no network either.

Anything that is not in the lockfile still needs the network: a new
dependency, or a version that Pkg has to resolve against a newer registry.
Such a command stops with the own error of Pkg, and `julia-purifier lock` or
`julia-purifier update` records the new download.

## Editor

`julia-purifier language-server` runs [LanguageServer.jl](https://github.com/julia-vscode/LanguageServer.jl)
on standard input and output for the project, from the environment that
`prefetch` realized. Point the Julia language-server setting of the editor at
this command, in the directory of the project. The server finds the
dependencies in the prefetched depot and needs no network; its index goes
under `$XDG_CACHE_HOME/julia-purifier`.

For a tool that wants to start Julia itself, `eval "$(julia-purifier env)"`
puts the locked environment on its `PATH`.

## Errors and fixes

Each of these fails the command and the Nix evaluation with a message that
names the file and the command to run:

| Problem | Message says | Fix |
| --- | --- | --- |
| A lockfile older than the project: the manifest or a Project.toml changed | `<file> changed since the lockfile was made` | `julia-purifier lock` |
| A lockfile edited by hand, truncated, or not JSON | `does not match the hash of its own content` | `julia-purifier lock` |
| A lockfile of another format version | `has format N` | `julia-purifier lock` |
| A package the manifest pins has no hash in the lockfile | `has no hash for <Name>` | `julia-purifier lock` |
| No lockfile | `does not exist` | `julia-purifier lock` |
| A lockfile without artifacts for the system | `records no artifacts for <system>` | Build on a system the lock covers (x86_64-linux, aarch64-linux or aarch64-darwin) |

A changed hash with a correct content hash (the lockfile was written by a
tool other than `lock`) fails the download of that file with the hash
mismatch error of Nix. A `deps/build.jl` that downloads files itself fails in
the sandbox, because Pkg records nothing of such downloads. Current packages
fetch binaries as artifacts instead, which the lock records.

Precompiled caches are not reproducible bit for bit, because Julia stamps
each one with a build identifier. `precompile = false` makes every output
reproducible, and Julia then compiles on first use.

## Sources supported and refused

Supported:

- Packages from the Julia package server, as tarballs, with the storage
  server as a mirror when the server is the public one. `JULIA_PKG_SERVER`
  names another server
- Packages with a `repo-url` in the manifest, and packages of a registry that
  the package server does not serve, as a git checkout of the commit whose
  tree is the tree of the package, including a package in a subdirectory
- Artifacts, including lazy ones, from the URL and hash in the
  Artifacts.toml of the package, for x86_64-linux, aarch64-linux and
  aarch64-darwin
- Workspaces, test environments in `[extras]`, `[targets]` or a
  `test/Project.toml`, packages with a `deps/build.jl`, and a manifest kept
  outside the source

Refused, with a message from the lock run:

- A git dependency with a local path as its URL, which Nix cannot fetch
- A manifest older than format 2, or one for a Julia that nixpkgs lacks
  (1.10 to 1.13 today) unless `julia` is passed
- A registry that Pkg keeps as a git clone in the fresh depot of the lock

SSH URLs are recorded as the HTTPS URL of the same host, since the sandbox
has no SSH keys. A private repository then needs a `fetchers` entry with
credentials.

## Examples

This example builds and tests [JSON3.jl](https://github.com/quinnj/JSON3.jl),
a package you do not own, from a flake of your own. JSON3.jl commits no
Manifest.toml, so the flake keeps the manifest and the lockfile beside it.

Lock the package. In a clone of JSON3.jl, run

```zsh
git clone https://github.com/quinnj/JSON3.jl
cd JSON3.jl
julia-purifier lock
```

The lock resolves the project, writes `Manifest.toml` and
`julia-purifier.lock.json`, and records the test environment. Copy both files
into the directory of your flake:

```zsh
mkdir ../json3-flake
cp Manifest.toml julia-purifier.lock.json ../json3-flake/
```

The flake in `../json3-flake/flake.nix` takes JSON3.jl as a source and builds
it from those files:

```nix
{
  inputs.julia-purifier.url = "github:nix-purifiers/julia-purifier";
  inputs.nixpkgs.follows = "julia-purifier/nixpkgs";
  inputs.json3 = {
    url = "github:quinnj/JSON3.jl";
    flake = false;
  };

  outputs = { nixpkgs, julia-purifier, json3, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      project = julia-purifier.lib.julia-purifier.buildJuliaProject {
        inherit pkgs;
        src = json3;
        manifestFile = ./Manifest.toml;
        lockFile = ./julia-purifier.lock.json;
      };
    in
    {
      packages.${system}.default = project.packages.JSON3;
      checks.${system}.tests = project.tests;
    };
}
```

Then `nix flake check` runs the test suite of JSON3.jl in the sandbox, and
`nix build` builds the package. After you change the version of JSON3.jl in
the flake, run `julia-purifier lock` in a clone at that version and copy the
two files again.

## Credits

The design comes from sbt-nix-backend, now
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier). The purifier
idea was inspired by the [cargo (libnix)](https://github.com/nixcloud/cargo)
project of nixcloud. The shared library is
[purifier](https://github.com/nix-purifiers/purifier).

## License

MIT
