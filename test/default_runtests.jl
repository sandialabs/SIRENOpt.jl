using Test
using LinearAlgebra
using SIRENOpt
using PVlib
using ForwardDiff
using FiniteDiff
using Random

const T = Float64

@testset "Latin hypercube sampling" begin
    lower = [0.0, -2.0, 5.0]
    upper = [1.0, 2.0, 5.0]
    n_samples = 8

    samples = latin_hypercube(lower, upper, n_samples; rng = MersenneTwister(42))
    @test size(samples) == (n_samples, length(lower))
    @test all(samples[:, 1] .>= lower[1])
    @test all(samples[:, 1] .<= upper[1])
    @test all(samples[:, 2] .>= lower[2])
    @test all(samples[:, 2] .<= upper[2])
    @test all(samples[:, 3] .== upper[3])

    for j in 1:2
        scaled = (samples[:, j] .- lower[j]) ./ (upper[j] - lower[j])
        strata = sort(floor.(Int, scaled .* n_samples))
        @test strata == collect(0:(n_samples - 1))
    end

    centered = latin_hypercube([0.0], [1.0], 4; rng = MersenneTwister(1), centered = true)
    @test sort(vec(centered)) ≈ [0.125, 0.375, 0.625, 0.875]

    alias_samples = lhyper(lower, upper; n_samples = 5, rng = MersenneTwister(7))
    @test size(alias_samples) == (5, 3)

    default_samples = lhyper(lower, upper; rng = MersenneTwister(9))
    @test size(default_samples) == (30, 3)

    @test_throws DimensionMismatch latin_hypercube([0.0], [1.0, 2.0], 4)
    @test_throws ArgumentError latin_hypercube([0.0], [1.0], 0)
    @test_throws ArgumentError latin_hypercube([2.0], [1.0], 4)
    @test_throws ArgumentError latin_hypercube([-Inf], [1.0], 4)
end

