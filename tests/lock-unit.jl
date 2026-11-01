# SPDX-License-Identifier: MIT
#
# Unit tests for the lock run's parsing and path logic (src/lock.jl). They
# need git and no network, so the flake runs them in the sandbox.
#
# Usage: julia tests/lock-unit.jl
using Test, TOML
using Base: UUID, SHA1
using Base.BinaryPlatforms

include(joinpath(@__DIR__, "..", "src", "lock.jl"))
const L = JuliaPurifierLock

@testset "julia-purifier lock" begin
    @testset "fetchable_url" begin
        @test L.fetchable_url("https://github.com/a/b.jl") == "https://github.com/a/b.jl"
        @test L.fetchable_url("git://example.org/x.git") == "git://example.org/x.git"
        # The sandbox has no SSH keys, so an SSH URL becomes HTTPS.
        @test L.fetchable_url("git@github.com:a/b.jl.git") == "https://github.com/a/b.jl.git"
        @test L.fetchable_url("ssh://git@gitlab.com/g/p.git") == "https://gitlab.com/g/p.git"
        @test L.fetchable_url("ssh://user@host.example/p") == "https://host.example/p"
        # A local path cannot be fetched by a Nix build.
        @test_throws ErrorException L.fetchable_url("/home/me/Pkg.jl")
        @test_throws ErrorException L.fetchable_url("../Pkg.jl")
    end

    @testset "server_mirrors" begin
        # The tests run without JULIA_PKG_SERVER, so the server is the
        # public one, whose storage server is a mirror.
        @test L.SERVER == "https://pkg.julialang.org"
        @test L.server_mirrors("package/u/t") == ["https://storage.julialang.net/package/u/t"]
    end

    @testset "sri" begin
        @test L.sri("33d766a1d3ef0a6e2936439bd8bb4d3baf35ef59a0e378b5cb2dfed2c785f871") ==
            "sha256-M9dmodPvCm4pNkOb2LtNO68171mg43i1yy3+0seF+HE="
    end

    @testset "platform_of" begin
        p = L.platform_of("aarch64", "linux", "glibc")
        @test arch(p) == "aarch64"
        @test os(p) == "linux"
        @test libc(p) == "glibc"
        # The Julia version tag comes from the host, as Pkg selects by it.
        @test haskey(tags(p), "julia_version")
        d = L.platform_of("aarch64", "macos", nothing)
        @test os(d) == "macos"
        @test libc(d) === nothing
    end

    @testset "packages_of" begin
        manifest = TOML.parse(
            """
            julia_version = "1.13.2"
            manifest_format = "2.1"

            [[deps.Dates]]
            uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
            version = "1.11.0"

            [[deps.JSON]]
            git-tree-sha1 = "06d90f699285d055e34f0b014636a75a17ff2252"
            uuid = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
            version = "1.13.4"

            [[deps.Core2]]
            git-tree-sha1 = "483a96a3655c93e27cd7baaa0a00fcdda1f3fdec"
            repo-rev = "v3.2.9"
            repo-subdir = "Core2"
            repo-url = "https://github.com/a/b.jl"
            uuid = "e2b509da-e806-4183-be48-004708413034"
            version = "3.1.3"

            [[deps.Mine]]
            path = "Mine"
            uuid = "0d5a1c55-3f7b-4a6e-9a51-6c1f4f9e2b10"
            version = "1.0.0"
            """
        )
        pkgs = Dict(p.name => p for p in L.packages_of(manifest))
        # A standard library and a path package are not downloaded.
        @test sort(collect(keys(pkgs))) == ["Core2", "JSON"]
        @test pkgs["JSON"].repo === nothing
        @test pkgs["JSON"].tree == "06d90f699285d055e34f0b014636a75a17ff2252"
        @test pkgs["Core2"].repo == "https://github.com/a/b.jl"
        @test pkgs["Core2"].rev == "v3.2.9"
        @test pkgs["Core2"].subdir == "Core2"
    end

    @testset "entries" begin
        a = L.archive_entry("packages/X/abcde", "https://s/x", ["https://m/x"], "sha256-AA==")
        @test a == Dict(
            "path" => "packages/X/abcde",
            "archive" => Dict("url" => "https://s/x", "mirrors" => ["https://m/x"], "stripTop" => false),
            "hash" => "sha256-AA==",
        )
        g = L.git_entry(L.GitSource("https://h/r", "c0ffee", "sha256-BB=="))
        @test g["path"] == "git/c0ffee"
        @test g["git"] == Dict(
            "url" => "https://h/r", "rev" => "c0ffee", "submodules" => false, "leaveDotGit" => false,
        )
    end

    @testset "find_commit" begin
        dir = mktempdir()
        git(args...) = run(pipeline(`git -C $dir -c user.name=t -c user.email=t@t $args`; stdout = devnull))
        git("init", "-q")
        mkpath(joinpath(dir, "Sub"))
        write(joinpath(dir, "Sub", "a.jl"), "1")
        write(joinpath(dir, "top.jl"), "1")
        git("add", "-A")
        git("commit", "-q", "-m", "one")
        first_commit = L.run_out(`git -C $dir rev-parse HEAD`)
        first_tree = L.run_out(`git -C $dir rev-parse HEAD^\{tree\}`)
        first_sub = L.run_out(`git -C $dir rev-parse HEAD:Sub`)
        write(joinpath(dir, "Sub", "a.jl"), "2")
        git("commit", "-q", "-am", "two")
        git("tag", "v2")
        second_commit = L.run_out(`git -C $dir rev-parse HEAD`)
        second_sub = L.run_out(`git -C $dir rev-parse HEAD:Sub`)

        # By the manifest's revision first, then by searching every commit.
        @test L.find_commit(dir, first_tree, nothing, nothing) == first_commit
        @test L.find_commit(dir, second_sub, "v2", "Sub") == second_commit
        @test L.find_commit(dir, first_sub, "v2", "Sub") == first_commit
        @test L.find_commit(dir, first_sub, nothing, "Sub") == first_commit
        @test_throws ErrorException L.find_commit(dir, "0"^40, nothing, nothing)
    end
end
