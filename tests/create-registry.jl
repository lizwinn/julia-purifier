# SPDX-License-Identifier: MIT
#
# Creates an empty registry with LocalRegistry.jl and pushes it to a bare
# git repository, for tests/cli.sh to register a package in.
#
# Usage: julia create-registry.jl <directory> <bare repository URL>
using Pkg
Pkg.activate(; temp = true, io = devnull)
Pkg.add("LocalRegistry"; io = devnull)
using LocalRegistry

dir, url = ARGS
create_registry(dir, url; description = "julia-purifier test registry", push = true)
