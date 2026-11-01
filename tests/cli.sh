#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests the julia-purifier command on the fixtures, with the network:
#
#   1. `lock` on a copy of each fixture writes the lockfile committed beside
#      the fixture, byte for byte.
#   2. `julia` in the app fixture runs Julia on the locked dependencies,
#      offline, and loads the project.
#   3. `julia` refuses a stale lockfile, with a message to relock.
#   4. The everyday loop: Julia started in the environment `env` prints
#      loads the project; adding a dependency makes the lockfile stale
#      until a relock; after it, the new dependency loads offline.
#   5. A build from a damaged lockfile fails with a message that names the
#      problem: a tampered hash, a missing entry, a malformed file and a
#      stale input.
#   6. `register` builds and tests the committed app with Nix and registers
#      its version in a local registry, which then records the tree of the
#      committed source.
#
# Run it from the repository root: bash tests/cli.sh
set -euo pipefail
trap 'echo "tests/cli.sh: line $LINENO failed: $BASH_COMMAND" >&2' ERR

repo="$(pwd)"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
export HOME="$work/home"
export XDG_CACHE_HOME="$work/cache"
export GIT_CONFIG_GLOBAL="$work/gitconfig"
mkdir -p "$HOME"
git config --global user.name "julia-purifier tests"
git config --global user.email "tests@julia-purifier.invalid"
git config --global init.defaultBranch main

nix build "$repo#julia-purifier" --out-link "$work/cli"
cli="$work/cli/bin/julia-purifier"

echo "== 1. lock reproduces the committed lockfiles"
for fixture in app workspace; do
  cp -r "$repo/tests/fixtures/$fixture" "$work/$fixture"
  chmod -R u+w "$work/$fixture"
  rm "$work/$fixture/julia-purifier.lock.toml"
  "$cli" lock "$work/$fixture"
  diff -u "$repo/tests/fixtures/$fixture/julia-purifier.lock.toml" "$work/$fixture/julia-purifier.lock.toml"
done

echo "== 2. julia runs on the locked dependencies"
cd "$work/app"
out="$("$cli" julia -e 'using HelloPurifier; print(HelloPurifier.greeting("cli"))')"
[ "$out" = '{"greeting":"Hello, cli","utf16le":6}' ] || {
  echo "unexpected output: $out" >&2
  exit 1
}

echo "== 3. julia refuses a stale lockfile"
cp Project.toml Project.toml.orig
printf '\n# an edit\n' >> Project.toml
if "$cli" julia -e 'exit(0)' 2> "$work/stale.log"; then
  echo "julia ran with a stale lockfile" >&2
  exit 1
fi
grep -q 'julia-purifier lock' "$work/stale.log"
mv Project.toml.orig Project.toml

echo "== 4. the everyday loop: editor environment, add a dependency, relock"
cp -r "$repo/tests/fixtures/app" "$work/loop"
chmod -R u+w "$work/loop"
cd "$work/loop"
# An editor or a language server starts `julia` itself, in the
# environment `julia-purifier env` prints.
(
  eval "$("$cli" env)"
  out="$(julia -e 'using HelloPurifier; print(HelloPurifier.greeting("env"))')"
  [ "$out" = '{"greeting":"Hello, env","utf16le":6}' ] || {
    echo "unexpected output through julia-purifier env: $out" >&2
    exit 1
  }
)
# Adding a dependency needs the network, which Pkg has with
# JULIA_PKG_OFFLINE=false; the lockfile is then stale until a relock.
JULIA_PKG_OFFLINE=false "$cli" julia -e 'using Pkg; Pkg.add("Crayons")'
if "$cli" julia -e 'exit(0)' 2> "$work/loop-stale.log"; then
  echo "julia ran after a dependency was added without a relock" >&2
  exit 1
fi
grep -q 'julia-purifier lock' "$work/loop-stale.log"
"$cli" lock
"$cli" julia -e 'using Crayons; print(Crayon(foreground = :red))' > /dev/null
cd "$work"

echo "== 5. a damaged lockfile fails with a message"
# Builds the app's depot from a copy of the fixture with one edit, and
# checks that the build fails with the given message.
expect_failure() {
  local name="$1" pattern="$2"
  if NIX_JP_SRC="$work/$name" nix build --impure --no-link --expr "
    let
      f = builtins.getFlake \"path:$repo\";
      pkgs = import f.inputs.nixpkgs {
        system = builtins.currentSystem;
        overlays = [ f.overlays.default ];
      };
    in
    (pkgs.buildJuliaProject { src = /. + builtins.getEnv \"NIX_JP_SRC\"; }).depot
  " 2> "$work/$name.log"; then
    echo "$name: the build succeeded" >&2
    exit 1
  fi
  grep -q "$pattern" "$work/$name.log" || {
    echo "$name: the error does not mention '$pattern':" >&2
    cat "$work/$name.log" >&2
    exit 1
  }
}
damaged() {
  rm -rf "${work:?}/$1"
  cp -r "$repo/tests/fixtures/app" "$work/$1"
  chmod -R u+w "$work/$1"
}
# A tampered hash: the fetch of that tarball fails.
edit_lock() {
  nix shell 'nixpkgs#julia_113-bin' -c julia --startup-file=no "$repo/tests/edit-lock.jl" "$@"
}
damaged tampered
edit_lock "$work/tampered/julia-purifier.lock.toml" tamper JSON
expect_failure tampered "hash mismatch"
# A missing entry: the manifest pins JSON, and the lockfile has no source
# for it.
damaged missing
edit_lock "$work/missing/julia-purifier.lock.toml" drop JSON
expect_failure missing "has no source for JSON"
# A malformed lockfile.
damaged malformed
printf '[[downloads\n' >> "$work/malformed/julia-purifier.lock.toml"
expect_failure malformed "parsing TOML"
# A stale lockfile, found at evaluation.
damaged stale
printf '\n# an edit\n' >> "$work/stale/Project.toml"
expect_failure stale "julia-purifier lock"

echo "== 6. register records the committed tree"
cd "$work/app"
git init -q
git add -A
git commit -q -m "HelloPurifier 0.1.0"
# LocalRegistry records the package's repository from its remote.
git init -q --bare "$work/app.git"
git remote add origin "file://$work/app.git"
git push -q origin main
git init -q --bare "$work/registry.git"
JULIA_DEPOT_PATH="$work/registry-depot:" nix shell "$repo#julia-purifier" 'nixpkgs#julia_113-bin' -c \
  julia --startup-file=no "$repo/tests/create-registry.jl" "$work/registry" "file://$work/registry.git"
"$cli" register "file://$work/registry.git" --push "$work/app"
git clone -q "file://$work/registry.git" "$work/registry-check"
tree="$(git -C "$work/app" rev-parse 'HEAD^{tree}')"
grep -q "git-tree-sha1 = \"$tree\"" "$work/registry-check/H/HelloPurifier/Versions.toml"

echo "all julia-purifier command tests passed"
