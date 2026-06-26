using SIRENOpt

"""
Run ontology/block-API equivalents of the legacy SNOW examples.

From the SIRENOpt.jl checkout:

    julia --project=. examples/snow_examples_block_api.jl

This migration fixture does not call SNOW. It preserves the example intent with
ontology builders, registry-backed formulation metadata, standard reports, and
replay residual summaries so the old hand-packed examples have a block-API path.
"""
function run_snow_examples_block_api(;
        report_dir = joinpath(@__DIR__, "results", "snow_examples_block_api"))
    mkpath(report_dir)
    cases = [
        _balanced_bus_case(report_dir),
        _short_horizon_case(report_dir),
        _three_minute_package_case(report_dir),
        _prescribed_motion_case(report_dir),
        _pendulum_codesign_case(report_dir),
    ]
    summary_path = _write_csv(joinpath(report_dir, "snow_block_api_summary.csv"),
        [_case_summary(case) for case in cases])
    return (
        cases = cases,
        summary = summary_path,
    )
end

function _balanced_bus_case(report_dir)
    scenario = ShortHorizonScenario(
        name = :balanced_bus_block_api,
        horizon_s = 2 * 3600.0,
        dt_s = 3600.0,
        solar_irradiance_kw_per_m2 = [0.5, 0.2],
        load_kw = [1.0, 1.0],
        initial_battery_soc = 0.7,
        provenance_note = "block-API migration of balanced_electric_bus_demo",
    )
    system = MinimalEnergyOntology(
        scenario = scenario,
        solar_area_m2 = 10.0,
        battery_capacity_kwh = 5.0,
        battery_power_kw = 3.0)
    return _run_migrated_case(
        :balanced_electric_bus_demo,
        :balanced_bus_block_api,
        system,
        scenario,
        report_dir)
end

function _short_horizon_case(report_dir)
    scenario = ShortHorizonScenario(
        name = :short_horizon_snow_block_api,
        horizon_s = 3 * 60.0,
        dt_s = 60.0,
        solar_irradiance_kw_per_m2 = [0.15, 0.12, 0.10],
        wind_speed_m_s = [8.0, 8.2, 8.1],
        wave_power_flux_kw_per_m = [1.0, 1.1, 1.0],
        load_kw = [1.2, 1.2, 1.2],
        initial_battery_soc = 0.7,
        provenance_note = "block-API migration of short_horizon_snow",
    )
    system = PackageBackedHybridOntology(
        scenario = scenario,
        solar_area_m2 = 12.0,
        battery_capacity_kwh = 6.0,
        battery_power_kw = 3.0,
        wind_rated_power_kw = 4.0,
        wave_rated_power_kw = 2.0)
    return _run_migrated_case(
        :short_horizon_snow,
        :short_horizon_snow_block_api,
        system,
        scenario,
        report_dir)
end

function _three_minute_package_case(report_dir)
    scenario = ShortHorizonScenario(
        name = :three_minute_package_snow_block_api,
        horizon_s = 3 * 60.0,
        dt_s = 60.0,
        solar_irradiance_kw_per_m2 = [0.05, 0.05, 0.05],
        wind_speed_m_s = [7.0, 7.5, 8.0],
        wave_power_flux_kw_per_m = [0.8, 0.9, 0.8],
        hydrokinetic_current_m_s = [2.0, 2.0, 2.0],
        load_kw = [0.1, 0.1, 0.1],
        initial_battery_soc = 0.7,
        provenance_note = "block-API migration of three_minute_package_snow",
    )
    system = PackageBackedHybridOntology(
        scenario = scenario,
        include_hydrokinetic = true,
        solar_area_m2 = 4.0,
        battery_capacity_kwh = 1.0,
        battery_power_kw = 0.5,
        wind_rated_power_kw = 1.0,
        wave_rated_power_kw = 0.5,
        hydrokinetic_rated_power_kw = 1.0,
        hydrokinetic_rotor_diameter_m = 1.0)
    return _run_migrated_case(
        :three_minute_package_snow,
        :three_minute_package_snow_block_api,
        system,
        scenario,
        report_dir)
end

