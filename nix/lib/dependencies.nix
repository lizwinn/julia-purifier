# SPDX-License-Identifier: MIT
#
# The downloads of a lock, laid out as a tree: each entry's content lies at
# its `path`, as a link to its fixed-output fetch. The entries have the
# shapes of the shared purifier library:
#
#   { path, url, mirrors, hash }                       a file
#   { path, archive = { url, mirrors, stripTop }, hash } an unpacked archive
#   { path, git = { url, rev, submodules, leaveDotGit, commitObject }, hash }
#                                                      a checkout
#
# This file knows nothing of Julia. It takes entries of these shapes and
# nothing else.
{
  lib,
  runCommand,
  fetchurl,
  fetchgit,
  gnutar,
  gzip,
  zstd,
  # The download entries.
  downloads,
  # The name of the tree in the store.
  name ? "purifier-dependencies",
}:
let
  # A store name allows fewer characters than a URL; the last segment of
  # the URL, with the rest replaced, keeps the store listing readable.
  storeName =
    url:
    let
      base = lib.last (lib.splitString "/" (builtins.head (lib.splitString "?" url)));
      clean = lib.strings.sanitizeDerivationName base;
    in
    if clean == "" then "download" else clean;

  fetchFile =
    {
      url,
      mirrors,
      hash,
    }:
    fetchurl {
      urls = [ url ] ++ mirrors;
      inherit hash;
      name = storeName url;
    };

  unpack =
    d:
    let
      file = fetchFile {
        inherit (d.archive) url mirrors;
        inherit (d) hash;
      };
    in
    runCommand "${storeName d.archive.url}-unpacked"
      {
        nativeBuildInputs = [
          gnutar
          gzip
          zstd
        ];
      }
      ''
        mkdir unpacked
        tar -xf ${file} -C unpacked
        ${
          if d.archive.stripTop then
            ''
              shopt -s dotglob nullglob
              top=(unpacked/*)
              if [ "''${#top[@]}" -ne 1 ] || [ ! -d "''${top[0]}" ]; then
                echo "purifier: ${d.archive.url} has no single top-level directory to strip" >&2
                exit 1
              fi
              mv "''${top[0]}" "$out"
            ''
          else
            ''
              mv unpacked "$out"
            ''
        }
      '';

  fetch =
    d:
    if d ? git && d.git.leaveDotGit then
      # A checkout with its .git is rebuilt from `commitObject` by the
      # shared purifier library. Pkg installs a package from its tree, so
      # julia-purifier writes no such entry.
      throw
        "purifier: ${d.git.url} at ${d.git.rev} is an entry with leaveDotGit, which this copy of the library does not fetch"
    else if d ? git then
      fetchgit {
        inherit (d.git) url rev;
        inherit (d) hash;
        fetchSubmodules = d.git.submodules;
        leaveDotGit = d.git.leaveDotGit;
      }
    else if d ? archive then
      unpack d
    else
      fetchFile { inherit (d) url mirrors hash; };
in
runCommand name
  {
    # The tree holds only links.
    preferLocalBuild = true;
    allowSubstitutes = false;
    passAsFile = [ "links" ];
    links = lib.concatMapStrings (d: "${d.path}\t${fetch d}\n") downloads;
  }
  ''
    mkdir -p "$out"
    while IFS=$'\t' read -r path target; do
      mkdir -p "$out/$(dirname "$path")"
      ln -s "$target" "$out/$path"
    done < "$linksPath"
  ''
