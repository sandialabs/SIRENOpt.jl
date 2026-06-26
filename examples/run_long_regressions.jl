using Dates

include(joinpath(@__DIR__, "multilevel_collocation_hybrid_demo.jl"))
include(joinpath(@__DIR__, "sirenolite_comparison_fixture.jl"))

"""
Run opt-in long ontology examples and paper-regression fixtures.

From the SIRENOpt.jl checkout:

    SIRENOPT_RUN_LONG_TESTS=1 julia --project=. examples/run_long_regressions.jl

The script refuses to run unless `SIRENOPT_RUN_LONG_TESTS=1` is set. It writes
all artifacts under `examples/results/long_regressions` by default.
"""
function run_long_regressions(;
        report_dir = joinpath(@__DIR__, "results", "long_regressions"))
    get(ENV, "SIRENOPT_RUN_LONG_TESTS", "0") == "1" ||
        throw(ArgumentError("Set SIRENOPT_RUN_LONG_TESTS=1 to run long regressions."))

    mkpath(report_dir)
    provenance = joinpath(report_dir, "long_regression_provenance.txt")
    open(provenance, "w") do io
        println(io, "generated_at=", Dates.now())
        println(io, "command=SIRENOPT_RUN_LONG_TESTS=1 julia --project=. examples/run_long_regressions.jl")
        println(io, "purpose=opt-in long ontology examples and paper-regression inputs")
    end

    multilevel = run_multilevel_collocation_hybrid_demo(
        report_dir = joinpath(report_dir, "multilevel_daily"),
        long_horizon = true)
    comparison = run_sirenolite_comparison_fixture(
        report_dir = joinpath(report_dir, "sirenolite_comparison"),
        horizon_s = 900.0,
        dt_s = 60.0)

    summary = joinpath(report_dir, "long_regression_summary.csv")
    open(summary, "w") do io
        println(io, "case,feasible,max_registered_constraint_violation,primary_report")
        println(io, join((
            "multilevel_daily",
            multilevel.optimization.replay_summary.feasible,
            multilevel.optimization.replay_summary.max_registered_constraint_violation,
            multilevel.acceptance_reports.level3_reliability_bins,
        ), ","))
        println(io, join((
            "sirenolite_comparison",
            comparison.ontology_result.replay_summary.feasible,
            comparison.ontology_result.replay_summary.max_registered_constraint_violation,
            comparison.reports.metrics,
        ), ","))
    end

    return (
        report_dir = report_dir,
        provenance = provenance,
        summary = summary,
        multilevel = multilevel,
        comparison = comparison,
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_long_regressions()
    println("long regression summary: ", result.summary)
end
