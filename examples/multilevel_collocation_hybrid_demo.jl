using SIRENOpt

"""
Run the fast V1 multi-level ontology acceptance demo.

From the SIRENOpt.jl checkout:

    julia --project=. examples/multilevel_collocation_hybrid_demo.jl

The active graph contains wind, wave/WEC, hydrokinetic, solar, battery, load,
bus, generator, converter, and a reduced pendulum platform fallback. Reports
identify package paths and substitutions in `model_paths.csv` and
`level_maps.csv`.

Set `SIRENOPT_ONTOLOGY_LONG_HORIZON=1` to run the longer opt-in daily
resource sweep. The default stays at three one-minute intervals so this example
is suitable for fast checks and documentation builds.
"""
function run_multilevel_collocation_hybrid_demo(;
        report_dir = joinpath(@__DIR__, "results", "multilevel_collocation_hybrid_demo"),
        long_horizon = _demo_env_flag("SIRENOPT_ONTOLOGY_LONG_HORIZON"))
    scenario = _multilevel_demo_scenario(long_horizon)
    sizing = _multilevel_demo_sizing(long_horizon)

    system = DynamicMultilevelHybridOntology(
        scenario = scenario,
        solar_area_m2 = sizing.solar_area_m2,
        include_hydrokinetic = true,
        battery_capacity_kwh = sizing.battery_capacity_kwh,
        battery_power_kw = sizing.battery_power_kw,
        wind_rated_power_kw = sizing.wind_rated_power_kw,
        wave_capture_width_m = sizing.wave_capture_width_m,
        wave_rated_power_kw = sizing.wave_rated_power_kw,
        hydrokinetic_rated_power_kw = sizing.hydrokinetic_rated_power_kw,
        hydrokinetic_rotor_diameter_m = sizing.hydrokinetic_rotor_diameter_m,
        platform_inertia_kg_m2 = sizing.platform_inertia_kg_m2,
        platform_stiffness_nm_per_rad = sizing.platform_stiffness_nm_per_rad,
        platform_damping_nm_s_per_rad = sizing.platform_damping_nm_s_per_rad,
        wind_platform_moment_per_kw_nm = sizing.wind_platform_moment_per_kw_nm,
    )

    description = describe(system)
    formulation = Collocation(terminal_soc_equal_initial = true)
    system_audit = audit(system, scenario; formulation = formulation)
    simulation = simulate(system, scenario; controller = RuleBasedController())
    model = assemble(system, scenario, formulation)
    optimization = optimize(system, scenario; formulation = formulation)
    replayed = replay(optimization)
    reported = report(optimization, report_dir)

    derivative_checks = _multilevel_derivative_checks(model, optimization.solution_x)
    derivative_path = joinpath(report_dir, "derivative_checks.csv")
    _write_derivative_checks(derivative_path, derivative_checks)
    acceptance_reports = _write_multilevel_acceptance_reports(report_dir,
        system, scenario, optimization, derivative_checks;
        long_horizon = long_horizon)

    motion_feedback_delta_kw =
        optimization.timeseries[1].wind_available_power_kw -
        optimization.timeseries[end].wind_available_power_kw

    return (
        system = system,
        scenario = scenario,
        description = description,
        audit = system_audit,
        simulation = simulation,
        model = model,
        optimization = optimization,
        replay = replayed,
        report = reported,
        derivative_checks = derivative_checks,
        derivative_report = derivative_path,
        acceptance_reports = acceptance_reports,
        motion_feedback_delta_kw = motion_feedback_delta_kw,
    )
end

