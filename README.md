# julia-purifier

julia-purifier keeps Julia's development workflow on locked,
Nix-resolved dependencies. Use the normal build and test commands in your
working tree; building the project itself in the Nix sandbox is an
optional next step.

## Quickstart

From the project root:

```zsh
nix shell 'github:nix-purifiers/julia-purifier'
julia-purifier lock
julia-purifier prefetch
eval "$(julia-purifier env)"
julia --project -e 'using Pkg; Pkg.test()'
```

Commit the lockfiles that the lock command writes, including the build
tool's own lockfile when it has one. Keep using the project's usual build,
test and editor commands with this setup. Nix provides the locked
dependencies; the development commands above run outside the Nix sandbox.
No project Nix files are needed for this workflow.

Sandboxed builds of the whole project are an optional
[next step](#building-the-project-with-nix).

The required wrapper is `julia-purifier julia`; pass your usual tool
arguments after it. With no purifier lockfile, it warns on standard error
and runs the ordinary tool with impure resolution.

For persistent use, add these packages through your usual Nix configuration.


## Development loop

The development loop goes through Julia itself, on the locked downloads.
Pkg has no plugin mechanism for tasks, so the `julia-purifier` command is a
program that runs Pkg and records what Pkg downloaded:

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
  `registry` is the name or URL of a registry. A Julia package has no archive
  to upload: a version is an entry in a registry that names a git tree. The
  `release` therefore holds the source and tree hash that Nix built and
  tested, and `publish` registers that tree. The command stops if the
  released tree differs from the committed one. For the General registry,
  which accepts versions through its Registrator bot, register the commit
  that this command has built.

A build can instead keep its lockfiles outside the repository. The
purifier lockfile is then named by `--lockfile <path>`, right after the name
of the command, or by the environment variable `JULIA_PURIFIER_LOCKFILE`.
The `Manifest.toml` is named by `--tool-lockfile <path>` or by
`JULIA_PURIFIER_TOOL_LOCKFILE`. With either one, `lock` and `update` read and
write the file there and leave the copy in the tree as it is. When the file
does not exist yet, they start from the copy in the tree. A flag takes
precedence over its variable, and both take precedence over the files in the
tree.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

The overlay adds one attribute to the package set, the scope
`pkgs.julia-purifier`, which holds the builder `buildJuliaProject` and the
command `julia-purifier`. The result of the build has `bin/<app>` for each
entry of the `[apps]` table of the package.

A project whose authors want a flake packages it with the same builder. The
flake can live in the repository of the project or in another repository:

```nix
{
  inputs.julia-purifier.url = "github:nix-purifiers/julia-purifier";
  inputs.nixpkgs.follows = "julia-purifier/nixpkgs";

  outputs =
    { nixpkgs, julia-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ julia-purifier.overlays.default ];
      };
      project = pkgs.julia-purifier.buildJuliaProject { src = ./.; };
    in
    {
      packages.${system}.default = project.packages.MyPackage;
      checks.${system}.tests = project.tests;
    };
}
```

`julia-purifier.overrideScope` replaces what the scope shares, and
`buildJuliaProject.override` replaces the packages that the builder takes
from the package set, such as `julia_113-bin`. The builder takes

- `src`, the project root: the directory with the manifest (the root of a
  workspace)
- `lockFile`, which defaults to `julia-purifier.lock.json` in `src`. A
  lockfile outside `src` takes the place of any lockfile in it
- `manifest`, which defaults to the `Manifest.toml` in `src`. A copy kept
  outside `src` takes the place of the one in `src` for the build
- `fetchers`, which goes unchanged to `fetchEntry` and `tree` of the shared
  library. A company mirror or credentials go into `fetchers.fetchurl`
- `julia`, the Julia to build with. The default is the `julia_1XY-bin` of the
  package set for the major and minor version the manifest names
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

The library of the flake holds
`lib.julia-purifier.readLock { src, lockFile ? ..., manifest ? null }`,
which reads the manifest and the lockfile into the shared shape
`{ purifier; entries; outputs; problems; }`. A stale, tampered, malformed or
incomplete lockfile shows up in `problems`, and the builder fails
evaluation with it.

`nix shell 'github:nix-purifiers/julia-purifier'` gives a shell with the
`julia-purifier` command.

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/julia-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.julia-purifier.buildJuliaProject { src = ./.; })
.packages.MyPackage'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

## Working offline

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

## Troubleshooting

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

## Supported language repositories

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

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

This example builds and tests [JSON3.jl](https://github.com/quinnj/JSON3.jl),
a package that commits no `Manifest.toml`. In a clone of the repository, lock
the project:

```zsh
nix shell 'github:nix-purifiers/julia-purifier'
git clone https://github.com/quinnj/JSON3.jl
cd JSON3.jl
julia-purifier lock
```

The lock resolves the project, and writes `Manifest.toml` and
`julia-purifier.lock.json` into the clone. Then build the package from the
directory of the clone:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/julia-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.julia-purifier.buildJuliaProject { src = ./.; })
.packages.JSON3'
```

To run the test suite of JSON3.jl in the sandbox, build `.tests` in place of
`.packages.JSON3`.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## License

MIT
