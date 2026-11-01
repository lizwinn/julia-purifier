# SPDX-License-Identifier: MIT
#
# `julia-purifier lock`: records every file Pkg downloads for a project, so
# that Nix can build the project offline in its sandbox.
#
# Usage: julia lock.jl <project directory>
#
# The script runs with the network, in the fresh depot that DEPOT_PATH[1]
# names. It instantiates the project there, resolves each test environment
# Pkg would create for `Pkg.test`, and writes julia-purifier.lock.toml beside
# the manifest. The lockfile holds:
#
#   downloads   the package sources, as the shared purifier library's
#               archive entries (a tarball from the package server) and git
#               entries (a checkout of the repository a package came from)
#   links       where a package source inside a git checkout goes in the
#               depot, as { from, to }
#   artifacts   per Nix system, the artifacts the packages need on that
#               system, as archive entries
#   builds      the depot paths of packages with a deps/build.jl
#   tests       per project with a test target, the Project.toml and
#               Manifest.toml of the environment Pkg.test runs in
#   inputs      the SHA-256 of each file the lock was made from, so that a
#               build notices a stale lockfile
module JuliaPurifierLock

using Pkg, TOML, SHA, Downloads, Base64
using Base: UUID, SHA1
using Base.BinaryPlatforms

# The package server Pkg downloads from: JULIA_PKG_SERVER when it is set, as
# Pkg itself reads it, and the public server otherwise. The public servers
# redirect to one storage server, which serves the same bytes, so that is a
# mirror of every public download.
const PUBLIC_SERVER = "https://pkg.julialang.org"
const SERVER = let s = get(ENV, "JULIA_PKG_SERVER", "")
    isempty(s) ? PUBLIC_SERVER : rstrip(occursin("://", s) ? s : "https://" * s, '/')
end
const STORAGE = "https://storage.julialang.net"
server_mirrors(path) = SERVER == PUBLIC_SERVER ? ["$STORAGE/$path"] : String[]

# The Nix systems the lock covers, as (arch, os, libc).
const SYSTEMS = [
    "x86_64-linux" => ("x86_64", "linux", "glibc"),
    "aarch64-linux" => ("aarch64", "linux", "glibc"),
    "aarch64-darwin" => ("aarch64", "macos", nothing),
]

# A recorded test environment names the project root by this path,
# relative to the environment's own directory. A build places the
# environment in a directory `env` and links `root` beside it to the
# project's source.
const ROOT = "../root"

sri(hex) = "sha256-" * base64encode(hex2bytes(hex))

function sha256_url(url)
    file = Downloads.download(url)
    try
        return bytes2hex(open(sha256, file))
    finally
        rm(file; force = true)
    end
end

# The platform of a Nix system, with the host's remaining tags (the Julia
# version, the libgfortran version and the C++ string ABI), which are the
# same for one Julia version on every system.
function platform_of(arch, os, libc)
    extra = Dict{Symbol, String}()
    for (k, v) in tags(HostPlatform())
        k in ("arch", "os", "libc", "call_abi", "os_version") && continue
        extra[Symbol(k)] = v
    end
    libc === nothing || (extra[:libc] = libc)
    return Platform(arch, os; extra...)
end

run_out(cmd) = strip(read(cmd, String))

# A git URL the sandbox can fetch: it has no SSH keys, so an SSH URL becomes
# the HTTPS URL of the same host and path, which is what most hosts serve.
function fetchable_url(url)
    m = match(r"^(?:ssh://)?git@([^:/]+)[:/](.+)$", url)
    m !== nothing && return "https://$(m[1])/$(m[2])"
    m = match(r"^ssh://(?:[^@/]+@)?([^/]+)/(.+)$", url)
    m !== nothing && return "https://$(m[1])/$(m[2])"
    if !occursin(r"^(https?|git)://", url)
        error("julia-purifier: the package repository $(repr(url)) is not a URL a Nix build can fetch")
    end
    return url
end

# The NAR hash of a directory, as nix-prefetch-git reports it for a
# checkout without .git.
nar_hash(dir) = run_out(`nix-hash --type sha256 --sri $dir`)

struct GitSource
    url::String
    commit::String
    hash::String
end

const CLONES = Dict{String, String}()