@testset "Ontology V1 minimal workflow" begin
    scenario = ShortHorizonScenario(
        horizon_s = 2 * 3600.0,
        dt_s = 3600.0,
        solar_irradiance_kw_per_m2 = [0.6, 0.2],
        wind_speed_m_s = [8.0, 8.0],
        wave_power_flux_kw_per_m = [1.0, 1.0],
        load_kw = [1.0, 1.0],
        initial_battery_soc = 0.7,
    )
    system = MinimalEnergyOntology(scenario = scenario, solar_area_m2 = 10.0,
        battery_capacity_kwh = 5.0, battery_power_kw = 3.0)

    @test isvalid(system.validation)
    desc = describe(system)
    @test desc.ontology == :MinimalEnergyOntology
    @test Set(row.name for row in desc.component_table) ==
        Set([:solar_resource, :solar_array, :solar_converter, :battery,
            :battery_converter, :load, :bus])
    @test any(row -> row.name == :battery_capacity_kwh && row.unit == "kWh",
        desc.design_defaults)

    aud = audit(system, scenario; formulation = Collocation())
    @test any(row -> row.source == Symbol("solar_converter.bus_electrical") &&
        row.sink == Symbol("bus.bus_electrical"), aud.connection_table)
    @test any(row -> row.owner == :bus && row.name == :bus_power_balance &&
        row.unit == "kW", aud.residual_table)
    @test any(row -> row.owner == :battery && row.name == :battery_soc &&
        row.time_index == 1, aud.variable_table)
    @test all(row -> row.initial == scenario.initial_states.battery_soc,
        filter(row -> row.owner == :battery && row.name == :battery_soc,
            aud.variable_table))
    @test all(row -> row.model_path in (:prescribed, :surrogate, :hard_residual),
        aud.model_path_table)

    model = assemble(system, scenario, Collocation())
    @test length(model.x0) == length(model.lower_bounds) == length(model.upper_bounds)
    @test length(model.constraint_lower_bounds) == length(model.constraint_upper_bounds)
    @test length(evaluate_constraints(model, model.x0)) == length(model.constraint_lower_bounds)
    constraint_violation(model, x) = maximum(max.(model.constraint_lower_bounds .- evaluate_constraints(model, x),
        evaluate_constraints(model, x) .- model.constraint_upper_bounds))
    equality_residual(model, x) = maximum(abs(evaluate_constraints(model, x)[i])
        for i in eachindex(model.constraint_lower_bounds)
        if model.constraint_lower_bounds[i] == 0.0 && model.constraint_upper_bounds[i] == 0.0)
    shifted_x0 = model.x0 .+ 0.01
    constraint_jac = ForwardDiff.jacobian(x -> evaluate_constraints(model, x), shifted_x0)
    @test size(constraint_jac) == (length(model.constraint_lower_bounds), length(model.x0))
    @test all(isfinite, constraint_jac)
    @test any(trace -> occursin("bus.bus_power_balance", trace), model.callback_trace)

    sim = simulate(system, scenario; controller = RuleBasedController())
    @test sim.replay_summary.feasible
    @test sim.replay_summary.max_abs_bus_balance_residual_kw < 1e-8
    @test sim.replay_summary.max_abs_battery_inventory_residual_kwh < 1e-8

    opt = optimize(system, scenario; formulation = Collocation())
    @test opt.replay_summary.feasible
    @test length(opt.solution_x) == length(model.x0)
    replayed = replay(opt)
    @test replayed.replay_summary.max_abs_bus_balance_residual_kw < 1e-8
    @test replayed.replay_summary.max_abs_battery_inventory_residual_kwh < 1e-8

    terminal_scenario = ShortHorizonScenario(
        horizon_s = 2 * 3600.0,
        dt_s = 3600.0,
        solar_irradiance_kw_per_m2 = [0.1, 1.0],
        load_kw = [1.0, 1.0],
        initial_battery_soc = 0.7,
    )
    terminal_system = MinimalEnergyOntology(scenario = terminal_scenario,
        solar_area_m2 = 20.0, battery_capacity_kwh = 5.0,
        battery_power_kw = 3.0)
    terminal_formulation = Collocation(terminal_soc_equal_initial = true)
    terminal_model = assemble(terminal_system, terminal_scenario,
        terminal_formulation)
    terminal_opt = optimize(terminal_system, terminal_scenario;
        formulation = terminal_formulation)
    terminal_replay = replay(terminal_opt)
    @test terminal_opt.replay_summary.feasible
    @test terminal_replay.replay_summary.feasible
    @test constraint_violation(terminal_model, terminal_opt.solution_x) <= 1e-8
    @test isapprox(terminal_opt.states[end].battery_soc,
        terminal_scenario.initial_states.battery_soc; atol = 1e-10)

    report_dir = mktempdir()
    reported = report(opt, report_dir)
    @test isfile(joinpath(report_dir, "components.csv"))
    @test isfile(joinpath(report_dir, "ports.csv"))
    @test isfile(joinpath(report_dir, "connections.csv"))
    @test isfile(joinpath(report_dir, "variables.csv"))
    @test isfile(joinpath(report_dir, "residuals.csv"))
    @test isfile(joinpath(report_dir, "outputs.csv"))
    @test isfile(joinpath(report_dir, "model_paths.csv"))
    @test isfile(joinpath(report_dir, "level_maps.csv"))
    @test isfile(joinpath(report_dir, "formulation_boundaries.csv"))
    @test isfile(joinpath(report_dir, "plots.csv"))
    @test isfile(joinpath(report_dir, "timeseries.csv"))
    @test occursin("direction", first(readlines(joinpath(report_dir, "ports.csv"))))
    @test occursin("source", first(readlines(joinpath(report_dir, "connections.csv"))))
    @test occursin("source_level", first(readlines(joinpath(report_dir, "level_maps.csv"))))
    @test occursin("boundary",
        first(readlines(joinpath(report_dir, "formulation_boundaries.csv"))))
    @test occursin("plot_group", first(readlines(joinpath(report_dir, "plots.csv"))))
    @test isfile(joinpath(report_dir, "plot_power_kw.svg"))
    @test any(endswith(".svg"), reported.reports)
    @test !isempty(reported.reports)

    no_battery = MinimalEnergyOntology(scenario = scenario, include_battery = false,
        solar_area_m2 = 10.0, critical_load_fraction = 0.0)
    no_battery_audit = audit(no_battery, scenario; formulation = Collocation())
    @test !any(row -> row.name in (:battery, :battery_converter),
        component_table(no_battery))
    @test !any(row -> row.owner in (:battery, :battery_converter),
        no_battery_audit.variable_table)
    @test !any(row -> row.owner in (:battery, :battery_converter),
        no_battery_audit.residual_table)
    @test !any(row -> occursin("battery", string(row.source)) ||
        occursin("battery", string(row.sink)), no_battery_audit.connection_table)

    @test_throws ArgumentError VariableSpec(name = :bad, owner = :block,
        role = :design, unit = "kW", initial = 2.0, lower = 3.0,
        upper = 4.0, scale = 1.0)
    @test_throws ArgumentError ResidualSpec(name = :bad, owner = :block,
        equation = :eqn, sense = :eq, unit = "kW", scale = 0.0)
    @test_throws ArgumentError PortSpec(name = :bad_force,
        port_type = :platform_wrench, direction = :out, quantity = :force,
        unit = "N", sign_convention = "positive upward", owner = :block)
    @test_throws ArgumentError ShortHorizonScenario(initial_battery_soc = 1.5)
    @test_throws ArgumentError MinimalEnergyOntology(battery_capacity_kwh = 0.0)
    @test_throws ArgumentError FullSIRENOptOntology()

    package_system = PackageBackedHybridOntology(scenario = scenario,
        wind_rated_power_kw = 4.0, wave_rated_power_kw = 2.0)
    @test isvalid(package_system.validation)
    package_audit = audit(package_system, scenario; formulation = Collocation())
    @test any(row -> row.block == :wind_rotor &&
        row.model_path == :package_backed &&
        row.package == "UnsteadyKineticRotorDynamics", package_audit.model_path_table)
    @test any(row -> row.block == :wind_generator &&
        row.package == "GeneratorSE", package_audit.model_path_table)
    @test any(row -> row.block == :wind_converter &&
        row.package == "PowerConverterDynamics", package_audit.model_path_table)
    @test any(row -> row.block == :wave_wec &&
        row.model_path == :surrogate, package_audit.model_path_table)
    package_result = optimize(package_system, scenario; formulation = Collocation())
    package_model = assemble(package_system, scenario, Collocation())
    @test package_result.replay_summary.feasible
    @test constraint_violation(package_model, package_result.solution_x) <= 1e-8
    @test equality_residual(package_model, package_result.solution_x) <= 1e-8
    package_jac = ForwardDiff.jacobian(x -> evaluate_constraints(package_model, x),
        package_result.solution_x .+ 1e-4)
    @test all(isfinite, package_jac)

    hydro_scenario = ShortHorizonScenario(
        horizon_s = 3600.0,
        dt_s = 3600.0,
        solar_irradiance_kw_per_m2 = [0.0],
        wind_speed_m_s = [0.0],
        wave_power_flux_kw_per_m = [0.0],
        hydrokinetic_current_m_s = [2.0],
        load_kw = [0.1],
        initial_battery_soc = 0.7,
    )
    hydro_system = PackageBackedHybridOntology(scenario = hydro_scenario,
        include_hydrokinetic = true,
        hydrokinetic_rated_power_kw = 3.0,
        hydrokinetic_rotor_diameter_m = 2.0)
    @test isvalid(hydro_system.validation)
    hydro_audit = audit(hydro_system, hydro_scenario; formulation = Collocation())
    @test any(row -> row.block == :hydrokinetic_rotor &&
        row.model_path == :package_backed &&
        row.package == "UnsteadyKineticRotorDynamics", hydro_audit.model_path_table)
    @test any(row -> row.block == :hydrokinetic_generator &&
        row.package == "GeneratorSE", hydro_audit.model_path_table)
    @test any(row -> row.block == :hydrokinetic_converter &&
        row.package == "PowerConverterDynamics", hydro_audit.model_path_table)
    @test any(row -> row.source == Symbol("hydrokinetic_converter.bus_electrical") &&
        row.sink == Symbol("bus.bus_electrical"), hydro_audit.connection_table)
    @test any(row -> row.owner == :hydrokinetic_rotor &&
        row.name == :hydrokinetic_available_limit, hydro_audit.residual_table)
    hydro_model = assemble(hydro_system, hydro_scenario, Collocation())
    hydro_result = optimize(hydro_system, hydro_scenario; formulation = Collocation())
    @test hydro_result.replay_summary.feasible
    @test hydro_result.replay_summary.max_registered_constraint_violation <= 1e-8
    @test hydro_result.timeseries[1].hydrokinetic_available_power_kw > 0
    @test hydro_result.timeseries[1].hydrokinetic_bus_power_kw > 0
    @test hydro_result.timeseries[1].hydrokinetic_converter_loss_kw >= 0
    @test 0.0 <= hydro_result.controls[1].hydrokinetic_curtailment <= 1.0
    @test constraint_violation(hydro_model, hydro_result.solution_x) <= 1e-8
    hydro_jac = ForwardDiff.jacobian(x -> evaluate_constraints(hydro_model, x),
        hydro_result.solution_x .+ 1e-4)
    @test all(isfinite, hydro_jac)
    @test any(row -> row.name == :hydrokinetic_bus_power_kw &&
        row.plot_group == :power, plot_table(hydro_system))
    hydro_report_dir = mktempdir()
    report(hydro_result, hydro_report_dir)
    @test occursin("hydrokinetic_bus_power_kw",
        first(readlines(joinpath(hydro_report_dir, "timeseries.csv"))))
    hydro_rotor_model = SIRENOpt._block_param(hydro_system, :hydrokinetic_rotor,
        :rotor_model)
    hydro_design = HydrokineticDesign{Float64}(
        rotor_diameter = 2.0,
        cp = 0.38,
        rated_power = 3.0,
        rotor_model = hydro_rotor_model)
    hydro_power_current(v) = power_available_hydrokinetic(hydro_design,
        HydrokineticOp{typeof(v)}(
            resource = TimeSeries([zero(v)], [v]),
            fluid_density = 1025.0,
            curtailment = zero(v)), 1)
    hydro_power_density(rho) = power_available_hydrokinetic(hydro_design,
        HydrokineticOp{typeof(rho)}(
            resource = TimeSeries([zero(rho)], [2.0 + zero(rho)]),
            fluid_density = rho,
            curtailment = zero(rho)), 1)
    @test isfinite(ForwardDiff.derivative(hydro_power_current, 2.0))
    @test isfinite(ForwardDiff.derivative(hydro_power_density, 1025.0))

    diesel_scenario = ShortHorizonScenario(
        horizon_s = 3600.0,
        dt_s = 3600.0,
        solar_irradiance_kw_per_m2 = [0.0],
        load_kw = [0.5],
        initial_diesel_fuel_l = 20.0,
    )
    diesel_system = MinimalEnergyOntology(scenario = diesel_scenario,
        include_battery = false,
        include_diesel = true,
        critical_load_fraction = 1.0,
        diesel_rated_power_kw = 20.0)
    @test isvalid(diesel_system.validation)
    diesel_audit = audit(diesel_system, diesel_scenario; formulation = Collocation())
    @test any(row -> row.block == :diesel_engine &&
        row.model_path == :package_backed &&
        row.package == "DieselGen", diesel_audit.model_path_table)
    @test any(row -> row.block == :diesel_generator &&
        row.package == "GeneratorSE", diesel_audit.model_path_table)
    @test any(row -> row.block == :diesel_converter &&
        row.package == "PowerConverterDynamics", diesel_audit.model_path_table)
    @test any(row -> row.owner == :diesel_engine &&
        row.name == :diesel_fuel_inventory, diesel_audit.residual_table)
    diesel_model = assemble(diesel_system, diesel_scenario, Collocation())
    diesel_result = optimize(diesel_system, diesel_scenario; formulation = Collocation())
    @test diesel_result.replay_summary.feasible
    @test diesel_result.replay_summary.max_registered_constraint_violation <= 1e-8
    @test diesel_result.timeseries[1].diesel_bus_power_kw > 0
    @test diesel_result.timeseries[1].diesel_fuel_used_l > 0
    @test diesel_result.timeseries[1].diesel_fuel_l < diesel_scenario.initial_states.diesel_fuel_l
    @test diesel_result.controls[1].diesel_power_kw > 0
    @test constraint_violation(diesel_model, diesel_result.solution_x) <= 1e-8
    diesel_jac = ForwardDiff.jacobian(x -> evaluate_constraints(diesel_model, x),
        diesel_result.solution_x .+ 1e-4)
    @test all(isfinite, diesel_jac)
    diesel_report_dir = mktempdir()
    report(diesel_result, diesel_report_dir)
    @test occursin("diesel_fuel_l",
        first(readlines(joinpath(diesel_report_dir, "states.csv"))))
    @test occursin("diesel_bus_power_kw",
        first(readlines(joinpath(diesel_report_dir, "timeseries.csv"))))

    process_scenario = ShortHorizonScenario(
        horizon_s = 3600.0,
        dt_s = 3600.0,
        solar_irradiance_kw_per_m2 = [0.0],
        load_kw = [0.2],
        h2_demand_kg_per_h = [0.02],
        desal_demand_m3_per_h = [0.1],
        initial_diesel_fuel_l = 40.0,
    )
    process_system = MinimalEnergyOntology(scenario = process_scenario,
        include_battery = false,
        include_diesel = true,
        include_h2 = true,
        include_desal = true,
        critical_load_fraction = 1.0,
        diesel_rated_power_kw = 40.0,
        h2_electrolyzer_power_kw = 2.0,
        desal_plant_power_kw = 2.0)
    @test isvalid(process_system.validation)
    process_audit = audit(process_system, process_scenario; formulation = Collocation())
    @test any(row -> row.block == :h2_electrolyzer &&
        row.package == "H2Gen", process_audit.model_path_table)
    @test any(row -> row.block == :desalination &&
        row.package == "Desal", process_audit.model_path_table)
    @test any(row -> row.owner == :h2_electrolyzer &&
        row.name == :h2_inventory, process_audit.residual_table)
    @test any(row -> row.owner == :desalination &&
        row.name == :desal_inventory, process_audit.residual_table)
    process_model = assemble(process_system, process_scenario, Collocation())
    process_result = optimize(process_system, process_scenario; formulation = Collocation())
    @test process_result.replay_summary.feasible
    @test process_result.replay_summary.max_abs_h2_inventory_residual_kg <= 1e-8
    @test process_result.replay_summary.max_abs_desal_inventory_residual_m3 <= 1e-8
    @test process_result.timeseries[1].h2_device_power_kw > 0
    @test process_result.timeseries[1].desal_device_power_kw > 0
    @test process_result.timeseries[1].h2_bus_power_kw < 0
    @test process_result.timeseries[1].desal_bus_power_kw < 0
    @test process_result.controls[1].h2_power_kw > 0
    @test process_result.controls[1].desal_power_kw > 0
    @test constraint_violation(process_model, process_result.solution_x) <= 1e-8
    process_jac = ForwardDiff.jacobian(x -> evaluate_constraints(process_model, x),
        process_result.solution_x .+ 1e-4)
    @test all(isfinite, process_jac)

    dynamic_scenario = ShortHorizonScenario(
        horizon_s = 3 * 60.0,
        dt_s = 60.0,
        solar_irradiance_kw_per_m2 = [0.1, 0.1, 0.1],
        wind_speed_m_s = [8.0, 8.0, 8.0],
        wave_power_flux_kw_per_m = [1.0, 1.0, 1.0],
        load_kw = [1.5, 1.5, 1.5],
        initial_battery_soc = 0.7,
    )
    dynamic_system = DynamicMultilevelHybridOntology(scenario = dynamic_scenario,
        platform_inertia_kg_m2 = 1.0e5,
        platform_stiffness_nm_per_rad = 0.0,
        platform_damping_nm_s_per_rad = 0.0,
        wind_platform_moment_per_kw_nm = 500.0,
        wind_rated_power_kw = 4.0,
        wave_rated_power_kw = 2.0)
    @test isvalid(dynamic_system.validation)
    dynamic_audit = audit(dynamic_system, dynamic_scenario; formulation = Collocation())
    @test any(row -> row.source == Symbol("platform.motion_state") &&
        row.sink == Symbol("wind_rotor.motion_state"), dynamic_audit.connection_table)
    @test any(row -> row.source == Symbol("wind_rotor.platform_wrench") &&
        row.sink == Symbol("platform.platform_wrench"), dynamic_audit.connection_table)
    @test any(row -> row.owner == :platform &&
        row.name == :platform_dynamic_defect &&
        row.unit == "rad/s", dynamic_audit.residual_table)
    dynamic_result = optimize(dynamic_system, dynamic_scenario; formulation = Collocation())
    dynamic_model = assemble(dynamic_system, dynamic_scenario, Collocation())
    @test dynamic_result.replay_summary.feasible
    @test constraint_violation(dynamic_model, dynamic_result.solution_x) <= 1e-8
    @test equality_residual(dynamic_model, dynamic_result.solution_x) <= 1e-8
    @test abs(dynamic_result.states[end].platform_omega_rad_s) > 0.0
    @test dynamic_result.timeseries[end].wind_available_power_kw <
        dynamic_result.timeseries[1].wind_available_power_kw
    @test any(row -> row.block == :platform &&
        row.model_path == :surrogate, level_map_table(dynamic_system))
    dynamic_jac = ForwardDiff.jacobian(x -> evaluate_constraints(dynamic_model, x),
        dynamic_result.solution_x .+ 1e-4)
    @test all(isfinite, dynamic_jac)
    @test any(row -> row.plot_group == :platform_motion &&
        row.name == :platform_theta_rad, plot_table(dynamic_system))
    dynamic_report_dir = mktempdir()
    dynamic_reported = report(dynamic_result, dynamic_report_dir)
    @test isfile(joinpath(dynamic_report_dir, "plot_platform_motion_rad.svg"))
    @test isfile(joinpath(dynamic_report_dir, "plot_dynamics_n_m.svg"))
    @test isfile(joinpath(dynamic_report_dir, "formulation_boundaries.csv"))
    @test any(path -> endswith(path, "plot_platform_motion_rad.svg"),
        dynamic_reported.reports)

    single_shooting = Shooting(kind = :single)
    single_model = assemble(dynamic_system, dynamic_scenario, single_shooting)
    single_vars = variable_table(single_model.registry)
    @test any(row -> row.role == :design, single_vars)
    @test any(row -> row.role == :control, single_vars)
    @test !any(row -> row.role == :state, single_vars)
    @test length(single_model.x0) < length(dynamic_model.x0)
    single_boundaries = formulation_boundary_table(single_model)
    @test any(row -> row.boundary == :single_shooting_replay &&
        row.replayed_roles == "state", single_boundaries)
    single_result = optimize(dynamic_system, dynamic_scenario;
        formulation = single_shooting)
    @test single_result.replay_summary.feasible
    @test single_result.replay_summary.max_registered_constraint_violation <= 1e-8

    multiple_shooting = Shooting(kind = :multiple, segment_s = 60.0,
        retained_implicit_boundaries = [:platform_implicit_step])
    multiple_boundaries = formulation_boundary_table(multiple_shooting)
    @test any(row -> row.boundary == :multiple_shooting_replay &&
        row.segment_s == 60.0, multiple_boundaries)
    @test any(row -> row.boundary == :retained_implicit_solve &&
        row.retained_implicit_boundary == :platform_implicit_step,
        multiple_boundaries)
    multiple_result = optimize(dynamic_system, dynamic_scenario;
        formulation = multiple_shooting)
    @test multiple_result.replay_summary.feasible
    shooting_report_dir = mktempdir()
    report(multiple_result, shooting_report_dir)
    formulation_boundary_header =
        first(readlines(joinpath(shooting_report_dir, "formulation_boundaries.csv")))
    @test occursin("retained_implicit_boundary", formulation_boundary_header)
    @test occursin("platform_implicit_step",
        read(joinpath(shooting_report_dir, "formulation_boundaries.csv"), String))
    @test_throws ArgumentError Shooting(kind = :bad)
    @test_throws ArgumentError Shooting(kind = :multiple, segment_s = 0.0)

    bus_block = BusBalanceBlock()
    cache = Dict{Symbol,Float64}()
    evaluate!(cache, bus_block, nothing, (inputs_kw = [2.0, -2.0],))
    r = zeros(1)
    residual!(r, bus_block, nothing, nothing, cache)
    @test r[1] == 0.0
    @test first(ports(bus_block, nothing)).owner == :bus