function _multilevel_demo_sizing(long_horizon::Bool)
    if long_horizon
        return (
            solar_area_m2 = 24.0,
            battery_capacity_kwh = 18.0,
            battery_power_kw = 6.0,
            wind_rated_power_kw = 8.0,
            wave_capture_width_m = 2.0,
            wave_rated_power_kw = 4.0,
            hydrokinetic_rated_power_kw = 8.0,
            hydrokinetic_rotor_diameter_m = 3.0,
            platform_inertia_kg_m2 = 1.0e12,
            platform_stiffness_nm_per_rad = 1.0e4,
            platform_damping_nm_s_per_rad = 1.0e6,
            wind_platform_moment_per_kw_nm = 10.0,
        )
    end
    return (
        solar_area_m2 = 10.0,
        battery_capacity_kwh = 5.0,
        battery_power_kw = 3.0,
        wind_rated_power_kw = 4.0,
        wave_capture_width_m = 2.0,
        wave_rated_power_kw = 2.0,
        hydrokinetic_rated_power_kw = 3.0,
        hydrokinetic_rotor_diameter_m = 2.0,
        platform_inertia_kg_m2 = 1.0e5,
        platform_stiffness_nm_per_rad = 0.0,
        platform_damping_nm_s_per_rad = 0.0,
        wind_platform_moment_per_kw_nm = 500.0,
    )
end

function _demo_env_flag(name::AbstractString)
    value = lowercase(get(ENV, name, "0"))
    return value in ("1", "true", "yes", "on")
end

function _multilevel_demo_scenario(long_horizon::Bool)
    if long_horizon
        n = 24
        hours = collect(0:(n - 1))
        solar = [max(0.0, 0.85 * sin(pi * (h - 6) / 12)) for h in hours]
        wind = [7.5 + 1.5 * sin(2pi * h / 24) for h in hours]
        wave = [1.0 + 0.25 * cos(2pi * h / 12) for h in hours]
        current = [2.4 + 0.1 * sin(2pi * h / 6) for h in hours]
        load = [1.0 + 0.25 * (h in 17:22 ? 1.0 : 0.0) for h in hours]
        return ShortHorizonScenario(
            name = :multilevel_daily_horizon,
            horizon_s = n * 3600.0,
            dt_s = 3600.0,
            solar_irradiance_kw_per_m2 = solar,
            wind_speed_m_s = wind,
            wave_power_flux_kw_per_m = wave,
            hydrokinetic_current_m_s = current,
            load_kw = load,
            initial_battery_soc = 0.7,
            provenance_note = "opt-in daily multi-level ontology resource sweep",
        )
    end
    return ShortHorizonScenario(
        name = :multilevel_short_horizon,
        horizon_s = 3 * 60.0,
        dt_s = 60.0,
        solar_irradiance_kw_per_m2 = [0.1, 0.1, 0.1],
        wind_speed_m_s = [8.0, 8.0, 8.0],
        wave_power_flux_kw_per_m = [1.0, 1.0, 1.0],
        hydrokinetic_current_m_s = [2.0, 2.0, 2.0],
        load_kw = [1.5, 1.5, 1.5],
        initial_battery_soc = 0.7,
        provenance_note = "fast multi-level ontology acceptance fixture",
    )
end

function _registry_index(model, owner::Symbol, name::Symbol; time_index = nothing)
    for entry in model.registry.variables
        entry.owner == owner || continue
        entry.name == name || continue
        entry.time_index == time_index || continue
        return first(entry.index_range)
    end
    return nothing
end

function _central_difference_norm(model, x, idx; h = 1e-5)
    idx === nothing && return NaN
    xp = copy(x)
    xm = copy(x)
    xp[idx] += h
    xm[idx] -= h
    dc = (evaluate_constraints(model, xp) .- evaluate_constraints(model, xm)) ./ (2h)
    return maximum(abs.(dc))
end

function _constraint_violation(model, x)
    c = evaluate_constraints(model, x)
    return max(maximum(model.constraint_lower_bounds .- c),
        maximum(c .- model.constraint_upper_bounds))
end