function clone(url, work)
    get!(CLONES, url) do
        dir = joinpath(work, "clones", bytes2hex(sha256(url)))
        if !isdir(dir)
            run(`git clone --quiet --no-checkout $url $dir`)
        end
        dir
    end
end

# The tree of a commit, or of a subdirectory in it.
function tree_of(dir, commit, subdir)
    spec = subdir === nothing ? "$commit^{tree}" : "$commit:$subdir"
    return try
        run_out(pipeline(`git -C $dir rev-parse --verify --quiet $spec`; stderr = devnull))
    catch
        ""
    end
end

# The commit whose tree (or whose `subdir`) is the package's tree. The
# manifest's revision is tried first; otherwise every commit is.
function find_commit(dir, tree, rev, subdir)
    candidates = String[]
    if rev !== nothing
        spec = "$rev^{commit}"
        c = try
            run_out(pipeline(`git -C $dir rev-parse --verify --quiet $spec`; stderr = devnull))
        catch
            ""
        end
        isempty(c) || push!(candidates, c)
    end
    for c in candidates
        tree_of(dir, c, subdir) == tree && return c
    end
    if subdir === nothing
        for line in eachline(`git -C $dir log --all --format=%H\ %T`)
            c, t = split(line)
            t == tree && return String(c)
        end
    else
        for c in eachline(`git -C $dir rev-list --all`)
            tree_of(dir, c, subdir) == tree && return c
        end
    end
    error("julia-purifier: no commit of $(dir) has the tree $(tree)$(subdir === nothing ? "" : " in $subdir")")
end

const CHECKOUTS = Dict{Tuple{String, String}, GitSource}()

function git_source(url, tree, rev, subdir, work)
    fetch_url = fetchable_url(url)
    dir = clone(url, work)
    commit = find_commit(dir, tree, rev, subdir)
    get!(CHECKOUTS, (fetch_url, commit)) do
        checkout = joinpath(work, "checkouts", commit)
        if !isdir(checkout)
            run(`git -C $dir worktree add --quiet --detach $checkout $commit`)
        end
        # The hash is that of the checkout without .git, which is what
        # nixpkgs' fetchgit produces with leaveDotGit off.
        copy = joinpath(work, "hashed", commit)
        rm(copy; recursive = true, force = true)
        mkpath(dirname(copy))
        cp(checkout, copy)
        rm(joinpath(copy, ".git"); recursive = true, force = true)
        GitSource(fetch_url, commit, nar_hash(copy))
    end
end

git_entry(src::GitSource) = Dict(
    "path" => "git/$(src.commit)",
    "git" => Dict(
        "url" => src.url,
        "rev" => src.commit,
        "submodules" => false,
        "leaveDotGit" => false,
    ),
    "hash" => src.hash,
)

archive_entry(path, url, mirrors, hash) = Dict(
    "path" => path,
    "archive" => Dict("url" => url, "mirrors" => mirrors, "stripTop" => false),
    "hash" => hash,
)

# The repository and subdirectory a registry names for a package, for
# packages the package server does not serve (those of other registries).
function registry_repo(uuid)
    for reg in Pkg.Registry.reachable_registries()
        haskey(reg, uuid) || continue
        info = Pkg.Registry.registry_info(reg[uuid])
        info.repo === nothing && continue
        return (info.repo, info.subdir)
    end
    return nothing
end

server_has(url) = try
    Downloads.request(url; method = "HEAD", throw = false).status == 200
catch
    false
end

# One package of a manifest: its name, UUID, tree hash and git origin.
struct Package
    name::String
    uuid::UUID
    tree::String
    repo::Union{Nothing, String}
    rev::Union{Nothing, String}
    subdir::Union{Nothing, String}
end

# The packages of a parsed manifest (format 2) that come from elsewhere:
# those with a tree hash. Packages with a path are part of the source, and
# standard libraries come with Julia.
function packages_of(manifest::Dict)
    out = Package[]
    for (name, entries) in get(manifest, "deps", Dict())
        for e in entries
            haskey(e, "git-tree-sha1") || continue
            haskey(e, "path") && continue
            push!(
                out, Package(
                    name, UUID(e["uuid"]), e["git-tree-sha1"],
                    get(e, "repo-url", nothing), get(e, "repo-rev", nothing),
                    get(e, "repo-subdir", nothing),
                )
            )
        end
    end
    return out
end

