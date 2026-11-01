# SPDX-License-Identifier: MIT
#
# Damages a lockfile for the negative tests in tests/cli.sh.
#
# Usage: julia edit-lock.jl <lockfile> drop <package name>
#        julia edit-lock.jl <lockfile> tamper <package name>
#
# `drop` removes the download entry of the package; `tamper` replaces the
# hash of that entry with the hash of an empty file.
using TOML

file, action, name = ARGS
lock = TOML.parsefile(file)
ofpackage(d) = startswith(d["path"], "packages/$name/")
if action == "drop"
    lock["downloads"] = [d for d in lock["downloads"] if !ofpackage(d)]
elseif action == "tamper"
    for d in lock["downloads"]
        ofpackage(d) && (d["hash"] = "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=")
    end
else
    error("unknown action $action")
end
open(io -> TOML.print(io, lock; sorted = true), file, "w")
