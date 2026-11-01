# SPDX-License-Identifier: MIT
#
# `julia-purifier language-server`: runs LanguageServer.jl on stdin and
# stdout for a project, from the editor environment that
# `julia-purifier prefetch` realized.
#
# Usage: julia --project=<editor env> language-server.jl <project root> <store>
#
# The process runs with the prefetched depots in JULIA_DEPOT_PATH, so the
# server finds the project's dependencies there and needs no network.
# `store` is a writable directory for the server's index.
using LanguageServer

root, store = ARGS
mkpath(store)
runserver(stdin, stdout, root, nothing, store)