function _prescribed_motion_case(report_dir)
    scenario = ShortHorizonScenario(
        name = :prescribed_motion_dynamic_io_block_api,
        horizon_s = 3 * 60.0,
        dt_s = 60.0,
        solar_irradiance_kw_per_m2 = [0.1, 0.1, 0.1],
        wind_speed_m_s = [7.5, 7.5, 7.5],
        wave_power_flux_kw_per_m = [1.0, 1.0, 1.0],
        load_kw = [1.0, 1.0, 1.0],
        initial_battery_soc = 0.7,
        provenance_note = "block-API migration of prescribed_motion_dynamic_io",
    )
    system = DynamicMultilevelHybridOntology(
        scenario = scenario,
        solar_area_m2 = 10.0,
        battery_capacity_kwh = 5.0,
        battery_power_kw = 3.0,
        wind_rated_power_kw = 3.0,
        wave_rated_power_kw = 2.0,
        platform_inertia_kg_m2 = 1.0e5,
        platform_stiffness_nm_per_rad = 0.0,
        platform_damping_nm_s_per_rad = 0.0,
        wind_platform_moment_per_kw_nm = 250.0)
    return _run_migrated_case(
        :prescribed_motion_dynamic_io,
        :prescribed_motion_dynamic_io_block_api,
        system,
        scenario,
        report_dir)
end

function _pendulum_codesign_case(report_dir)
    scenario = ShortHorizonScenario(
        name = :pendulum_platform_codesign_snow_block_api,
        horizon_s = 3 * 60.0,
        dt_s = 60.0,
        solar_irradiance_kw_per_m2 = [0.1, 0.1, 0.1],
        wind_speed_m_s = [8.0, 8.0, 8.0],
        wave_power_flux_kw_per_m = [1.0, 1.0, 1.0],
        hydrokinetic_current_m_s = [2.0, 2.0, 2.0],
        load_kw = [1.5, 1.5, 1.5],
        initial_battery_soc = 0.7,
        provenance_note = "block-API migration of pendulum_platform_codesign_snow",
    )
    system = DynamicMultilevelHybridOntology(
        scenario = scenario,
        include_hydrokinetic = true,
        solar_area_m2 = 10.0,
        battery_capacity_kwh = 5.0,
        battery_power_kw = 3.0,
        wind_rated_power_kw = 4.0,
        wave_rated_power_kw = 2.0,
        hydrokinetic_rated_power_kw = 3.0,
        hydrokinetic_rotor_diameter_m = 2.0,
        platform_inertia_kg_m2 = 1.0e5,
        platform_stiffness_nm_per_rad = 0.0,
        platform_damping_nm_s_per_rad = 0.0,
        wind_platform_moment_per_kw_nm = 500.0)
    return _run_migrated_case(
        :pendulum_platform_codesign_snow,
        :pendulum_platform_codesign_snow_block_api,
        system,
        scenario,
        report_dir)
end

function _run_migrated_case(legacy_example, migrated_name, system, scenario,
        report_root)
    formulation = Collocation()
    result = optimize(system, scenario; formulation = formulation)
    case_dir = joinpath(report_root, string(migrated_name))
    reported = report(result, case_dir)
    return (
        legacy_example = legacy_example,
        migrated_name = migrated_name,
        system = system,
        scenario = scenario,
        formulation = formulation,
        result = result,
        report = reported,
        report_dir = case_dir,
    )
end

function _case_summary(case)
    model_paths = model_path_table(case.system)
    package_blocks = [row.block for row in model_paths if row.model_path == :package_backed]
    surrogate_blocks = [row.block for row in model_paths if row.model_path == :surrogate]
    grid = case.scenario.time_grids.main
    return (
        legacy_example = case.legacy_example,
        migrated_name = case.migrated_name,
        ontology = case.system.ontology.name,
        formulation = case.formulation.name,
        formulation_method = case.formulation.variant,
        horizon_s = grid.horizon_s,
        dt_s = grid.dt_s,
        intervals = length(case.result.timeseries),
        package_backed_blocks = join(string.(package_blocks), "; "),
        surrogate_blocks = join(string.(surrogate_blocks), "; "),
        model_path_report = joinpath(case.report_dir, "model_paths.csv"),
        component_report = joinpath(case.report_dir, "components.csv"),
        replay_residual_report = joinpath(case.report_dir, "replay_residuals.csv"),
        feasible_replay = case.result.replay_summary.feasible,
        max_registered_constraint_violation =
            case.result.replay_summary.max_registered_constraint_violation,
    )
end

function _csv_escape(x)
    s = string(x === nothing ? "" : x)
    if occursin(',', s) || occursin('"', s) || occursin('\n', s)
        return "\"" * replace(s, "\"" => "\"\"") * "\""
    end
    return s
end

function _write_csv(path::AbstractString, rows::Vector)
    open(path, "w") do io
        if isempty(rows)
            println(io)
            return
        end
        headers = collect(keys(first(rows)))
        println(io, join(string.(headers), ","))
        for row in rows
            println(io, join((_csv_escape(getproperty(row, h)) for h in headers), ","))
        end
    end
    return path
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_snow_examples_block_api()
    println("SNOW block-API migration summary: ", result.summary)
    for case in result.cases
        println("  ", case.legacy_example, " -> ", case.migrated_name,
            " feasible=", case.result.replay_summary.feasible)
    end
end