end

@testset "SIRENOpt examples" begin
    # Example time series (hours)
    t = [0.0, 1.0, 2.0]
    solar_ts = TimeSeries(t, [0.2, 0.5, 0.1])
    wind_ts = TimeSeries(t, [4.0, 5.0, 3.0])
    wave_ts = TimeSeries(t, [2.0, 2.0, 2.0])
    load_ts = TimeSeries(t, [5.0, 5.0, 5.0])

    # Minimal operation setup
    op = SystemOperation{T}(
        solar = SolarOp{T}(resource = solar_ts),
        wind = WindOp{T}(resource = wind_ts),
        wave = WaveOp{T}(resource = wave_ts),
        load = LoadOp{T}(demand = load_ts),
    )

    design = SystemDesign{T}()

    @testset "simulation" begin
        states, outputs = simulate(design, op, 1.0)
        @test length(states) == length(load_ts)
        @test length(outputs) == length(load_ts)
        @test all(o -> isfinite(o.bus_voltage), outputs)

        state1, out1 = simulate_step(design, op, states[1], 1, 1.0)
        setpoints = controller_step(design, op, states[1], 1, 1.0)
        state2, out2 = plant_step(design, op, states[1], setpoints, 1, 1.0)
        @test state1.battery_soc ≈ state2.battery_soc
        @test out1.net_bus_power_kw ≈ out2.net_bus_power_kw

        _, smooth_outputs = simulate(design, op, 1.0; control = smooth_controller_step)
        @test all(o -> isfinite(o.net_bus_power_kw), smooth_outputs)
        @test all(o -> isfinite(o.bus_balance_residual_kw), smooth_outputs)
        @test all(o -> o.bus_balance_residual_kw ≈ o.net_bus_power_kw, smooth_outputs)
    end

    @testset "bus-balanced residual fixture" begin
        include(joinpath(@__DIR__, "..", "examples", "balanced_electric_bus_demo.jl"))
        result = run_balanced_electric_bus_demo()
        outputs = result.outputs

        @test length(outputs) == 4
        @test all(output -> isfinite(output.bus_balance_residual_kw), outputs)
        @test all(output -> output.bus_balance_residual_kw ≈ output.net_bus_power_kw, outputs)
        @test maximum(abs(output.bus_balance_residual_kw) for output in outputs) < 1e-10
        @test maximum(abs(output.battery_inventory_residual_kwh) for output in outputs) < 1e-10
        @test maximum(abs(output.diesel_fuel_inventory_residual) for output in outputs) < 1e-10
        @test maximum(abs(output.h2_inventory_residual_kg) for output in outputs) < 1e-10
        @test maximum(abs(output.desal_inventory_residual_m3) for output in outputs) < 1e-10
    end

    @testset "multi-level ontology acceptance demo reports" begin
        include(joinpath(@__DIR__, "..", "examples", "multilevel_collocation_hybrid_demo.jl"))
        demo_dir = mktempdir()
        result = run_multilevel_collocation_hybrid_demo(report_dir = demo_dir)

        @test result.optimization.replay_summary.feasible
        @test result.optimization.replay_summary.max_registered_constraint_violation <= 1e-8
        @test result.motion_feedback_delta_kw > 0

        map_metadata = result.acceptance_reports.map_metadata
        level1_summary = result.acceptance_reports.level1_map_summary
        level2_event = result.acceptance_reports.level2_dynamic_event
        level3_reliability = result.acceptance_reports.level3_reliability_bins
        result_metadata = result.acceptance_reports.result_metadata
        for path in (map_metadata, level1_summary, level2_event,
                level3_reliability, result_metadata, result.derivative_report)
            @test isfile(path)
        end

        map_header = first(readlines(map_metadata))
        @test occursin("producing_level", map_header)
        @test occursin("consuming_level", map_header)
        @test occursin("design_dependencies", map_header)
        @test occursin("valid_range", map_header)
        @test occursin("interpolation_method", map_header)
        @test occursin("verification_case", map_header)
        map_text = read(map_metadata, String)
        @test occursin("solar_array_contract", map_text)
        @test occursin("wind_rotor_contract", map_text)
        @test occursin("wave_wec_contract", map_text)
        @test occursin("hydrokinetic_rotor_contract", map_text)
        @test occursin("platform_contract", map_text)
        @test occursin("load_contract", map_text)
        @test occursin("ForwardDiff/central-difference boundary check", map_text)

        level1_text = read(level1_summary, String)
        @test occursin("wind_rotor_contract", level1_text)
        @test occursin("wave_wec_contract", level1_text)
        @test occursin("hydrokinetic_rotor_contract", level1_text)
        @test occursin("platform_contract", level1_text)

        level2_lines = readlines(level2_event)
        @test length(level2_lines) == length(result.optimization.timeseries) + 1
        @test occursin("platform_theta_rad", first(level2_lines))
        @test occursin("bus_balance_residual_kw", first(level2_lines))

        level3_lines = readlines(level3_reliability)
        @test length(level3_lines) == length(result.optimization.timeseries) + 1
        @test occursin("resource_bin", first(level3_lines))
        @test occursin("served_load_kw", first(level3_lines))
        @test occursin("reliability_margin", first(level3_lines))

        derivative_text = read(result.derivative_report, String)
        @test occursin("design_to_level1_wind", derivative_text)
        @test occursin("level1_motion_to_source", derivative_text)
        @test occursin("level2_dispatch_to_level3_reliability", derivative_text)
        constraint_bounds_line = only(filter(
            line -> startswith(line, "constraint_bounds,"),
            readlines(result.derivative_report)))
        @test parse(Float64, split(constraint_bounds_line, ",")[end]) <= 1e-8

        report_level_maps = first(readlines(joinpath(demo_dir, "level_maps.csv")))
        @test occursin("producing_level", report_level_maps)
        @test occursin("interpolation_method", report_level_maps)
        @test occursin("active_bound_report", report_level_maps)
        residual_text = read(joinpath(demo_dir, "residuals.csv"), String)
        @test occursin("battery_terminal_soc", residual_text)
        @test occursin("wave_pto_limit", residual_text)
        @test isfile(result.acceptance_reports.manuscript_summary)
        @test isfile(result.acceptance_reports.manuscript_figure_manifest)
        @test occursin("terminal_battery_soc",
            read(result.acceptance_reports.manuscript_summary, String))
        @test occursin("generated_from_checked_result",
            first(readlines(result.acceptance_reports.manuscript_figure_manifest)))
    end

    @testset "SIRENO-lite ontology comparison fixture" begin
        include(joinpath(@__DIR__, "..", "examples", "sirenolite_comparison_fixture.jl"))
        comparison_dir = mktempdir()
        result = run_sirenolite_comparison_fixture(report_dir = comparison_dir)

        @test result.ontology_result.replay_summary.feasible
        @test result.ontology_result.replay_summary.max_registered_constraint_violation <= 1e-8
        @test length(result.reference_outputs) == length(result.ontology_result.timeseries)
        @test isdir(result.reports.ontology_report_dir)
        for path in (result.reports.inputs, result.reports.summary,
                result.reports.metrics, result.reports.difference,
                result.reports.reference_timeseries,
                result.reports.sirenopt_timeseries, result.reports.timeseries,
                result.reports.model_paths, result.reports.plot)
            @test isfile(path)
        end
        input_text = read(result.reports.inputs, String)
        @test occursin("source_file", input_text)
        @test occursin("solar_irradiance_kw_per_m2", input_text)
        @test occursin("h2_demand_kg_per_h", input_text)
        summary_text = read(result.reports.summary, String)
        @test occursin("sirenolite_reference_simulator", summary_text)
        @test occursin("sirenopt_sirenolite_ontology", summary_text)
        metrics_text = read(result.reports.metrics, String)
        @test occursin("load_served_kwh", metrics_text)
        @test occursin("reported_difference", metrics_text)
        difference_text = read(result.reports.difference, String)
        @test occursin("resource_mapping", difference_text)
        @test occursin("battery_sign", difference_text)
        model_path_text = read(result.reports.model_paths, String)
        @test occursin("wind_rotor,package_backed", model_path_text)
        @test occursin("wave_wec,surrogate", model_path_text)
        @test occursin("legacy SIRENO-lite-aligned SIRENOpt simulator",
            read(result.reports.reference_timeseries, String))
        @test occursin("SIRENOpt ontology SIRENO-lite comparison fixture",
            read(result.reports.sirenopt_timeseries, String))
        @test occursin("reference_battery_soc", first(readlines(result.reports.timeseries)))
    end

    @testset "SNOW examples block-API migration fixture" begin
        include(joinpath(@__DIR__, "..", "examples", "snow_examples_block_api.jl"))
        migration_dir = mktempdir()
        result = run_snow_examples_block_api(report_dir = migration_dir)

        @test length(result.cases) == 5
        @test isfile(result.summary)
        @test all(case -> case.result.replay_summary.feasible, result.cases)
        @test maximum(case.result.replay_summary.max_registered_constraint_violation
            for case in result.cases) <= 1e-8
        summary_text = read(result.summary, String)
        @test occursin("balanced_electric_bus_demo", summary_text)
        @test occursin("short_horizon_snow", summary_text)
        @test occursin("three_minute_package_snow", summary_text)
        @test occursin("prescribed_motion_dynamic_io", summary_text)
        @test occursin("pendulum_platform_codesign_snow", summary_text)
        @test occursin("package_backed_blocks", first(readlines(result.summary)))
        for case in result.cases
            @test isfile(joinpath(case.report_dir, "components.csv"))
            @test isfile(joinpath(case.report_dir, "model_paths.csv"))
            @test isfile(joinpath(case.report_dir, "replay_residuals.csv"))
        end
    end

    @testset "SNOW-style objective" begin
        varspec = default_design_varspec(design)
        x0 = varspec_x0(varspec)

        problem = SnowProblem{T}(
            base_design = design,
            operation = op,
            dt_hours = 1.0,
            constraint_spec = ConstraintSpec{T}(
                battery_only_hours = 1.0,
                battery_plus_renewables_hours = 1.0,
                full_system_hours = 1.0,
            ),
            objective_mode = :dynamic,
            varspec = varspec,
        )

        g = zeros(constraint_count(problem))
        f = snow_objective!(g, x0, problem)

        @test isfinite(f)
        @test length(g) == 3
        @test all(isfinite, g)

        # Demonstrate parameter update through x-vector
        x1 = copy(x0)
        x1[1] = x1[1] * 1.5
        design1 = design_from_x(design, varspec, x1)
        @test design1.solar.area ≈ x1[1]
    end

    @testset "mixed-type design update" begin
        varspec = default_design_varspec(design)
        x0 = varspec_x0(varspec)

        x_mixed = Any[x0...]
        x_mixed[1] = big(x0[1])
        design_mixed = design_from_x(design, varspec, x_mixed)

        @test design_mixed.solar.area == big(x0[1])
        @test design_mixed.solar.area isa BigFloat
        @test design_mixed.wind.rated_power isa BigFloat
    end

    @testset "AD dynamic objective smoke test" begin
        varspec = DesignVarSpec{T}(vars = DesignVar{T}[
            DesignVar{T}(name = :solar_area, initial = design.solar.area, lower = zero(T)),
        ])
        x0 = varspec_x0(varspec)
        problem = SnowProblem{T}(
            base_design = design,
            operation = op,
            dt_hours = 1.0,
            constraint_spec = ConstraintSpec{T}(
                battery_only_hours = 1.0,
                battery_plus_renewables_hours = 1.0,
                full_system_hours = 1.0,
            ),
            objective_mode = :dynamic,
            varspec = varspec,
        )

        objective(x) = begin
            g = zeros(eltype(x), constraint_count(problem))
            snow_objective!(g, x, problem)
        end

        grad_ad = ForwardDiff.gradient(objective, x0)
        grad_fd = FiniteDiff.finite_difference_gradient(objective, x0, Val(:central))

        @test length(grad_ad) == 1
        @test all(isfinite, grad_ad)
        @test all(isapprox.(grad_ad, grad_fd; rtol = 1.0e-6, atol = 1.0e-8))
    end

    @testset "fuel and critical load accounting" begin
        diesel_design = SIRENOpt.with(design;
            diesel = DieselDesign{T}(
                rated_power = 20.0,
                efficiency = 0.5,
                fuel_per_kwh = 0.2,
            ),
            diesel_gen = GeneratorDesign{T}(
                rated_power = 50.0,
                efficiency = 0.8,
            ),
            diesel_conv = ConverterDesign{T}(
                rated_power = 50.0,
                efficiency = 0.9,
            ),
        )
        zero_load_op = SystemOperation{T}(
            load = LoadOp{T}(demand = TimeSeries([0.0, 1.0], [0.0, 0.0])),
        )
        fixed_diesel = (design, op, state, k, dt_hours) -> ControlSetpoints(
            solar_curtailment = one(dt_hours),
            wind_curtailment = one(dt_hours),
            wave_curtailment = one(dt_hours),
            load_served_fraction = one(dt_hours),
            diesel_power_kw = 10.0,
            battery_power_kw = zero(dt_hours),
            h2_power_kw = zero(dt_hours),
            desal_power_kw = zero(dt_hours),
        )

        _, fuel_outputs = simulate(diesel_design, zero_load_op, 1.0; control = fixed_diesel)
        engine = diesel_engine_design(diesel_design.diesel)
        expected_fuel = 2 * diesel_fuel_used(engine, 10.0, 1.0)
        @test sum(o -> o.diesel_fuel_used, fuel_outputs) ≈ expected_fuel
        @test objective_dynamic(diesel_design, zero_load_op, 1.0;
            mode = :diesel_fuel, control = fixed_diesel) ≈ expected_fuel
        @test sum(o -> o.diesel_power_kw * diesel_design.diesel.fuel_per_kwh, fuel_outputs) != expected_fuel

        critical_design = SIRENOpt.with(design;
            load = LoadDesign{T}(critical_fraction = 0.25),
            battery = BatteryDesign{T}(capacity_kwh = 10.0),
        )
        critical_op = SystemOperation{T}(
            load = LoadOp{T}(demand = TimeSeries([0.0], [20.0])),
        )
        cons = check_constraints(critical_design, critical_op,
            ConstraintSpec{T}(battery_only_hours = 4.0), 1.0)
        @test cons.battery_only_margin ≈ -10.0
    end

    @testset "hydrokinetic source path" begin
        hydro_design = SIRENOpt.with(design;
            hydrokinetic = HydrokineticDesign{T}(rated_power = 25.0),
            hydrokinetic_gen = GeneratorDesign{T}(rated_power = 25.0),
            hydrokinetic_conv = ConverterDesign{T}(rated_power = 25.0),
            h2 = H2Design{T}(electrolyzer_power_kw = 0.0),
            desal = DesalDesign{T}(plant_power_kw = 0.0),
        )
        hydro_op = SystemOperation{T}(
            hydrokinetic = HydrokineticOp{T}(resource = TimeSeries([0.0], [2.0])),
            load = LoadOp{T}(demand = TimeSeries([0.0], [0.0])),
        )
        hydro_only = (design, op, state, k, dt_hours) -> ControlSetpoints(
            solar_curtailment = one(dt_hours),
            wind_curtailment = one(dt_hours),
            wave_curtailment = one(dt_hours),
            hydrokinetic_curtailment = zero(dt_hours),
            load_served_fraction = one(dt_hours),
            diesel_power_kw = zero(dt_hours),
            battery_power_kw = zero(dt_hours),
            h2_power_kw = zero(dt_hours),
            desal_power_kw = zero(dt_hours),
        )

        _, hydro_outputs = simulate(hydro_design, hydro_op, 1.0; control = hydro_only)
        @test hydro_outputs[1].hydrokinetic_power_kw > 0
        @test hydro_outputs[1].net_bus_power_kw >= hydro_outputs[1].hydrokinetic_power_kw
    end

    @testset "UnsteadyKineticRotorDynamics source adapter" begin
        wind_model = simple_ccblade_rotor_model(
            rotor_radius = 1.0,
            blades = 2,
            n_sections = 3,
            omega_rad_s = 20.0,
            fluid = :air,
        )
        p_air = ccblade_rotor_power_kw(wind_model, 10.0, 1.225)
        @test isfinite(p_air)
        @test p_air >= 0

        ccblade_wind = WindDesign{T}(
            rotor_diameter = 2.0,
            rated_power = 100.0,
            rotor_model = wind_model,
        )
        p_wind = power_available_wind(ccblade_wind, WindOp{T}(resource = TimeSeries([0.0], [10.0]), air_density = 1.225), 1)
        @test isfinite(p_wind)
        @test 0 <= p_wind <= ccblade_wind.rated_power

        hydro_model = simple_ccblade_rotor_model(
            rotor_radius = 0.5,
            blades = 2,
            n_sections = 3,
            omega_rad_s = 8.0,
            fluid = :water,
        )
        ccblade_hydro = HydrokineticDesign{T}(
            rotor_diameter = 1.0,
            rated_power = 100.0,
            rotor_model = hydro_model,
        )
        p_hydro = power_available_hydrokinetic(ccblade_hydro, HydrokineticOp{T}(resource = TimeSeries([0.0], [2.0]), fluid_density = 1025.0), 1)
        @test isfinite(p_hydro)
        @test 0 <= p_hydro <= ccblade_hydro.rated_power

        rotor_power(v) = ccblade_rotor_power_kw(wind_model, v, 1.225)
        dpdv_ad = ForwardDiff.derivative(rotor_power, 10.0)
        dpdv_fd = FiniteDiff.finite_difference_derivative(rotor_power, 10.0, Val(:central))
        @test isfinite(dpdv_ad)
        @test isapprox(dpdv_ad, dpdv_fd; rtol = 1.0e-6, atol = 1.0e-8)
    end
