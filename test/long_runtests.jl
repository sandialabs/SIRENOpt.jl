using Test

if get(ENV, "SIRENOPT_RUN_LONG_TESTS", "0") != "1"
    @info "Skipping SIRENOpt long tests; set SIRENOPT_RUN_LONG_TESTS=1 to run them."
else
    include(joinpath(@__DIR__, "..", "examples", "multilevel_collocation_hybrid_demo.jl"))
    include(joinpath(@__DIR__, "..", "examples", "sirenolite_comparison_fixture.jl"))

    @testset "SIRENOpt long ontology examples" begin
        report_root = mktempdir()

        multilevel = run_multilevel_collocation_hybrid_demo(
            report_dir = joinpath(report_root, "multilevel_daily"),
            long_horizon = true)
        @test length(multilevel.optimization.timeseries) == 24
        @test multilevel.optimization.replay_summary.feasible
        @test multilevel.optimization.replay_summary.max_registered_constraint_violation <= 1e-8
        @test isfile(multilevel.acceptance_reports.level3_reliability_bins)

        comparison = run_sirenolite_comparison_fixture(
            report_dir = joinpath(report_root, "sirenolite_comparison"),
            horizon_s = 900.0,
            dt_s = 60.0)
        @test comparison.ontology_result.replay_summary.feasible
        @test comparison.ontology_result.replay_summary.max_registered_constraint_violation <= 1e-8
        @test isfile(comparison.reports.metrics)
        @test isfile(comparison.reports.difference)
    end
end
