# SPDX-License-Identifier: MIT
#
# A library member of the workspace fixture. It uses Example from the
# General registry and SnoopCompileCore from a subdirectory of the
# SnoopCompile.jl repository.
module Greeting

using Example: hello
using SnoopCompileCore: SnoopCompileCore

greet(name) = hello(name) * " (SnoopCompileCore loaded: $(isdefined(SnoopCompileCore, Symbol("@snoop_inference"))))"

end
