# SPDX-License-Identifier: MIT
#
# `julia-purifier publish`: registers the version of each package of a
# project in a registry, with LocalRegistry.jl.
#
# Usage: julia publish.jl <registry> <push> <project directory>...
#
# `registry` is the name of an installed registry or the URL of one. With
# `push` set to "push", LocalRegistry pushes the registry's new commit. The
# command runs this after Nix has built the project's `release` from its
# committed tree, with the tests passing, and after it has checked that the
# tree hash of each released package is the tree it registers. The script
# runs in a fresh depot, where Pkg installs LocalRegistry.
using Pkg

registry, push = ARGS[1], ARGS[2] == "push"
dirs = ARGS[3:end]

Pkg.activate(; temp = true, io = devnull)
Pkg.add("LocalRegistry"; io = devnull)
using LocalRegistry

for dir in dirs
    LocalRegistry.register(abspath(dir); registry, push)
end