function _multilevel_derivative_checks(model, x)
    checks = NamedTuple[]
    wind_idx = _registry_index(model, :wind_rotor, :wind_rated_power_kw)
    theta_idx = _registry_index(model, :platform, :platform_theta_rad; time_index = 3)
    inertia_idx = _registry_index(model, :platform, :platform_inertia_kg_m2)
    served_idx = _registry_index(model, :load, :load_served_fraction; time_index = 1)
    push!(checks, (
        boundary = :design_to_level1_wind,
        producing_level = "design variables",
        consuming_level = "Level 1 motion/resource physics",
        method = "central finite difference of registered constraints",
        owner = :wind_rotor,
        variable = :wind_rated_power_kw,
        time_index = "",
        index = wind_idx,
        max_abs_dc_dx = _central_difference_norm(model, x, wind_idx),
    ))
    push!(checks, (
        boundary = :level1_motion_to_source,
        producing_level = "Level 1 motion/resource physics",
        consuming_level = "Level 2 dispatch contract",
        method = "central finite difference of registered constraints",
        owner = :platform,
        variable = :platform_theta_rad,
        time_index = 3,
        index = theta_idx,
        max_abs_dc_dx = _central_difference_norm(model, x, theta_idx),
    ))
    push!(checks, (
        boundary = :design_to_level1_platform,
        producing_level = "design variables",
        consuming_level = "Level 1 motion/resource physics",
        method = "central finite difference of registered constraints",
        owner = :platform,
        variable = :platform_inertia_kg_m2,
        time_index = "",
        index = inertia_idx,
        max_abs_dc_dx = _central_difference_norm(model, x, inertia_idx),
    ))
    push!(checks, (
        boundary = :level2_dispatch_to_level3_reliability,
        producing_level = "Level 2 dispatch contract",
        consuming_level = "Level 3 hourly reliability table",
        method = "central finite difference of registered constraints",
        owner = :load,
        variable = :load_served_fraction,
        time_index = 1,
        index = served_idx,
        max_abs_dc_dx = _central_difference_norm(model, x, served_idx),
    ))
    push!(checks, (
        boundary = :constraint_bounds,
        producing_level = "registered collocation residuals",
        consuming_level = "replay residual audit",
        method = "bound violation on replayed registered constraints",
        owner = :system,
        variable = :all_constraints,
        time_index = "",
        index = "",
        max_abs_dc_dx = _constraint_violation(model, x),
    ))
    return checks
end

function _write_derivative_checks(path, checks)
    open(path, "w") do io
        println(io, "boundary,producing_level,consuming_level,method,owner,variable,time_index,index,max_abs_dc_dx")
        for row in checks
            println(io, join((
                row.boundary,
                row.producing_level,
                row.consuming_level,
                row.method,
                row.owner,
                row.variable,
                row.time_index,
                row.index,
                row.max_abs_dc_dx,
            ), ","))
        end
    end
    return path
end

function _csv_escape(x)
    s = string(x === nothing ? "" : x)
    if occursin(',', s) || occursin('"', s) || occursin('\n', s)
        return "\"" * replace(s, "\"" => "\"\"") * "\""
    end
    return s
end

function _write_demo_csv(path::AbstractString, rows::Vector{<:NamedTuple})
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

function _map_metadata_rows(system)
    rows = NamedTuple[]
    for row in level_map_table(system)
        push!(rows, (
            map_name = Symbol(string(row.block), "_contract"),
            producing_level = row.producing_level,
            consuming_level = row.consuming_level,
            block = row.block,
            quantity = row.quantity,
            unit = row.unit,
            design_dependencies = row.design_dependencies,
            scenario_dependencies = row.scenario_dependencies,
            state_dependencies = row.state_dependencies,
            valid_range = row.valid_range,
            interpolation_method = row.interpolation_method,
            sensitivity_method = row.sensitivity_method,
            verification_case = row.verification_case,
            active_bound_report = row.active_bound_report,
            model_path = row.model_path,
            package = row.package,
            adapter = row.adapter,
            replacement_target = row.replacement_target,
            fallback_policy = row.fallback_policy,
            substitution_reason = row.substitution_reason,
        ))
    end
    return rows
end

function _level1_summary_rows(system)
    level1_blocks = Set([:wind_rotor, :wave_wec, :hydrokinetic_rotor, :platform])
    return [row for row in _map_metadata_rows(system) if row.block in level1_blocks]
end

function _critical_load_fraction(system)
    for block in system.blocks
        block.name == :load || continue
        :critical_fraction in keys(block.parameters) || return 1.0
        return Float64(block.parameters.critical_fraction)
    end
    return 1.0
end