end

@testset "GeneratorSE and PowerConverterDynamics adapters" begin
    gen_model = generatorse_pmsg_arms_model(rated_power_kw = 5000.0)
    @test isfinite(gen_model.efficiency)
    @test 0 < gen_model.efficiency <= 1
    @test gen_model.mass_kg > 0

    gen_design = GeneratorDesign{T}(
        rated_power = 5000.0,
        efficiency = 0.5,
        generator_model = gen_model,
    )
    p_gen = generator_output(gen_design, GeneratorOp{T}(), 1000.0)
    @test isfinite(p_gen)
    @test isapprox(p_gen, 1000.0 * gen_model.efficiency; rtol = 1.0e-3)

    conv_model = powerconverter_model(rated_power_kw = 5000.0)
    conv_design = ConverterDesign{T}(
        rated_power = 5000.0,
        efficiency = 0.5,
        converter_model = conv_model,
    )
    p_bus = converter_output(conv_design, ConverterOp{T}(), p_gen)
    @test isfinite(p_bus)
    @test 0 < p_bus < p_gen

    power_path(p) = begin
        p_generated = generator_output(gen_design, GeneratorOp{typeof(p)}(), p)
        converter_output(conv_design, ConverterOp{typeof(p)}(), p_generated)
    end
    grad_ad = ForwardDiff.derivative(power_path, 1000.0)
    grad_fd = FiniteDiff.finite_difference_derivative(power_path, 1000.0, Val(:central))
    @test isfinite(grad_ad)
    @test grad_ad > 0
    @test isapprox(grad_ad, grad_fd; rtol = 1.0e-6, atol = 1.0e-8)
