# SPDX-License-Identifier: MIT
#
# The julia-purifier command.
#
#   julia-purifier lock [dir]       records every file Pkg downloads for the
#                                   project in julia-purifier.lock.toml
#   julia-purifier julia [args...]  runs Julia on the project's locked
#                                   dependencies, offline
#   julia-purifier env              prints that environment as shell
#                                   exports, for direnv and editors
#   julia-purifier register <registry> [--push] [dir]
#                                   builds and tests the committed project
#                                   with Nix, then registers its version
#
# The commands take the Julia of the major and minor version the manifest
# records, from the nixpkgs this package was built from.
{
  writeShellApplication,
  coreutils,
  gnugrep,
  gnused,
  git,
  nix,
  path,
  stdenv,
  # The Julia for a directory without a manifest.
  julia-bin,
}:
writeShellApplication {
  name = "julia-purifier";
  runtimeInputs = [
    coreutils
    gnugrep
    gnused
    git
    nix
  ];
  text = ''
    nixpkgs=${path}
    system=${stdenv.hostPlatform.system}
    lib=${../../nix/lib}
    # The flake's lock, which pins the shared purifier library for the
    # evaluations below.
    flake_lock=${../../flake.lock}
    lock_jl=${../../src/lock.jl}
    register_jl=${../../src/register.jl}

    usage() {
      sed -n 's/^# \{0,1\}//; 4,15p' ${./default.nix} >&2
      exit 2
    }

    # The project root: the nearest directory upwards with a manifest.
    find_root() {
      local dir
      dir="$(realpath "$1")"
      while [ ! -f "$dir/Manifest.toml" ] && ! compgen -G "$dir/Manifest-v*.toml" > /dev/null; do
        if [ "$dir" = / ]; then
          return 1
        fi
        dir="$(dirname "$dir")"
      done
      printf '%s\n' "$dir"
    }

    manifest_of() {
      if [ -f "$1/Manifest.toml" ]; then
        printf '%s\n' "$1/Manifest.toml"
      else
        compgen -G "$1/Manifest-v*.toml" | head -n1
      fi
    }

    # The directory a lock starts from: the nearest directory upwards with a
    # manifest, or else the nearest one with a Project.toml, whose manifest
    # the lock then writes.
    find_project() {
      find_root "$1" && return
      local dir
      dir="$(realpath "$1")"
      while [ ! -f "$dir/Project.toml" ]; do
        if [ "$dir" = / ]; then
          return 1
        fi
        dir="$(dirname "$dir")"
      done
      printf '%s\n' "$dir"
    }

    # The nixpkgs Julia of the manifest's major and minor version, or
    # nixpkgs' default Julia for a project without a manifest.
    julia_for() {
      local version attr manifest
      manifest="$(manifest_of "$1")"
      if [ -z "$manifest" ]; then
        printf '%s\n' ${julia-bin}
        return
      fi
      version="$(grep -m1 '^julia_version' "$manifest" | sed 's/.*"\(.*\)".*/\1/')"
      if [ -z "$version" ]; then
        echo "julia-purifier: $1 has a manifest without julia_version; run Pkg.resolve() with Julia 1.7 or newer" >&2
        exit 1
      fi
      attr="julia_$(echo "$version" | cut -d. -f1)$(echo "$version" | cut -d. -f2)-bin"
      # The expression is Nix, which reads the attribute from the environment.
      # shellcheck disable=SC2016
      JP_NIXPKGS="$nixpkgs" JP_SYSTEM="$system" JP_ATTR="$attr" nix build --impure --no-link --print-out-paths --expr '
        (import (builtins.getEnv "JP_NIXPKGS") { system = builtins.getEnv "JP_SYSTEM"; }).''${builtins.getEnv "JP_ATTR"}
      '
    }

    # Builds the locked dependencies of $root into a cache under
    # $XDG_CACHE_HOME/julia-purifier, with a GC root, and sets $cache to it.
    # The stamp covers the files a lock is made from (the manifest and every
    # Project.toml), so that a change to any of them is checked against the
    # lockfile again.
    prepare_interactive() {
      local stamp
      cache="''${XDG_CACHE_HOME:-$HOME/.cache}/julia-purifier/$(printf '%s' "$root" | sha256sum | cut -c1-32)"
      stamp="$(
        {
          cat "$root/julia-purifier.lock.toml" "$(manifest_of "$root")"
          find "$root" -name Project.toml -not -path '*/.git/*' -print0 | sort -z | xargs -0 cat
        } | sha256sum | cut -d' ' -f1
      )"
      if [ "$(cat "$cache/stamp" 2> /dev/null || true)" != "$stamp" ]; then
        echo "julia-purifier: building the locked dependencies of $root" >&2
        mkdir -p "$cache"
        if ! JP_NIXPKGS="$nixpkgs" JP_SYSTEM="$system" JP_ROOT="$root" nix build --impure --out-link "$cache/interactive" --expr "
          import $lib/interactive.nix {
            pkgs = import (builtins.getEnv \"JP_NIXPKGS\") { system = builtins.getEnv \"JP_SYSTEM\"; };
            src = /. + builtins.getEnv \"JP_ROOT\";
            flakeLock = $flake_lock;
          }
        "; then
          echo "julia-purifier: the lockfile does not build; run \`julia-purifier lock\` to renew it, or set JULIA_PURIFIER=0" >&2
          exit 1
        fi
        printf '%s\n' "$stamp" > "$cache/stamp"
      fi
    }

    cmd="''${1:-}"
    [ -n "$cmd" ] || usage
    shift

    case "$cmd" in
      lock)
        root="$(find_project "''${1:-.}")" || {
          echo "julia-purifier: no Project.toml in ''${1:-.} or above; run the lock in a Julia project" >&2
          exit 1
        }
        julia="$(julia_for "$root")"
        depot="$(mktemp -d)"
        trap 'chmod -R u+w "$depot"; rm -rf "$depot"' EXIT
        # A fresh depot, so that every file Pkg needs is downloaded and
        # recorded. The trailing ":" keeps Julia's own depots after it.
        JULIA_DEPOT_PATH="$depot:" "$julia/bin/julia" --startup-file=no "$lock_jl" "$root"
        ;;

      julia)
        # Without a lockfile (or with JULIA_PURIFIER=0) this is plain Julia:
        # the manifest's Julia where there is a manifest, nixpkgs' default
        # Julia otherwise.
        if [ "''${JULIA_PURIFIER:-1}" = 0 ] || ! root="$(find_root .)" || [ ! -f "$root/julia-purifier.lock.toml" ]; then
          if [ -n "''${root:-}" ] && julia="$(julia_for "$root")"; then
            exec "$julia/bin/julia" "$@"
          fi
          exec ${julia-bin}/bin/julia "$@"
        fi
        prepare_interactive
        # The user's own depot comes first (the leading ":"), where Julia
        # writes; the locked dependencies come after it.
        export JULIA_DEPOT_PATH=":$cache/interactive/depot"
        export JULIA_PKG_OFFLINE="''${JULIA_PKG_OFFLINE:-true}"
        exec "$cache/interactive/julia/bin/julia" --project="$root" "$@"
        ;;

      env)
        # For direnv, an editor or a language server, which start `julia`
        # themselves: the environment `julia-purifier julia` runs Julia in.
        root="$(find_root .)" && [ -f "$root/julia-purifier.lock.toml" ] || {
          echo "julia-purifier: no julia-purifier.lock.toml here or above; run \`julia-purifier lock\` in the project" >&2
          exit 1
        }
        prepare_interactive
        printf 'export JULIA_DEPOT_PATH=%q\n' ":$cache/interactive/depot"
        printf 'export JULIA_PKG_OFFLINE=true\n'
        printf 'export JULIA_PROJECT=%q\n' "$root"
        printf 'export PATH=%q\n' "$cache/interactive/julia/bin:$PATH"
        ;;

      register)
        registry="''${1:-}"
        [ -n "$registry" ] || usage
        shift
        push=
        if [ "''${1:-}" = --push ]; then
          push=push
          shift
        fi
        root="$(find_root "''${1:-.}")" || {
          echo "julia-purifier: no Manifest.toml in ''${1:-.} or above" >&2
          exit 1
        }
        if [ -n "$(git -C "$root" status --porcelain -- .)" ]; then
          echo "julia-purifier: $root has uncommitted changes; a registry records the committed tree" >&2
          exit 1
        fi
        top="$(git -C "$root" rev-parse --show-toplevel)"
        rev="$(git -C "$root" rev-parse HEAD)"
        sub="$(realpath --relative-to="$top" "$root")"
        echo "julia-purifier: building and testing $rev:$sub with Nix" >&2
        JP_NIXPKGS="$nixpkgs" JP_SYSTEM="$system" JP_TOP="$top" JP_REV="$rev" JP_SUB="$sub" nix build --impure --no-link --expr "
          let
            pkgs = import (builtins.getEnv \"JP_NIXPKGS\") { system = builtins.getEnv \"JP_SYSTEM\"; };
            repo = builtins.fetchGit { url = builtins.getEnv \"JP_TOP\"; rev = builtins.getEnv \"JP_REV\"; };
            sub = builtins.getEnv \"JP_SUB\";
            src = if sub == \".\" then repo else repo + \"/\" + sub;
            purifier = import $lib/purifier.nix { inherit (pkgs) lib; flakeLock = $flake_lock; };
            project = pkgs.callPackage $lib/build-julia-project.nix { inherit purifier; } { inherit src; doCheck = true; };
          in
          builtins.attrValues project.packages
        "
        julia="$(julia_for "$root")"
        depot="$(mktemp -d)"
        trap 'chmod -R u+w "$depot"; rm -rf "$depot"' EXIT
        JULIA_DEPOT_PATH="$depot:''${JULIA_DEPOT_PATH:-}" "$julia/bin/julia" --startup-file=no "$register_jl" "$root" "$registry" $push
        ;;

      *)
        usage
        ;;
    esac
  '';
}
