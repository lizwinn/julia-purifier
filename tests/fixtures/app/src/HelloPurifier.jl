# SPDX-License-Identifier: MIT
#
# A fixture package. Its command prints a JSON object that uses each of
# its dependencies: JSON from the General registry, StringEncodings with
# its Libiconv_jll binary artifact, and Example from a git repository.
module HelloPurifier

using JSON: JSON
using StringEncodings: encode
using Example: hello

greeting(name) = JSON.json(
    Dict(
        "greeting" => hello(name),
        "utf16le" => length(encode(name, "UTF-16LE")),
    ),
)

function (@main)(args)
    println(greeting(isempty(args) ? "Nix" : first(args)))
    return 0
end

end