end

@testset "AgnosticStorageDynamics battery adapter" begin
    storage_template = SIRENOpt.AgnosticStorageDynamics.StorageParams(
        energy_capacity = 1.0,
        charge_rate_max = 1.0,
        discharge_rate_max = 1.0,
        standing_loss_rate = 0.0,
    )
    storage_design = BatteryDesign{T}(
        capacity_kwh = 10.0,
        max_charge_kw = 5.0,
        max_discharge_kw = 5.0,
        charge_efficiency = 1.0,
        discharge_efficiency = 1.0,
        storage_model = storage_template,
    )

    soc_discharge, p_discharge = battery_step(storage_design, BatteryOp{T}(), 0.5, 3.0, 1.0)
    @test p_discharge ≈ 3.0
    @test soc_discharge ≈ 0.2

    soc_charge, p_charge = battery_step(storage_design, BatteryOp{T}(), soc_discharge, -4.0, 1.0)
    @test p_charge ≈ -4.0
    @test soc_charge ≈ 0.6

    battery_power(cmd) = begin
        _, p = battery_step(storage_design, BatteryOp{typeof(cmd)}(), 0.5 + zero(cmd), cmd, 1.0 + zero(cmd))
        p
    end
    grad_ad = ForwardDiff.derivative(battery_power, 2.0)
    grad_fd = FiniteDiff.finite_difference_derivative(battery_power, 2.0, Val(:central))
    @test isfinite(grad_ad)
    @test grad_ad ≈ 1.0
    @test isapprox(grad_ad, grad_fd; rtol = 1.0e-8, atol = 1.0e-8)
