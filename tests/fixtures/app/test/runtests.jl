# SPDX-License-Identifier: MIT
using Test
using OrderedCollections: OrderedDict
using HelloPurifier

@testset "HelloPurifier" begin
    @test HelloPurifier.greeting("x") == "{\"greeting\":\"Hello, x\",\"utf16le\":2}"
    # OrderedCollections is a test-only dependency, from [extras].
    @test collect(keys(OrderedDict("b" => 1, "a" => 2))) == ["b", "a"]
end
