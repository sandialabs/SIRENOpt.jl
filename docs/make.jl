import Pkg
Pkg.activate(@__DIR__)
if get(ENV, "CI", "false") == "true" || get(ENV, "SIRENOPT_DOCS_RESOLVE", "false") == "true"
    Pkg.resolve()
    Pkg.instantiate()
end

using Documenter
using SIRENOpt

DocMeta.setdocmeta!(SIRENOpt, :DocTestSetup, :(using SIRENOpt); recursive = true)

function cached_package_roots(package_name)
    roots = String[]
    for depot in DEPOT_PATH
        package_dir = joinpath(depot, "packages", package_name)
        isdir(package_dir) || continue
        for slug in sort(readdir(package_dir))
            root = joinpath(package_dir, slug)
            isfile(joinpath(root, "Project.toml")) && push!(roots, root)
        end
    end
    return roots
end

function generate_literate_tutorials()
    source = joinpath(@__DIR__, "literate", "pendulum_platform_tutorial.jl")
    tutorial_dir = joinpath(@__DIR__, "src", "tutorials")
    generated_dir = joinpath(@__DIR__, "src", "generated", "pendulum_platform_tutorial")
    report_dir = joinpath(generated_dir, "reports")
    generated_page = joinpath(tutorial_dir, "pendulum_platform_tutorial.md")
    generated_notebook = joinpath(tutorial_dir, "pendulum_platform_tutorial.ipynb")

    mkpath(tutorial_dir)
    mkpath(generated_dir)
    mkpath(report_dir)

    original_load_path = copy(LOAD_PATH)
    original_gks = get(ENV, "GKSwstype", nothing)
    original_output_dir = get(ENV, "SIRENOPT_TUTORIAL_OUTPUT_DIR", nothing)
    original_report_dir = get(ENV, "SIRENOPT_TUTORIAL_REPORT_DIR", nothing)

    try
        cached_roots = vcat(
            cached_package_roots("Literate"),
            cached_package_roots("OptimizationParameters"),
        )
        for root in reverse(cached_roots)
            root in LOAD_PATH || pushfirst!(LOAD_PATH, root)
        end

        literate = Base.require(Base.PkgId(
            Base.UUID("98b081ad-f1c9-55d3-8b20-4c87d4299306"), "Literate"))
        documenter_flavor = Base.invokelatest(getfield(literate, :DocumenterFlavor))

        ENV["GKSwstype"] = "100"
        ENV["SIRENOPT_TUTORIAL_OUTPUT_DIR"] = generated_dir
        ENV["SIRENOPT_TUTORIAL_REPORT_DIR"] = report_dir

        Base.invokelatest(getfield(literate, :markdown), source, tutorial_dir;
            name = "pendulum_platform_tutorial",
            execute = true,
            credit = false,
            flavor = documenter_flavor,
        )
        Base.invokelatest(getfield(literate, :notebook), source, tutorial_dir;
            name = "pendulum_platform_tutorial",
            execute = true,
            credit = false,
        )
    catch err
        if isfile(generated_page) && isfile(generated_notebook)
            @warn "Could not regenerate Literate tutorial; using checked-in generated files" exception=(err, catch_backtrace())
        else
            rethrow()
        end
    finally
        empty!(LOAD_PATH)
        append!(LOAD_PATH, original_load_path)
        if original_gks === nothing
            delete!(ENV, "GKSwstype")
        else
            ENV["GKSwstype"] = original_gks
        end
        if original_output_dir === nothing
            delete!(ENV, "SIRENOPT_TUTORIAL_OUTPUT_DIR")
        else
            ENV["SIRENOPT_TUTORIAL_OUTPUT_DIR"] = original_output_dir
        end
        if original_report_dir === nothing
            delete!(ENV, "SIRENOPT_TUTORIAL_REPORT_DIR")
        else
            ENV["SIRENOPT_TUTORIAL_REPORT_DIR"] = original_report_dir
        end
    end
end

generate_literate_tutorials()

makedocs(
    sitename = "SIRENOpt.jl",
    modules = [SIRENOpt],
    remotes = nothing,
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        edit_link = "master",
        repolink = "https://github.com/sandialabs/SIRENOpt.jl",
    ),
    pages = [
        "Home" => "index.md",
        "Quick Start" => "quickstart.md",
        "Tutorials" => [
            "Pendulum Platform Ontology Tutorial" => "tutorials/pendulum_platform_tutorial.md",
        ],
        "Theory" => "theory.md",
        "Design Records" => [
            "Ontology V1 Conventions" => "design/ontology-v1-conventions.md",
            "Ontology Release Audit" => "design/ontology-release-audit.md",
        ],
        "API" => "api.md",
    ],
)

if get(ENV, "CI", "false") == "true"
    deploydocs(; repo = "github.com/sandialabs/SIRENOpt.jl.git", devbranch = "master")
end