function _level2_dynamic_event_rows(result)
    rows = NamedTuple[]
    for row in result.timeseries
        push!(rows, (
            time_s = row.time_s,
            platform_theta_rad = row.platform_theta_rad,
            platform_omega_rad_s = row.platform_omega_rad_s,
            platform_pitch_moment_nm = row.platform_pitch_moment_nm,
            platform_dynamic_residual_rad_s = row.platform_dynamic_residual_rad_s,
            wind_available_power_kw = row.wind_available_power_kw,
            wind_bus_power_kw = row.wind_bus_power_kw,
            wave_bus_power_kw = row.wave_bus_power_kw,
            hydrokinetic_bus_power_kw = row.hydrokinetic_bus_power_kw,
            battery_soc = row.battery_soc,
            load_served_fraction = row.load_served_fraction,
            bus_balance_residual_kw = row.bus_balance_residual_kw,
        ))
    end
    return rows
end

function _resource_bin(row)
    if row.solar_irradiance_kw_per_m2 > 0.5
        return "solar_high"
    elseif row.wind_speed_m_s >= 8.0
        return "wind_high"
    elseif row.hydrokinetic_current_m_s >= 2.0
        return "current_high"
    end
    return "mixed_low"
end

function _level3_reliability_rows(result)
    critical_fraction = _critical_load_fraction(result.system)
    dt_s = result.scenario.time_grids.main.dt_s
    rows = NamedTuple[]
    for (i, row) in enumerate(result.timeseries)
        served_kw = row.load_kw * row.load_served_fraction
        push!(rows, (
            bin_index = i,
            bin_duration_s = dt_s,
            resource_bin = _resource_bin(row),
            solar_irradiance_kw_per_m2 = row.solar_irradiance_kw_per_m2,
            wind_speed_m_s = row.wind_speed_m_s,
            wave_power_flux_kw_per_m = row.wave_power_flux_kw_per_m,
            hydrokinetic_current_m_s = row.hydrokinetic_current_m_s,
            load_kw = row.load_kw,
            served_load_kw = served_kw,
            unserved_load_kw = max(row.load_kw - served_kw, 0.0),
            served_fraction = row.load_served_fraction,
            critical_fraction = critical_fraction,
            reliability_margin = row.load_served_fraction - critical_fraction,
            max_abs_bus_residual_kw = abs(row.bus_balance_residual_kw),
            battery_soc = row.battery_soc,
        ))
    end
    return rows
end

function _result_metadata_rows(scenario, result, derivative_checks; long_horizon::Bool)
    return [
        (name = :scenario, value = scenario.name, unit = "", source = "ScenarioSpec"),
        (name = :horizon_s, value = scenario.time_grids.main.horizon_s, unit = "s", source = "TimeGrid"),
        (name = :dt_s, value = scenario.time_grids.main.dt_s, unit = "s", source = "TimeGrid"),
        (name = :intervals, value = length(result.timeseries), unit = "count", source = "replay"),
        (name = :formulation, value = result.formulation.name, unit = "", source = "FormulationSpec"),
        (name = :solver, value = result.solver.name, unit = "", source = "ResultSpec"),
        (name = :feasible, value = result.replay_summary.feasible, unit = "bool", source = "replay_summary"),
        (name = :max_registered_constraint_violation, value = result.replay_summary.max_registered_constraint_violation, unit = "", source = "replay_summary"),
        (name = :derivative_checks, value = length(derivative_checks), unit = "count", source = "derivative_checks.csv"),
        (name = :long_horizon_env_gate, value = long_horizon, unit = "bool", source = "SIRENOPT_ONTOLOGY_LONG_HORIZON"),
    ]
end