end

@testset "H2Gen and Desal adapters" begin
    h2_template = SIRENOpt.H2Gen.DesignStruct(
        capacity_mw = 0.01,
        efficiency = 0.6,
        min_load = 0.0,
        max_load = 1.0,
    )
    h2_design = H2Design{T}(
        electrolyzer_power_kw = 10.0,
        tank_capacity_kg = 5.0,
        specific_energy_kwh_per_kg = 50.0,
        h2_model = h2_template,
    )
    h2_op = H2Op{T}(demand = TimeSeries([0.0], [0.0]))
    h2_level, h2_power = h2_step(h2_design, h2_op, 0.0, 5.0, 1.0, 1)
    @test h2_power ≈ 5.0
    @test h2_level ≈ 0.1

    desal_template = SIRENOpt.Desal.DesignStruct(
        capacity_m3_per_h = 1.0,
        specific_energy_nominal_kwh_per_m3 = 3.0,
        min_load = 0.0,
        response_time_hours = 0.0,
        part_load_penalty = 0.0,
        recovery_part_load_sensitivity = 0.0,
    )
    desal_design = DesalDesign{T}(
        plant_power_kw = 3.0,
        tank_capacity_m3 = 5.0,
        specific_energy_kwh_per_m3 = 3.0,
        desal_model = desal_template,
    )
    desal_op = DesalOp{T}(demand = TimeSeries([0.0], [0.0]))
    desal_level, desal_power = desal_step(desal_design, desal_op, 0.0, 1.5, 1.0, 1)
    @test desal_power ≈ 1.5
    @test desal_level ≈ 0.5

    h2_power_used(p) = begin
        _, used = h2_step(h2_design, H2Op{typeof(p)}(demand = TimeSeries([zero(p)], [zero(p)])), zero(p), p, one(p), 1)
        used
    end
    h2_grad_ad = ForwardDiff.derivative(h2_power_used, 5.0)
    h2_grad_fd = FiniteDiff.finite_difference_derivative(h2_power_used, 5.0, Val(:central))
    @test isfinite(h2_grad_ad)
    @test h2_grad_ad > 0
    @test isapprox(h2_grad_ad, h2_grad_fd; rtol = 1.0e-6, atol = 1.0e-8)

    desal_level_path(p) = begin
        level, _ = desal_step(desal_design, DesalOp{typeof(p)}(demand = TimeSeries([zero(p)], [zero(p)])), zero(p), p, one(p), 1)
        level
    end
    desal_grad_ad = ForwardDiff.derivative(desal_level_path, 1.5)
    desal_grad_fd = FiniteDiff.finite_difference_derivative(desal_level_path, 1.5, Val(:central))
    @test isfinite(desal_grad_ad)
    @test desal_grad_ad > 0
    @test isapprox(desal_grad_ad, desal_grad_fd; rtol = 1.0e-6, atol = 1.0e-8)
end

@testset "Wave resource adapters" begin
    flux = wave_power_flux_kw_per_m(2.0, 8.0)
    @test isfinite(flux)
    @test flux > 0

    frequencies = collect(0.05:0.01:1.0) .* SIRENOpt.Unitful.Hz
    spectrum = SIRENOpt.WaveSpectra.ParametricSpectra.spectrum_pierson_moskowitz(
        frequencies,
        2.0 * SIRENOpt.Unitful.m,
        8.0 * SIRENOpt.Unitful.s,
    )
    spectral_flux = wave_spectrum_power_flux_kw_per_m(spectrum)
    @test isfinite(spectral_flux)
    @test spectral_flux > 0
    @test isapprox(spectral_flux, flux; rtol = 0.2)

    ts = wave_resource_timeseries([0.0, 1.0], [flux, spectral_flux])
    @test value_at(ts, 1) == flux
    @test value_at(ts, 2) == spectral_flux