struct Captured <: Exception end

# The environment Pkg.test runs a project's tests in. Pkg calls `test_fn`
# inside its sandbox, with the sandbox's project active; the function copies
# the project and manifest and stops before the tests run.
function test_environment(project_dir)
    captured = Dict{String, String}()
    capture = function ()
        proj = Base.active_project()
        captured["Project.toml"] = read(proj, String)
        captured["Manifest.toml"] = read(Base.project_file_manifest_path(proj), String)
        throw(Captured())
    end
    Pkg.activate(project_dir; io = devnull)
    try
        Pkg.test(; test_fn = capture)
    catch e
        isempty(captured) && rethrow()
    end
    return captured
end

has_test_target(project) =
    haskey(get(project, "targets", Dict()), "test") ||
    isfile(joinpath(project["__dir"], "test", "Project.toml"))

function read_project(dir)
    p = TOML.parsefile(joinpath(dir, "Project.toml"))
    p["__dir"] = dir
    return p
end

relpath_or_dot(path, root) = (r = relpath(path, root); r == "." ? "." : r)

function main(project_arg)
    root = abspath(project_arg)
    work = mktempdir()
    ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"

    Pkg.activate(root; io = devnull)
    ctx = Pkg.Types.Context()
    manifest_file = ctx.env.manifest_file
    # Julia packages often keep no manifest in version control. The lock
    # needs one, so it resolves the project and writes it.
    if !isfile(manifest_file)
        @info "julia-purifier: $(root) has no manifest; resolving the project to write $(basename(manifest_file))"
        # The lock's depot is fresh, and Pkg.resolve, unlike
        # Pkg.instantiate, does not install the default registries.
        Pkg.Registry.add()
        Pkg.resolve()
        ctx = Pkg.Types.Context()
        manifest_file = ctx.env.manifest_file
    end
    root = dirname(manifest_file)
    manifest = TOML.parsefile(manifest_file)

    jv = VersionNumber(get(manifest, "julia_version", string(VERSION)))
    if (jv.major, jv.minor) != (VERSION.major, VERSION.minor)
        error("julia-purifier: the manifest is for Julia $(jv); run the lock with Julia $(jv.major).$(jv.minor)")
    end

    # The projects of the environment: the root and, in a workspace, its
    # members.
    project_dirs = [root]
    for p in get(get(TOML.parsefile(joinpath(root, "Project.toml")), "workspace", Dict()), "projects", String[])
        push!(project_dirs, normpath(joinpath(root, p)))
    end
    workspace_dirs = Set(project_dirs)

    # Pkg instantiates what the active project reaches, so each project of
    # a workspace is instantiated on its own.
    for dir in project_dirs
        @info "julia-purifier: instantiating $(dir)"
        Pkg.activate(dir; io = devnull)
        Pkg.instantiate()
    end

    # Each package with a test target whose tests run in a sandbox, rather
    # than in a test project of the workspace.
    tests = Dict{String, Any}()
    packages = packages_of(manifest)
    for dir in project_dirs
        project = read_project(dir)
        haskey(project, "uuid") || continue
        has_test_target(project) || continue
        normpath(joinpath(dir, "test")) in workspace_dirs && continue
        @info "julia-purifier: resolving the test environment of $(project["name"])"
        env = test_environment(dir)
        for (k, v) in env
            env[k] = replace(v, root => ROOT)
        end
        # The manifest's project hash depends on where the project lies, so
        # the build computes it (nix/lib/project-hash.jl) and the lock
        # leaves it out.
        env["Manifest.toml"] = replace(env["Manifest.toml"], r"^project_hash = .*\n"m => "")
        tests[relpath_or_dot(dir, root)] = env
        append!(packages, packages_of(TOML.parse(env["Manifest.toml"])))
    end
    Pkg.activate(root; io = devnull)

    downloads = Dict{String, Any}()
    links = Dict{String, String}()
    builds = String[]
    artifacts = Dict(system => Dict{String, Any}() for (system, _) in SYSTEMS)
    seen = Set{Tuple{UUID, String}}()

    for pkg in packages
        (pkg.uuid, pkg.tree) in seen && continue
        push!(seen, (pkg.uuid, pkg.tree))
        tree = SHA1(pkg.tree)
        slug = Base.version_slug(pkg.uuid, tree)
        path = "packages/$(pkg.name)/$(slug)"
        installed = Pkg.Operations.find_installed(pkg.name, pkg.uuid, tree)
        isdir(installed) || error("julia-purifier: Pkg did not install $(pkg.name) at $(installed)")

        url = "$SERVER/package/$(pkg.uuid)/$(pkg.tree)"
        repo = pkg.repo
        subdir = pkg.subdir
        if repo === nothing && !server_has(url)
            r = registry_repo(pkg.uuid)
            r === nothing && error("julia-purifier: neither the package server nor a registry has $(pkg.name) at $(pkg.tree)")
            repo, subdir = r
        end
        if repo === nothing
            @info "julia-purifier: hashing $(pkg.name)"
            downloads[path] = archive_entry(
                path, url, server_mirrors("package/$(pkg.uuid)/$(pkg.tree)"), sri(sha256_url(url))
            )
        else
            @info "julia-purifier: locating $(pkg.name) in $(repo)"
            src = git_source(repo, pkg.tree, pkg.rev, subdir, work)
            entry = git_entry(src)
            downloads[entry["path"]] = entry
            links[path] = subdir === nothing ? entry["path"] : "$(entry["path"])/$(subdir)"
        end

        isfile(joinpath(installed, "deps", "build.jl")) && push!(builds, path)

        for (system, (arch, os, libc)) in SYSTEMS
            platform = platform_of(arch, os, libc)
            for (_, selected) in Pkg.Operations.collect_artifacts(installed; platform, include_lazy = true)
                for (name, meta) in selected
                    art_tree = meta["git-tree-sha1"]
                    art_path = "artifacts/$(art_tree)"
                    haskey(artifacts[system], art_path) && continue
                    dls = get(meta, "download", Any[])
                    artifacts[system][art_path] = if isempty(dls)
                        a_url = "$SERVER/artifact/$(art_tree)"
                        archive_entry(art_path, a_url, server_mirrors("artifact/$(art_tree)"), sri(sha256_url(a_url)))
                    else
                        first_dl = dls[1]
                        mirrors = [d["url"] for d in dls[2:end] if d["sha256"] == first_dl["sha256"]]
                        archive_entry(art_path, first_dl["url"], mirrors, sri(first_dl["sha256"]))
                    end
                end
            end
        end
    end

    # The artifacts Pkg installed on this host are the ones the lock
    # recorded for it; a package whose artifact selection differs (through a
    # platform augmentation hook) would show up here.
    host = [s for (s, (arch, os, _)) in SYSTEMS if arch == string(Sys.ARCH) && os == (Sys.isapple() ? "macos" : "linux")]
    installed_artifacts = joinpath(DEPOT_PATH[1], "artifacts")
    if !isempty(host) && isdir(installed_artifacts)
        for t in readdir(installed_artifacts)
            occursin(r"^[0-9a-f]{40}$", t) || continue
            haskey(artifacts[host[1]], "artifacts/$t") ||
                error("julia-purifier: Pkg installed the artifact $t, which the lock did not select for $(host[1])")
        end
    end

    inputs = Dict{String, String}()
    for f in [manifest_file; [joinpath(d, "Project.toml") for d in project_dirs]]
        isfile(f) && (inputs[relpath(f, root)] = bytes2hex(open(sha256, f)))
    end

    lock = Dict(
        "version" => 1,
        "julia" => string(VERSION),
        "inputs" => inputs,
        "downloads" => [downloads[k] for k in sort(collect(keys(downloads)))],
        "links" => [Dict("from" => links[k], "to" => k) for k in sort(collect(keys(links)))],
        "builds" => sort(builds),
        "artifacts" => Dict(s => [a[k] for k in sort(collect(keys(a)))] for (s, a) in artifacts),
        "tests" => tests,
    )
    out = joinpath(root, "julia-purifier.lock.toml")
    open(out, "w") do io
        println(io, "# This file is written by `julia-purifier lock`. Commit it beside the manifest.")
        TOML.print(io, lock; sorted = true)
    end
    @info "julia-purifier: wrote $(out)"
    return
end

end

# tests/lock-unit.jl includes this file for its functions; run as a
# program, it locks the project.
if abspath(PROGRAM_FILE) == @__FILE__
    JuliaPurifierLock.main(isempty(ARGS) ? "." : ARGS[1])
end
