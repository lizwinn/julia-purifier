# SPDX-License-Identifier: MIT
#
# buildJuliaProject: builds a Julia project in the Nix sandbox from its
# Manifest.toml and julia-purifier.lock.toml, offline.
#
#   (buildJuliaProject { src = ./.; }).packages.<Name>
#
# The result has
#
#   depot        the Julia depot of the project's dependencies: every
#                package source and artifact the lock names, the files that
#                the dependencies' deps/build.jl scripts write, and the
#                dependencies' precompiled caches. It is built from the
#                manifest and the lockfile only, so it stays the same while
#                the project's own sources change
#   compiled     a depot with the precompiled caches of the project's own
#                packages, on top of `depot`
#   environment  `bin/julia`, Julia with the project active and both depots
#                behind the user's own depot, offline
#   packages     one package per project that is a Julia package (the root
#                and the members of a workspace), by package name. Each has
#                `bin/<app>` for every entry of the [apps] table in its
#                Project.toml, and `share/julia-purifier/project`. Its
#                `tests` attribute runs the package's tests
#   tests        the test runs, by package name
#
# Every output is known from the Project.toml files and the lockfile, which
# Nix reads at evaluation time.
{
  lib,
  pkgs,
  stdenvNoCC,
  runCommand,
  makeWrapper,
  callPackage,
}:
{
  # The project root: the directory with the Manifest.toml and the
  # julia-purifier.lock.toml (the root of a workspace).
  src,
  # The lockfile, when it is not julia-purifier.lock.toml in `src`.
  lockFile ? src + "/julia-purifier.lock.toml",
  # The manifest, when it is not in `src`. Julia packages often keep their
  # Manifest.toml out of version control; a build then takes it from
  # beside the lockfile.
  manifestFile ? null,
  # The Julia that builds and runs the project. The default is the
  # nixpkgs Julia of the major and minor version the lock was made with.
  julia ? null,
  # Runs every package's tests as part of building it.
  doCheck ? false,
}:
let
  system = stdenvNoCC.hostPlatform.system;
  l = import ./lock.nix {
    inherit
      lib
      src
      system
      lockFile
      manifestFile
      ;
  };

  # The project as Julia sees it: `src`, with the manifest beside its
  # Project.toml when the manifest is kept elsewhere. Evaluation reads the
  # files from `src` and `manifestFile`; only builds use this copy.
  projectSrc =
    if manifestFile == null then
      src
    else
      runCommand "julia-project-source" { } ''
        cp -r ${src} "$out"
        chmod -R u+w "$out"
        cp ${manifestFile} "$out/${l.manifestName}"
      '';

  juliaVersion = lib.splitVersion l.julia;
  juliaAttr = "julia_${builtins.elemAt juliaVersion 0}${builtins.elemAt juliaVersion 1}-bin";
  julia' =
    if julia != null then
      julia
    else
      pkgs.${juliaAttr}
        or (throw "julia-purifier: the lock was made with Julia ${l.julia}, and this nixpkgs has no ${juliaAttr}; pass `julia` to buildJuliaProject.");

  downloads = callPackage ./dependencies.nix {
    inherit (l) downloads;
    name = "julia-purifier-downloads";
  };

  # The depot paths that hold package sources and artifacts. Downloads
  # under git/ are checkouts, which the links place in the depot.
  depotPaths = builtins.filter (p: lib.hasPrefix "packages/" p || lib.hasPrefix "artifacts/" p) (
    map (d: d.path) l.downloads
  );

  projectDir = dir: if dir == "." then "${projectSrc}" else "${projectSrc}/${dir}";

  offlineEnv = ''
    export HOME="$TMPDIR"
    export JULIA_PKG_OFFLINE=true
    export JULIA_PKG_SERVER=""
    export JULIA_PKG_PRECOMPILE_AUTO=0
  '';

  # The manifest is copied to the store on its own, so the depot does not
  # depend on the rest of the source.
  manifest = builtins.path {
    path = l.manifest;
    name = "Manifest.toml";
  };

  depot =
    runCommand "julia-purifier-depot"
      {
        nativeBuildInputs = [ julia' ];
        passAsFile = [
          "paths"
          "links"
        ];
        paths = lib.concatMapStrings (p: "${p}\n") depotPaths;
        links = lib.concatMapStrings (k: "${k.from}\t${k.to}\n") l.links;
      }
      ''
        ${offlineEnv}
        mkdir -p "$out/packages" "$out/artifacts"
        while IFS= read -r p; do
          mkdir -p "$out/$(dirname "$p")"
          cp -rL --preserve=mode ${downloads}/"$p" "$out/$p"
        done < "$pathsPath"
        while IFS=$'\t' read -r from to; do
          mkdir -p "$out/$(dirname "$to")"
          cp -rL --preserve=mode ${downloads}/"$from" "$out/$to"
        done < "$linksPath"
        chmod -R u+w "$out"

        export JULIA_DEPOT_PATH="$out:"
        julia --startup-file=no ${./deps-env.jl} ${manifest} deps
        deps="$PWD/deps"
        julia --startup-file=no --project="$deps" -e 'using Pkg; Pkg.instantiate()'
        # Each deps/build.jl runs from its deps directory, in the environment
        # of the manifest's packages, with the flags Pkg builds with. Pkg's
        # own build resolves a fresh environment against a registry, which
        # the sandbox does not have.
        for p in ${lib.escapeShellArgs l.builds}; do
          echo "julia-purifier: running $p/deps/build.jl"
          (cd "$out/$p/deps" && julia --startup-file=no --project="$deps" -O0 --compile=min --color=no build.jl)
        done
        julia --startup-file=no --project="$deps" -e 'using Pkg; Pkg.precompile()'
        rm -rf "$out/logs"
      '';

  # Julia writes new caches into the first depot only, so the project's own
  # packages are compiled into this depot and the dependencies' caches stay
  # in `depot`.
  compiled =
    runCommand "julia-purifier-compiled"
      {
        nativeBuildInputs = [ julia' ];
      }
      ''
        ${offlineEnv}
        mkdir -p "$out"
        export JULIA_DEPOT_PATH="$out:${depot}:"
        # Pkg precompiles what the active project reaches, so each project
        # of a workspace is precompiled on its own.
        for dir in ${lib.escapeShellArgs (map projectDir (builtins.attrNames l.projects))}; do
          julia --startup-file=no --project="$dir" -e '
            using Pkg
            Pkg.instantiate()
            Pkg.precompile()
          '
        done
        rm -rf "$out/logs" "$out/environments"
      '';

  # The depots a program of the project runs with. The leading empty entry
  # puts the user's own depot first, where Julia writes.
  runtimeDepots = ":${compiled}:${depot}";

  environment =
    runCommand "julia-purifier-environment"
      {
        nativeBuildInputs = [ makeWrapper ];
      }
      ''
        mkdir -p "$out/bin"
        makeWrapper ${lib.getExe julia'} "$out/bin/julia" \
          --set JULIA_DEPOT_PATH ${lib.escapeShellArg runtimeDepots} \
          --set-default JULIA_PKG_OFFLINE true \
          --add-flags "--project=${projectSrc}"
      '';

  testFor =
    p:
    let
      dir = projectDir p.dir;
      recorded = l.tests.${p.dir} or null;
      inWorkspace = l.projects ? ${if p.dir == "." then "test" else "${p.dir}/test"};
      depots = "$TMPDIR/depot:${compiled}:${depot}:";
    in
    if recorded != null then
      runCommand "${p.name}-tests"
        {
          nativeBuildInputs = [ julia' ];
          passAsFile = [
            "project"
            "manifest"
          ];
          project = recorded."Project.toml";
          manifest = recorded."Manifest.toml";
        }
        ''
          ${offlineEnv}
          # The recorded environment names the project as ../root.
          mkdir -p env
          ln -s ${projectSrc} root
          cp "$projectPath" env/Project.toml
          cp "$manifestPath" env/Manifest.toml
          env="$PWD/env"
          export JULIA_DEPOT_PATH="${depots}"
          julia --startup-file=no ${./project-hash.jl} "$env"
          julia --startup-file=no --project="$env" -e 'using Pkg; Pkg.instantiate()'
          cd ${dir}/test
          julia --startup-file=no --project="$env" --check-bounds=yes runtests.jl
          touch "$out"
        ''
    else if inWorkspace || builtins.pathExists (src + "/${p.dir}/test/runtests.jl") then
      runCommand "${p.name}-tests"
        {
          nativeBuildInputs = [ julia' ];
        }
        ''
          ${offlineEnv}
          export JULIA_DEPOT_PATH="${depots}"
          cd ${dir}/test
          julia --startup-file=no --project=${
            if inWorkspace then "${dir}/test" else dir
          } --check-bounds=yes runtests.jl
          touch "$out"
        ''
    else
      null;

  tests = lib.filterAttrs (_: t: t != null) (lib.mapAttrs (_: testFor) l.packages);

  packageFor =
    name: p:
    let
      apps = p.apps or { };
      appFlags =
        spec:
        lib.concatStringsSep " " (
          [
            "--startup-file=no"
            "--project=${projectDir p.dir}"
          ]
          ++ (spec.julia_flags or [ ])
          ++ [
            "-m"
            (if spec ? submodule then "${name}.${spec.submodule}" else name)
          ]
        );
      test = tests.${name} or null;
    in
    runCommand "${lib.strings.sanitizeDerivationName name}-${p.version or "0.0.0"}"
      {
        nativeBuildInputs = [ makeWrapper ];
        # With doCheck, building the package runs its tests.
        checked = lib.optionalString (doCheck && test != null) "${test}";
        passthru = {
          inherit depot compiled;
          julia = julia';
          tests = test;
          project = projectDir p.dir;
        };
        meta = lib.optionalAttrs (apps != { }) {
          mainProgram = builtins.head (builtins.attrNames apps);
        };
      }
      ''
        mkdir -p "$out/bin" "$out/share/julia-purifier"
        ln -s ${projectDir p.dir} "$out/share/julia-purifier/project"
        ${lib.concatStrings (
          lib.mapAttrsToList (app: spec: ''
            makeWrapper ${lib.getExe julia'} "$out/bin/${app}" \
              --set JULIA_DEPOT_PATH ${lib.escapeShellArg runtimeDepots} \
              --set-default JULIA_PKG_OFFLINE true \
              --add-flags ${lib.escapeShellArg (appFlags spec)}
          '') apps
        )}
      '';
in
{
  inherit
    depot
    compiled
    environment
    tests
    ;
  julia = julia';
  packages = lib.mapAttrs packageFor l.packages;
}
