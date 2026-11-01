# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads.
{
  pkgs,
  # The flake's default package overlay, which adds buildJuliaProject and
  # the julia-purifier command.
  overlay,
  # The source of JSON3.jl, pinned in tests/dependencies.
  json3,
}:
let
  inherit (pkgs) lib;

  # Every fixture builds the way a consumer's package does: through
  # buildJuliaProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildJuliaProject;

  # One package with a command, a JSON dependency from the General
  # registry, StringEncodings with its Libiconv_jll artifact, Example from
  # its git repository, and a test-only dependency from [extras].
  app = buildJuliaProject { src = ./fixtures/app; };
  appChecked = buildJuliaProject {
    src = ./fixtures/app;
    doCheck = true;
  };

  # A workspace with a library member that uses a package from a
  # subdirectory of a git repository, its test project, and a command
  # member that depends on the library through a path source.
  workspace = buildJuliaProject { src = ./fixtures/workspace; };

  # An environment (no package of its own) whose dependency Conda has a
  # deps/build.jl, which the depot build runs offline.
  buildscript = buildJuliaProject { src = ./fixtures/buildscript; };

  # A real-world package, JSON3.jl, whose manifest and lockfile lie beside
  # the source rather than in it. Its tests use Arrow, with the LZ4 and
  # Zstandard binary artifacts, and JSON3's ArrowTypes extension.
  realworld = buildJuliaProject {
    src = json3;
    manifestFile = ./realworld/JSON3/Manifest.toml;
    lockFile = ./realworld/JSON3/julia-purifier.lock.toml;
  };

  system = pkgs.stdenv.hostPlatform.system;
  readLock =
    lockFile:
    import ../nix/lib/lock.nix {
      inherit lib system lockFile;
      src = ./fixtures/app;
    };

  # A check passes when `assertion` holds; it fails with `message`
  # otherwise.
  evalCheck =
    name: assertion: message:
    if assertion then
      pkgs.runCommand name { } "touch $out"
    else
      throw "julia-purifier check ${name}: ${message}";

  # Whether evaluating `value` throws. Nix does not show the message to
  # the evaluation, so the checks below match the throw by what they feed
  # the reader.
  fails = value: !(builtins.tryEval (builtins.deepSeq value value)).success;
in
{
  # The command runs, with every dependency loaded, and Julia writes no
  # compiled cache of its own: the store holds them all.
  app =
    pkgs.runCommand "app-check"
      {
        nativeBuildInputs = [ app.packages.HelloPurifier ];
      }
      ''
        export HOME="$TMPDIR"
        hello-purifier Nix | grep -qx '{"greeting":"Hello, Nix","utf16le":6}'
        if [ -n "$(find "$HOME" -name '*.ji' -print -quit)" ]; then
          echo "the command compiled caches into the user's depot" >&2
          find "$HOME" -name '*.ji' >&2
          exit 1
        fi
        touch $out
      '';

  # The tests run in the environment Pkg.test resolved in the lock run,
  # with the test-only dependency.
  app-tests = app.tests.HelloPurifier;

  # With doCheck, building the package runs its tests.
  app-checked = appChecked.packages.HelloPurifier;

  # The environment is Julia with the project active.
  app-environment =
    pkgs.runCommand "app-environment-check"
      {
        nativeBuildInputs = [ app.environment ];
      }
      ''
        export HOME="$TMPDIR"
        julia -e 'using HelloPurifier; print(HelloPurifier.greeting("env"))' \
          | grep -qx '{"greeting":"Hello, env","utf16le":6}'
        touch $out
      '';

  # The command member greets through the library member.
  workspace =
    pkgs.runCommand "workspace-check"
      {
        nativeBuildInputs = [ workspace.packages.Greeter ];
      }
      ''
        export HOME="$TMPDIR"
        greet Nix | grep -qx 'Hello, Nix (SnoopCompileCore loaded: true)'
        touch $out
      '';

  # Conda loads, with the deps/deps.jl its build script wrote in the depot.
  buildscript =
    pkgs.runCommand "buildscript-check"
      {
        nativeBuildInputs = [ buildscript.environment ];
      }
      ''
        export HOME="$TMPDIR"
        julia -e '
          using Conda
          deps = joinpath(dirname(pathof(Conda)), "..", "deps", "deps.jl")
          isfile(deps) || error("Conda has no deps/deps.jl: its build script did not run")
          startswith(pathof(Conda), "${buildscript.depot}") || error("Conda loaded from $(pathof(Conda))")
        '
        touch $out
      '';

  # JSON3.jl's own test suite runs offline.
  realworld-json3-tests = realworld.tests.JSON3;

  # JSON3.jl loads from its package and parses.
  realworld-json3 =
    pkgs.runCommand "realworld-json3-check"
      {
        nativeBuildInputs = [ realworld.environment ];
      }
      ''
        export HOME="$TMPDIR"
        julia -e 'using JSON3; print(JSON3.read("{\"a\":[1,2]}").a[2])' | grep -qx 2
        touch $out
      '';

  # The library member's tests run in the workspace's test project.
  workspace-tests = workspace.tests.Greeting;

  # The outputs are known at evaluation time: one package per member that
  # is a package, one test run per package with tests.
  outputs = evalCheck "outputs" (
    builtins.attrNames workspace.packages == [
      "Greeter"
      "Greeting"
    ]
    && builtins.attrNames workspace.tests == [ "Greeting" ]
    && builtins.attrNames app.packages == [ "HelloPurifier" ]
    && app.packages.HelloPurifier.meta.mainProgram == "hello-purifier"
  ) "the fixtures' packages, tests or commands differ from their Project.toml files";

  # A lockfile whose recorded input hash differs from the file fails
  # evaluation, with a message to run `julia-purifier lock`.
  stale-lock = evalCheck "stale-lock" (fails (readLock ./stale-lock.toml)
    .downloads) "a lockfile with a stale input hash evaluated";

  # A lockfile without artifacts for the system fails evaluation.
  unlocked-system = evalCheck "unlocked-system" (fails
    (import ../nix/lib/lock.nix {
      inherit lib;
      src = ./fixtures/app;
      system = "riscv64-linux";
    }).downloads
  ) "a lockfile evaluated for a system it has no artifacts for";

  # The lock run's parsing and path logic, in the sandbox.
  lock-unit =
    let
      sources = lib.fileset.toSource {
        root = ../.;
        fileset = lib.fileset.unions [
          ../src
          ./lock-unit.jl
        ];
      };
    in
    pkgs.runCommand "lock-unit-check"
      {
        nativeBuildInputs = [
          pkgs.julia_113-bin
          pkgs.git
        ];
      }
      ''
        export HOME="$TMPDIR"
        julia --startup-file=no ${sources}/tests/lock-unit.jl
        touch $out
      '';

  # The command builds (writeShellApplication runs shellcheck on it).
  cli = withOverlay.julia-purifier.julia-purifier;
}
