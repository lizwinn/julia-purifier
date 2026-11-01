# SPDX-License-Identifier: MIT
#
# The command member of the workspace fixture: it greets through the
# Greeting member.
module Greeter

using Greeting: greet

function (@main)(args)
    println(greet(isempty(args) ? "workspace" : first(args)))
    return 0
end

end
