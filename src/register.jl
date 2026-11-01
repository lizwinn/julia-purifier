# SPDX-License-Identifier: MIT
#
# `julia-purifier register`: registers the version in a project's
# Project.toml in a registry, with LocalRegistry.jl.
#
# Usage: julia register.jl <project directory> <registry> [<push>]
#
# `registry` is the name of an installed registry or the URL of one. With
# `push` set to "push", LocalRegistry pushes the registry's new commit. The
# CLI runs this after Nix has built and tested the project from its
# lockfile, so the version a registry records is the source tree Nix built.
# The script runs in a fresh depot, where Pkg installs LocalRegistry.
using Pkg

project_dir, registry = ARGS[1], ARGS[2]
push = length(ARGS) >= 3 && ARGS[3] == "push"

Pkg.activate(; temp = true, io = devnull)
Pkg.add("LocalRegistry"; io = devnull)
using LocalRegistry

LocalRegistry.register(abspath(project_dir); registry, push)