end

@testset "Hydrodynamics platform adapter" begin
    excitation_coeff = zeros(1, 1, 2, 2)
    excitation_coeff[1, 1, :, 1] = [1.0, 0.5]
    excitation_coeff[1, 1, :, 2] = [0.0, 0.25]
    wave = ([1.0, 2.0], [0.0, pi / 2], [0.5, 0.2], 0.1, 0.0, 0.0)
    model = hydrodynamic_platform_model(
        stiffness_n_per_m = 2.0,
        damping_n_s_per_m = 0.2,
        mass_kg = 10.0,
        excitation_coeff = excitation_coeff,
        constant_forces_n = [0.0],
        wave = wave,
    )

    accel = hydrodynamic_platform_acceleration(model, 0.1, 0.0, 0.25)
    @test isfinite(accel)

    state = PlatformState{T}(position = 0.1, velocity = 0.0, acceleration = 0.0)
    next_state = hydrodynamic_dynamics_step(model, state, 0.1; time_s = 0.25)
    @test isfinite(next_state.position)
    @test isfinite(next_state.velocity)
    @test isfinite(next_state.acceleration)

    platform_design = PlatformDesign{T}(base_mass = 10.0, hydrodynamic_model = model)
    coupled_state = dynamics_step(platform_design, state, 1.0, 0.1)
    @test isfinite(coupled_state.acceleration)

    platform_accel(x) = hydrodynamic_platform_acceleration(model, x[1], x[2], 0.25)
    grad_ad = ForwardDiff.gradient(platform_accel, [0.1, 0.0])
    grad_fd = FiniteDiff.finite_difference_gradient(platform_accel, [0.1, 0.0], Val(:central))
    @test length(grad_ad) == 2
    @test all(isfinite, grad_ad)
    @test all(isapprox.(grad_ad, grad_fd; rtol = 1.0e-6, atol = 1.0e-8))
end

@testset "Hydrodynamics 6DOF platform adapter" begin
    function sample_hydrodynamics6dof_platform()
        omega = T.([0.5, 1.0])
        wave = hydrodynamics_wave_components(
            omega = omega,
            phase = zeros(T, length(omega)),
            spectrum = fill(T(0.4), length(omega)),
            dω = T(0.1),
            start_time_s = zero(T),
            ramp_time_s = zero(T),
        )
        hydrostatic = zeros(T, 6, 6)
        hydrostatic[3, 3] = T(20.0)
        radiation_damping = zeros(T, 6, 6)
        excitation = zeros(T, 6, 1, length(omega), 2)
        excitation[3, 1, :, 1] .= T.([10.0, 10.0])
        model = hydrodynamics6dof_platform_model(
            mass_matrix = Diagonal(fill(T(100.0), 6)),
            radiation_damping = radiation_damping,
            hydrostatic_stiffness = hydrostatic,
            excitation_coeff = excitation,
            wave = wave,
        )
        return PlatformDesign{T}(base_mass = 100.0, hydrodynamic_model = model)
    end

    platform = sample_hydrodynamics6dof_platform()
    state = PlatformState6DOF{T}()
    wrench = zeros(T, 6)
    wrench[3] = 10.0

    @test platform_wrench(platform, PlatformOp{T}(external_wrench = TimeSeries([0.0], [wrench])), 1) == wrench
    @test platform_wrench(platform, PlatformOp{T}(external_force = TimeSeries([0.0], [10.0])), 1) == wrench
    @test_throws ArgumentError dynamics_step(platform, PlatformState{T}(), wrench, 0.1)

    quiet_wave = hydrodynamics_wave_components(
        omega = T.([0.5, 1.0]),
        phase = zeros(T, 2),
        spectrum = zeros(T, 2),
        dω = T(0.1),
        start_time_s = zero(T),
        ramp_time_s = zero(T),
    )
    next_state = dynamics_step(platform, state, wrench, 0.1; time_s = 0.0,
        wave = quiet_wave)
    @test next_state isa PlatformState6DOF
    @test length(next_state.position) == 6
    @test size(next_state.velocity_history, 1) == 6
    @test size(next_state.velocity_history, 2) == 2
    @test next_state.acceleration[3] ≈ 10.0 / 100.0 rtol = 0.05
    @test next_state.position[3] > 0
    @test all(iszero, next_state.position[[1, 2, 4, 5, 6]])

    design = SystemDesign{T}(platform = platform)
    op = SystemOperation{T}(
        load = LoadOp{T}(demand = TimeSeries([0.0, 1.0], [0.0, 0.0])),
        platform = PlatformOp{T}(
            external_wrench = TimeSeries([0.0, 1.0], [zeros(T, 6), zeros(T, 6)]),
            wave_components = hydrodynamics_wave_components(
                omega = T.([0.5, 1.0]),
                phase = zeros(T, 2),
                spectrum = fill(T(0.4), 2),
                dω = T(0.1),
                start_time_s = zero(T),
                ramp_time_s = zero(T),
            ),
        ),
    )
    fixed_controls = (_design, _op, _state, _k, dt_hours) -> ControlSetpoints{typeof(dt_hours)}()
    states, outputs = simulate(design, op, 0.1 / 3600; control = fixed_controls)
    @test length(states) == 2
    @test length(outputs) == 2
    @test states[1].platform isa PlatformState6DOF
    @test states[2].platform.position[3] > 0
    @test isfinite(outputs[1].bus_voltage)
    diagnostic_op = SystemOperation{T}(
        load = LoadOp{T}(demand = TimeSeries([0.0, 1.0], [0.0, 0.0])),
        platform = PlatformOp{T}(
            external_wrench = TimeSeries([0.0, 1.0], [zeros(T, 6), zeros(T, 6)]),
            validate_hydrodynamic_coefficients = true,
        ),
    )
    @test_throws ArgumentError simulate(design, diagnostic_op, 0.1 / 3600;
        control = fixed_controls)
end

@testset "Full-system Hydrodynamics 6DOF demonstration" begin
    include(joinpath(@__DIR__, "..", "examples", "full_system_hydrodynamics6dof_demo.jl"))
    result = run_full_system_hydrodynamics6dof_demo()

    @test length(result.states) == 8
    @test length(result.outputs) == 8
    @test all(output -> isfinite(output.bus_voltage), result.outputs)
    @test all(output -> isfinite(output.net_bus_power_kw), result.outputs)
    @test all(output -> isfinite(output.bus_balance_residual_kw), result.outputs)
    @test all(output -> isfinite(output.battery_inventory_residual_kwh), result.outputs)
    @test all(output -> isfinite(output.diesel_fuel_inventory_residual), result.outputs)
    @test all(output -> isfinite(output.h2_inventory_residual_kg), result.outputs)
    @test all(output -> isfinite(output.desal_inventory_residual_m3), result.outputs)
    @test maximum(abs(output.battery_inventory_residual_kwh) for output in result.outputs) < 1e-10
    @test maximum(abs(output.diesel_fuel_inventory_residual) for output in result.outputs) < 1e-10
    @test maximum(abs(output.h2_inventory_residual_kg) for output in result.outputs) < 1e-10
    @test maximum(abs(output.desal_inventory_residual_m3) for output in result.outputs) < 1e-10

    @test any(output -> output.solar_power_kw > 0, result.outputs)
    @test any(output -> output.wind_power_kw > 0, result.outputs)
    @test any(output -> output.wave_power_kw > 0, result.outputs)
    @test any(output -> output.hydrokinetic_power_kw > 0, result.outputs)
    @test any(output -> output.diesel_power_kw > 0, result.outputs)
    @test any(output -> output.battery_power_kw < 0, result.outputs)
    @test any(output -> output.h2_power_kw < 0, result.outputs)
    @test any(output -> output.desal_power_kw < 0, result.outputs)
    @test any(output -> output.load_power_kw < 0, result.outputs)
    @test sum(output -> output.diesel_fuel_used, result.outputs) > 0

    @test result.states[1].platform isa PlatformState6DOF
    @test result.states[end].platform.position[3] > 0
    @test size(result.states[end].platform.velocity_history, 1) == 6
    @test size(result.states[end].platform.velocity_history, 2) == length(result.states)
    @test result.operation.platform.wave_components isa Tuple
    @test result.design.platform.hydrodynamic_model isa Hydrodynamic6DOFPlatformModel

    @test result.design.solar.pv_model !== nothing
    @test result.design.wind_gen.generator_model !== nothing
    @test result.design.wind_conv.converter_model !== nothing
    @test result.design.battery.storage_model !== nothing
    @test result.design.h2.h2_model !== nothing
    @test result.design.desal.desal_model !== nothing
    @test result.aggregate.mass > result.design.platform.base_mass

    updated = SIRENOpt.with(result.design;
        wind_gen = SIRENOpt.with(result.design.wind_gen; rated_power = 40.0),
        wind_conv = SIRENOpt.with(result.design.wind_conv; rated_power = 40.0),
        battery = SIRENOpt.with(result.design.battery; capacity_kwh = 25.0),
        h2 = SIRENOpt.with(result.design.h2; electrolyzer_power_kw = 4.0),
        desal = SIRENOpt.with(result.design.desal; plant_power_kw = 3.0),
    )
    @test updated.wind_gen.generator_model === result.design.wind_gen.generator_model
    @test updated.wind_conv.converter_model === result.design.wind_conv.converter_model
    @test updated.battery.storage_model === result.design.battery.storage_model
    @test updated.h2.h2_model === result.design.h2.h2_model
    @test updated.desal.desal_model === result.design.desal.desal_model
