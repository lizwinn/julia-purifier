# SPDX-License-Identifier: MIT
#
# Damages a lockfile for the negative tests in tests/cli.sh, and writes it
# with a correct content hash, as a lock run would.
#
# Usage: julia edit-lock.jl <lockfile> <manifest> drop <package name>
#        julia edit-lock.jl <lockfile> <manifest> tamper <package name>
#
# The package is found by its tree hash in the manifest. `drop` removes the
# hash of its tarball from the lockfile; `tamper` replaces it with the hash
# of an empty file.
include(joinpath(@__DIR__, "..", "src", "lock.jl"))
using TOML
const L = JuliaPurifierLock

file, manifest, action, name = ARGS
tree = TOML.parsefile(manifest)["deps"][name][1]["git-tree-sha1"]
lock = L.parse_json(read(file, String))
haskey(lock["packages"], tree) || error("the lockfile has no tarball of $name")
if action == "drop"
    delete!(lock["packages"], tree)
elseif action == "tamper"
    lock["packages"][tree] = "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
else
    error("unknown action $action")
end
write(file, L.lock_text(lock))
