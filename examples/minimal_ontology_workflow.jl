using SIRENOpt

"""
Run the V1 minimal ontology workflow.

From the SIRENOpt.jl checkout:

    julia --project=. examples/minimal_ontology_workflow.jl
"""
function run_minimal_ontology_workflow(; report_dir = joinpath(@__DIR__, "results", "minimal_ontology_workflow"))
    scenario = ShortHorizonScenario(
        horizon_s = 2 * 3600.0,
        dt_s = 3600.0,
        solar_irradiance_kw_per_m2 = [0.6, 0.2],
        load_kw = [1.0, 1.0],
        initial_battery_soc = 0.7,
    )
    system = MinimalEnergyOntology(
        scenario = scenario,
        solar_area_m2 = 10.0,
        solar_converter_rating_kw = 10.0,
        battery_capacity_kwh = 5.0,
        battery_power_kw = 3.0,
        load_converter_rating_kw = 10.0,
    )

    description = describe(system)
    system_audit = audit(system, scenario; formulation = Collocation())
    simulation = simulate(system, scenario; controller = RuleBasedController())
    optimization = optimize(system, scenario; formulation = Collocation())
    replayed = replay(optimization)
    reported = report(optimization, report_dir)

    return (
        system = system,
        scenario = scenario,
        description = description,
        audit = system_audit,
        simulation = simulation,
        optimization = optimization,
        replay = replayed,
        report = reported,
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_minimal_ontology_workflow()
    println("ontology: ", result.system.ontology.name)
    println("blocks: ", length(result.description.component_table))
    println("variables: ", length(result.audit.variable_table))
    println("residuals: ", length(result.audit.residual_table))
    println("simulation replay: ", result.simulation.replay_summary)
    println("optimization replay: ", result.optimization.replay_summary)
    println("report files:")
    for path in result.report.reports
        println("  ", path)
    end
end