function _write_multilevel_acceptance_reports(report_dir, system, scenario, result,
        derivative_checks; long_horizon::Bool)
    map_metadata = joinpath(report_dir, "map_metadata.csv")
    level1_summary = joinpath(report_dir, "level1_map_summary.csv")
    level2_event = joinpath(report_dir, "level2_dynamic_event.csv")
    level3_reliability = joinpath(report_dir, "level3_reliability_bins.csv")
    result_metadata = joinpath(report_dir, "result_metadata.csv")
    manuscript_summary = joinpath(report_dir, "manuscript_summary_table.csv")
    manuscript_manifest = joinpath(report_dir, "manuscript_figure_manifest.csv")
    _write_demo_csv(map_metadata, _map_metadata_rows(system))
    _write_demo_csv(level1_summary, _level1_summary_rows(system))
    _write_demo_csv(level2_event, _level2_dynamic_event_rows(result))
    _write_demo_csv(level3_reliability, _level3_reliability_rows(result))
    _write_demo_csv(result_metadata,
        _result_metadata_rows(scenario, result, derivative_checks;
            long_horizon = long_horizon))
    _write_demo_csv(manuscript_summary, _manuscript_summary_rows(result))
    _write_demo_csv(manuscript_manifest, _manuscript_figure_manifest_rows(report_dir))
    return (
        map_metadata = map_metadata,
        level1_map_summary = level1_summary,
        level2_dynamic_event = level2_event,
        level3_reliability_bins = level3_reliability,
        result_metadata = result_metadata,
        manuscript_summary = manuscript_summary,
        manuscript_figure_manifest = manuscript_manifest,
    )
end

function _manuscript_summary_rows(result)
    rows = result.timeseries
    dt_h = result.scenario.time_grids.main.dt_s / 3600
    served_kwh = sum(row.load_kw * row.load_served_fraction for row in rows) * dt_h
    renewable_kwh = sum(row.solar_bus_power_kw + row.wind_bus_power_kw +
        row.wave_bus_power_kw + row.hydrokinetic_bus_power_kw for row in rows) * dt_h
    return [
        (metric = :served_load, value = served_kwh, unit = "kWh",
            source_file = "timeseries.csv",
            table_note = "sum(load_kw * load_served_fraction * dt_h)"),
        (metric = :renewable_bus_energy, value = renewable_kwh, unit = "kWh",
            source_file = "timeseries.csv",
            table_note = "solar + wind + wave + hydrokinetic bus energy"),
        (metric = :max_registered_constraint_violation,
            value = result.replay_summary.max_registered_constraint_violation,
            unit = "scaled residual",
            source_file = "replay_residuals.csv",
            table_note = "registered collocation constraints reconstructed in replay"),
        (metric = :terminal_battery_soc,
            value = result.states[end].battery_soc,
            unit = "fraction",
            source_file = "states.csv",
            table_note = "terminal SOC residual active in final acceptance formulation"),
        (metric = :platform_pitch_range,
            value = maximum(row.platform_theta_rad for row in rows) -
                minimum(row.platform_theta_rad for row in rows),
            unit = "rad",
            source_file = "level2_dynamic_event.csv",
            table_note = "reduced pendulum motion envelope"),
    ]
end

function _manuscript_figure_manifest_rows(report_dir)
    rows = NamedTuple[]
    artifacts = [
        ("plot_power_kw.svg", :power_figure, "standard report SVG"),
        ("plot_platform_motion_rad.svg", :platform_motion_figure, "standard report SVG"),
        ("level1_map_summary.csv", :level1_table, "map contract table"),
        ("level2_dynamic_event.csv", :level2_table, "dynamic event table"),
        ("level3_reliability_bins.csv", :level3_table, "binned reliability table"),
        ("manuscript_summary_table.csv", :summary_table, "manuscript metric table"),
    ]
    for (filename, role, note) in artifacts
        push!(rows, (
            artifact = filename,
            role = role,
            path = joinpath(report_dir, filename),
            generated_from_checked_result = isfile(joinpath(report_dir, filename)),
            note = note,
        ))
    end
    return rows
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_multilevel_collocation_hybrid_demo()
    println("ontology: ", result.system.ontology.name)
    println("blocks: ", length(result.description.component_table))
    println("variables: ", length(result.audit.variable_table))
    println("residuals: ", length(result.audit.residual_table))
    println("optimization replay: ", result.optimization.replay_summary)
    println("motion feedback delta kW: ", result.motion_feedback_delta_kw)
    println("derivative checks:")
    for row in result.derivative_checks
        println("  ", row)
    end
    println("report files:")
    for path in vcat(result.report.reports, [result.derivative_report],
            collect(values(result.acceptance_reports)))
        println("  ", path)
    end
end
