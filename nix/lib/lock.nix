# SPDX-License-Identifier: MIT
#
# Reads a project's julia-purifier.lock.toml and Project.toml files at
# evaluation time. It returns
#
#   downloads   the package sources and, for `system`, the artifacts, as
#               download entries of the shared purifier library
#   links       where a package source inside a git checkout goes in the
#               depot, as { from, to }
#   builds      the depot paths of packages that have a deps/build.jl
#   tests       per project directory with a test target that Pkg tests in
#               a sandbox, the recorded Project.toml and Manifest.toml text
#   julia       the Julia version the lock was made with
#   manifest    the manifest file
#   projects    per project directory ("." for the root, then the members of
#               a workspace), the parsed Project.toml and `dir`
#   packages    the projects that are packages (with a name and a UUID), by
#               package name
#
# Evaluation fails, with a message naming the command that fixes it, when
#
#   - a file the lock was made from has changed since (the lock is stale)
#   - the manifest or a recorded test environment names a package the
#     lockfile has no source for (the lockfile was edited or truncated)
#   - the lockfile records no artifacts for `system`
{
  lib,
  src,
  system,
  lockFile ? src + "/julia-purifier.lock.toml",
  # The manifest, when it is not in `src`: Julia packages often keep their
  # Manifest.toml out of version control, beside the lockfile.
  manifestFile ? null,
}:
let
  relock = "run `julia-purifier lock` in the project to renew it";

  lock =
    if builtins.pathExists lockFile then
      builtins.fromTOML (builtins.readFile lockFile)
    else
      throw "julia-purifier: ${toString lockFile} does not exist; run `julia-purifier lock` in the project.";

  manifestName = builtins.head (
    builtins.filter (lib.hasPrefix "Manifest") (builtins.attrNames (lock.inputs or { }))
    ++ [ "Manifest.toml" ]
  );
  manifest = if manifestFile != null then manifestFile else src + "/${manifestName}";

  # The path of a file the lock was made from.
  inputPath = f: if f == manifestName then manifest else src + "/${f}";

  checked =
    if lock.version or null != 1 then
      throw "julia-purifier: ${toString lockFile} has format ${toString (lock.version or "?")}; this julia-purifier reads format 1, so ${relock}."
    else
      let
        stale = builtins.filter (
          f:
          !builtins.pathExists (inputPath f) || builtins.hashFile "sha256" (inputPath f) != lock.inputs.${f}
        ) (builtins.attrNames lock.inputs);
      in
      if stale != [ ] then
        throw "julia-purifier: ${lib.concatStringsSep ", " stale} changed since ${toString lockFile} was made; ${relock}."
      else
        lock;

  # Every package a manifest pins by tree hash needs a source in the depot.
  # The lockfile places it at packages/<Name>/<slug>, as a download or a
  # link; a manifest names a package by its name, so that is what is
  # checked.
  pinned =
    m:
    lib.concatLists (
      lib.mapAttrsToList (
        name: entries: map (_: name) (builtins.filter (e: e ? "git-tree-sha1" && !(e ? path)) entries)
      ) (m.deps or { })
    );
  placed = lib.unique (
    map (p: builtins.elemAt (lib.splitString "/" p) 1) (
      builtins.filter (lib.hasPrefix "packages/") (
        map (d: d.path) checked.downloads ++ map (k: k.to) (checked.links or [ ])
      )
    )
  );
  manifests = [
    (builtins.fromTOML (builtins.readFile manifest))
  ]
  ++ map (t: builtins.fromTOML t."Manifest.toml") (builtins.attrValues (checked.tests or { }));
  unplaced = lib.subtractLists placed (lib.unique (lib.concatMap pinned manifests));
  covered =
    if unplaced != [ ] then
      throw "julia-purifier: ${toString lockFile} has no source for ${lib.concatStringsSep ", " unplaced}, which the manifest pins; ${relock}."
    else
      checked;

  readProject =
    dir:
    builtins.fromTOML (builtins.readFile (src + "/${if dir == "." then "" else dir + "/"}Project.toml"))
    // {
      inherit dir;
    };

  root = readProject ".";
  # A workspace lists its members relative to the root, possibly with a
  # leading "./".
  memberDirs = map (lib.removePrefix "./") (root.workspace.projects or [ ]);
  projects = lib.listToAttrs (
    map (dir: lib.nameValuePair dir (readProject dir)) ([ "." ] ++ memberDirs)
  );

  packages = lib.listToAttrs (
    map (p: lib.nameValuePair p.name p) (
      builtins.filter (p: p ? name && p ? uuid) (builtins.attrValues projects)
    )
  );

  artifacts =
    covered.artifacts.${system}
      or (throw "julia-purifier: ${toString lockFile} records no artifacts for ${system}; the lock covers ${lib.concatStringsSep ", " (builtins.attrNames covered.artifacts)}.");
in
{
  # TOML has no null, so a git entry in the lockfile leaves out the
  # `commitObject` of the shared entry shape when it is null.
  downloads =
    map (
      d:
      if d ? git then
        d
        // {
          git = {
            commitObject = null;
          }
          // d.git;
        }
      else
        d
    ) covered.downloads
    ++ artifacts;
  links = covered.links or [ ];
  builds = covered.builds or [ ];
  tests = covered.tests or { };
  inherit (covered) julia;
  inherit
    manifest
    manifestName
    projects
    packages
    ;
}
