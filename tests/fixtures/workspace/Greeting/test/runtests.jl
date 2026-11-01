# SPDX-License-Identifier: MIT
using Test
using Greeting

@testset "Greeting" begin
    @test Greeting.greet("x") == "Hello, x (SnoopCompileCore loaded: true)"
end