end

@testset "Mooring platform adapter" begin
    ph = mooring_parameter_handler(
        line_count = 2,
        water_depth_m = 100.0,
        fairlead_depth_m = 20.0,
        anchor_radius_m = 120.0,
        line_length_m = 160.0,
        segment_area_m2 = 0.01,
        segment_density_kg_per_m3 = 7850.0,
        elastic_modulus_pa = 2.1e11,
        mesh_size_m = 40.0,
    )
    @test ph isa SIRENOpt.Mooring.ParameterHandlers.ParameterHandler
    @test length(ph.lines) == 2
    @test all(p -> p.coords isa Vector{Float64}, values(ph.points))

    mooring_model = mooring_system_model(ph; damping_n_s_per_m = 50.0, constant_force_n = 10.0)
    @test mooring_model isa MooringSystemModel
    @test mooring_mass_kg(mooring_model) ≈ 2 * 7850.0 * 0.01 * 160.0
    @test mooring_heave_stiffness_n_per_m(ph) > 0
    @test mooring_restoring_force(mooring_model, 2.0, 0.5) ≈
          10.0 - mooring_model.heave_stiffness_n_per_m * 2.0 - 50.0 * 0.5

    platform = PlatformDesign{T}(base_mass = 1000.0, damping = 0.0, mooring_model = mooring_model)
    design_with_mooring = SystemDesign{T}(platform = platform)
    design_without_mooring = SystemDesign{T}(platform = SIRENOpt.with(platform; mooring_model = nothing))
    @test aggregate_mass_cost_volume(design_with_mooring).mass -
          aggregate_mass_cost_volume(design_without_mooring).mass ≈ mooring_mass_kg(mooring_model)

    @test update_platform(design_with_mooring).mooring_model === mooring_model
    @test platform_from_supported_mass(design_with_mooring).mooring_model === mooring_model
    @test SIRENOpt.with(design_with_mooring).platform.mooring_model === mooring_model
    @test design_from_x(design_with_mooring, DesignVarSpec{T}(), T[]).platform.mooring_model === mooring_model

    state = PlatformState{T}(position = 1.0, velocity = 0.0, acceleration = 0.0)
    next_state = dynamics_step(platform, state, 0.0, 1.0)
    expected_accel = mooring_restoring_force(mooring_model, state.position, state.velocity) /
                     (platform.base_mass + mooring_model.mass_kg)
    @test next_state.acceleration ≈ expected_accel
    @test next_state.acceleration < 0

    captured_force = Ref{T}(NaN)
    implicit_state = dynamics_step(
        platform,
        state,
        5.0,
        1.0;
        method = :implicit,
        solve_residual = (residual_state, residual_design, residual_force, _dt) -> begin
            captured_force[] = residual_force
            residual_mooring = mooring_restoring_force(
                residual_design.mooring_model,
                residual_state.position,
                residual_state.velocity,
            )
            return (residual_force + residual_mooring - residual_design.damping * residual_state.velocity) /
                   SIRENOpt.platform_mass(residual_design)
        end,
    )
    @test captured_force[] ≈ 5.0
    @test implicit_state.acceleration ≈ (5.0 + mooring_restoring_force(mooring_model, state.position, state.velocity)) /
                                        (platform.base_mass + mooring_model.mass_kg)

    lines = mooring_setup_lines(mooring_model)
    @test length(lines) == 2
    @test all(haskey(lines, line_id) for line_id in keys(ph.lines))
end


@testset "PVlib solar adapter" begin
    weather = PVlib.WeatherSample{Float64}(
        time = PVlib.ZonedDateTime(2020, 6, 1, 12, 0, 0, PVlib.TimeZone("America/Denver")),
        ghi = 800.0,
        dni = 900.0,
        dhi = 100.0,
        temp_air = 20.0,
        temp_dew = 10.0,
        relative_humidity = 50.0,
        pressure = 101325.0,
        wind_speed = 1.5,
        wind_direction = 180.0,
        albedo = 0.10,
    )
    solar_pos = PVlib.get_solar_position(35.1, -106.6, 1500.0, weather)
    pv_model = pvlib_solar_model(surface_tilt_deg = 35.1, surface_azimuth_deg = 180.0, altitude_m = 1500.0)
    pv_ac_model = pvlib_solar_model(
        surface_tilt_deg = 35.1,
        surface_azimuth_deg = 180.0,
        altitude_m = 1500.0,
        use_inverter_ac = true,
    )

    base_design = SystemDesign{Float64}(
        solar = SolarDesign{Float64}(area = pv_model.pv_module.area, efficiency = 1.0, pv_model = pv_model),
        solar_gen = GeneratorDesign{Float64}(rated_power = 20.0, efficiency = 1.0),
        solar_conv = ConverterDesign{Float64}(rated_power = 20.0, efficiency = 1.0),
    )
    op = SystemOperation{Float64}(
        solar = SolarOp{Float64}(resource = TimeSeries([0.0], [0.0]), pv_weather = [weather], pv_solar_position = [solar_pos]),
        load = LoadOp{Float64}(demand = TimeSeries([0.0], [0.0])),
    )

    p_dc = pvlib_solar_dc_power_kw(pv_model, base_design.solar.area, weather, solar_pos)
    @test isfinite(p_dc)
    @test p_dc > 0

    p_available = power_available_solar(base_design.solar, op.solar, 1)
    @test isapprox(p_available, p_dc; rtol = 1.0e-6)

    ac_design = SIRENOpt.with(base_design;
        solar = SIRENOpt.with(base_design.solar; pv_model = pv_ac_model))
    p_ac = pvlib_solar_ac_power_kw(pv_ac_model, ac_design.solar.area, weather, solar_pos)
    p_ac_available = power_available_solar(ac_design.solar, op.solar, 1)
    @test isfinite(p_ac)
    @test p_ac > 0
    @test isapprox(p_ac_available, p_ac; rtol = 1.0e-6)
    @test !isapprox(p_ac_available, p_dc; rtol = 1.0e-8, atol = 1.0e-10)

    p_bus = solar_power(base_design.solar, op.solar, base_design.solar_gen, op.solar_gen, base_design.solar_conv, op.solar_conv, 1)
    @test p_bus > 0
    @test isfinite(p_bus)

    solar_power_from_area(a) = begin
        design = SIRENOpt.with(base_design; solar = SIRENOpt.with(base_design.solar; area = a))
        power_available_solar(design.solar, op.solar, 1)
    end
    dpda_ad = ForwardDiff.derivative(solar_power_from_area, base_design.solar.area)
    dpda_fd = FiniteDiff.finite_difference_derivative(solar_power_from_area, base_design.solar.area, Val(:central))
    @test isfinite(dpda_ad)
    @test dpda_ad > 0
    @test isapprox(dpda_ad, dpda_fd; rtol = 1.0e-6, atol = 1.0e-8)
end
