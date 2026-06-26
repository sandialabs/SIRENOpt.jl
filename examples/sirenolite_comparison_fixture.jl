using SIRENOpt
"""
Run a fast SIRENO-lite comparison fixture from fixed CSV-derived inputs.

From the SIRENOpt.jl checkout:

    julia --project=. examples/sirenolite_comparison_fixture.jl

The reference path uses the legacy SIRENO-lite-aligned `SystemDesign` simulator.
The SIRENOpt path uses `SIRENOLiteOntology` with the same resource and load
profiles. Outputs are comparison CSVs and a small SVG intended for paper tables
without manual value copying.
"""
function run_sirenolite_comparison_fixture(;
        report_dir = joinpath(@__DIR__, "results", "sirenolite_comparison_fixture"),
        horizon_s = 180.0,
        dt_s = 60.0,
        start_hour = 12.0)

    mkpath(report_dir)
    data_path = _sirenolite_data_path()
    profiles = _comparison_profiles(data_path, horizon_s, dt_s, start_hour)
    n = Int(round(horizon_s / dt_s))
    op = _reference_operation(profiles, n)
    reference_design = _reference_design(SystemDesign{Float64}(), op, profiles)
    reference_states, reference_outputs = simulate(reference_design, op,
        profiles.dt_hours)

    scenario = _comparison_scenario(profiles, n, horizon_s, dt_s)
    ontology_system = _comparison_ontology(reference_design, scenario, profiles, n)
    ontology_result = optimize(ontology_system, scenario; formulation = Collocation())
    ontology_report_dir = joinpath(report_dir, "sirenopt_ontology_report")
    ontology_report = report(ontology_result, ontology_report_dir)

    reference_summary = _reference_summary(reference_states, reference_outputs,
        profiles.dt_hours)
    ontology_summary = _ontology_summary(ontology_result, dt_s / 3600)
    input_rows = _comparison_input_rows(data_path, profiles, reference_design,
        horizon_s, dt_s, start_hour, n)
    metric_rows = _comparison_metric_rows(reference_summary, ontology_summary)
    timeseries_rows = _comparison_timeseries(reference_states, reference_outputs,
        ontology_result.timeseries, dt_s)
    reference_timeseries_rows = _reference_timeseries(reference_states,
        reference_outputs, dt_s)
    sirenopt_timeseries_rows = _sirenopt_timeseries(ontology_result.timeseries,
        dt_s)
    model_difference_rows = _model_difference_rows(ontology_system)
    model_path_rows = _comparison_model_paths(ontology_system)

    input_path = _write_csv(joinpath(report_dir, "comparison_inputs.csv"),
        input_rows)
    summary_path = _write_csv(joinpath(report_dir, "comparison_summary.csv"),
        [reference_summary, ontology_summary])
    metrics_path = _write_csv(joinpath(report_dir, "comparison_metrics.csv"),
        metric_rows)
    difference_path = _write_csv(joinpath(report_dir, "model_differences.csv"),
        model_difference_rows)
    reference_timeseries_path = _write_csv(joinpath(report_dir,
        "sirenolite_reference_timeseries.csv"), reference_timeseries_rows)
    sirenopt_timeseries_path = _write_csv(joinpath(report_dir,
        "sirenopt_timeseries.csv"), sirenopt_timeseries_rows)
    timeseries_path = _write_csv(joinpath(report_dir, "comparison_timeseries.csv"),
        timeseries_rows)
    model_path_path = _write_csv(joinpath(report_dir, "comparison_model_paths.csv"),
        model_path_rows)
    plot_path = joinpath(report_dir, "comparison_power.svg")
    _write_comparison_svg(plot_path, timeseries_rows)

    return (
        profiles = profiles,
        scenario = scenario,
        reference_design = reference_design,
        reference_states = reference_states,
        reference_outputs = reference_outputs,
        ontology_system = ontology_system,
        ontology_result = ontology_result,
        ontology_report = ontology_report,
        reports = (
            inputs = input_path,
            summary = summary_path,
            metrics = metrics_path,
            difference = difference_path,
            reference_timeseries = reference_timeseries_path,
            sirenopt_timeseries = sirenopt_timeseries_path,
            timeseries = timeseries_path,
            model_paths = model_path_path,
            plot = plot_path,
            ontology_report_dir = ontology_report_dir,
        ),
    )
end

function _sirenolite_data_path()
    data_path = joinpath(@__DIR__, "..", "data", "sirenolite_load_resource_data.csv")
    isfile(data_path) || throw(ArgumentError("SIRENO-lite data file not found at $(data_path)."))
    return data_path
end

function _comparison_profiles(data_path, horizon_s, dt_s, start_hour)
    return short_horizon_profiles(
        data_path;
        start_hour = start_hour,
        horizon_s = horizon_s,
        dt_s = dt_s,
        seed = 17,
        peak_load_kw = 1.2,
        solar_kw_per_m2 = 0.8,
        wind_speed_range = (6.5, 8.0),
        wave_kw_per_m_range = (0.8, 1.1),
        h2_daily_demand_g = 0.0,
        water_daily_demand_l = 0.0,
        noise_frac = (solar = 0.0, wind = 0.0, wave = 0.0, load = 0.0),
    )
end

function _comparison_input_rows(data_path, profiles, design, horizon_s, dt_s,
        start_hour, n)
    rows = NamedTuple[]
    push!(rows, (
        quantity = :source_file,
        sirenolite_field = "data/sirenolite_load_resource_data.csv",
        sirenolite_unit = "CSV",
        sirenopt_field = "provenance.source_csv",
        sirenopt_unit = "path",
        conversion = "repo-relative fixed input file",
        first_sirenopt_value = data_path,
        notes = "Clean rerunnable fixture input; no external SIRENO-lite solve in default tests.",
    ))
    push!(rows, (
        quantity = :time,
        sirenolite_field = "Time",
        sirenolite_unit = "h",
        sirenopt_field = "ScenarioSpec.time_grids.main",
        sirenopt_unit = "s",
        conversion = "start_hour plus dt_s; horizon_s in seconds",
        first_sirenopt_value = start_hour * 3600,
        notes = "Default fixture uses $(n) intervals, horizon_s=$(horizon_s), dt_s=$(dt_s).",
    ))
    push!(rows, (
        quantity = :solar_resource,
        sirenolite_field = "Solar_W_shape",
        sirenolite_unit = "normalized W-shape",
        sirenopt_field = "solar_irradiance_kw_per_m2",
        sirenopt_unit = "kW/m^2",
        conversion = "normalize CSV shape and scale to 0.8 kW/m^2",
        first_sirenopt_value = profiles.solar_ts.values[1],
        notes = "Physical proxy used by both reference and ontology paths.",
    ))
    push!(rows, (
        quantity = :wind_resource,
        sirenolite_field = "Wind_W_shape",
        sirenolite_unit = "normalized W-shape",
        sirenopt_field = "wind_speed_m_s",
        sirenopt_unit = "m/s",
        conversion = "normalize CSV shape and map to 6.5-8.0 m/s",
        first_sirenopt_value = profiles.wind_ts.values[1],
        notes = "Explicitly not a parity claim with native SIRENO-lite wind equations.",
    ))
    push!(rows, (
        quantity = :wave_resource,
        sirenolite_field = "Wave_W_shape",
        sirenolite_unit = "normalized W-shape",
        sirenopt_field = "wave_power_flux_kw_per_m",
        sirenopt_unit = "kW/m",
        conversion = "normalize CSV shape and map to 0.8-1.1 kW/m",
        first_sirenopt_value = profiles.wave_ts.values[1],
        notes = "Ontology path reports the WEC as a surrogate.",
    ))
    push!(rows, (
        quantity = :load,
        sirenolite_field = "Load_W_shape",
        sirenolite_unit = "W shape",
        sirenopt_field = "load_kw",
        sirenopt_unit = "kW",
        conversion = "normalize CSV shape and scale to 1.2 kW peak",
        first_sirenopt_value = profiles.load_ts.values[1],
        notes = "Positive demand is converted to signed negative bus load internally.",
    ))
    push!(rows, (
        quantity = :battery_state,
        sirenolite_field = "battery initial SOC",
        sirenolite_unit = "fraction",
        sirenopt_field = "initial_battery_soc",
        sirenopt_unit = "fraction",
        conversion = "same value in both paths",
        first_sirenopt_value = 0.7,
        notes = "SIRENOpt positive battery power is discharge to the bus.",
    ))
    push!(rows, (
        quantity = :battery_capacity,
        sirenolite_field = "Battery capacity",
        sirenolite_unit = "kWh",
        sirenopt_field = "battery_capacity_kwh",
        sirenopt_unit = "kWh",
        conversion = "same SIRENO-lite-aligned default",
        first_sirenopt_value = design.battery.capacity_kwh,
        notes = "Used in both reference simulator and SIRENOLiteOntology.",
    ))
    push!(rows, (
        quantity = :hydrogen_demand,
        sirenolite_field = "Hydrogen_g_per_h_shape",
        sirenolite_unit = "g/h",
        sirenopt_field = "h2_demand_kg_per_h",
        sirenopt_unit = "kg/h",
        conversion = "divide by 1000; default fixture sets demand to zero",
        first_sirenopt_value = 0.0,
        notes = "Optional process demand is disabled to keep default comparison compact.",
    ))
    push!(rows, (
        quantity = :potable_water_demand,
        sirenolite_field = "PotableWater_L_per_h_shape",
        sirenolite_unit = "L/h",
        sirenopt_field = "desal_demand_m3_per_h",
        sirenopt_unit = "m^3/h",
        conversion = "divide by 1000; default fixture sets demand to zero",
        first_sirenopt_value = 0.0,
        notes = "Optional process demand is disabled to keep default comparison compact.",
    ))
    return rows
end

_slice_timeseries(ts::TimeSeries, n::Int) =
    TimeSeries(ts.t[1:n], ts.values[1:n])

function _reference_operation(profiles, n::Int)
    return SystemOperation{Float64}(
        solar = SolarOp{Float64}(resource = _slice_timeseries(profiles.solar_ts, n)),
        wind = WindOp{Float64}(
            resource = _slice_timeseries(profiles.wind_ts, n),
            air_density = 1.225),
        wave = WaveOp{Float64}(resource = _slice_timeseries(profiles.wave_ts, n)),
        load = LoadOp{Float64}(demand = _slice_timeseries(profiles.load_ts, n)),
        h2 = H2Op{Float64}(demand = TimeSeries(profiles.t_hours[1:n], zeros(n))),
        desal = DesalOp{Float64}(demand = TimeSeries(profiles.t_hours[1:n], zeros(n))),
        battery = BatteryOp{Float64}(soc_init = 0.7),
    )
end

function _reference_design(design::SystemDesign{Float64}, op, profiles)
    max_solar = maximum(op.solar.resource.values)
    max_load = maximum(op.load.demand.values)
    solar_rating = max_solar * design.solar.area * design.solar.efficiency
    batt_rate = max(design.battery.capacity_kwh, 1.0)
    return SIRENOpt.with(design;
        solar_gen = SIRENOpt.with(design.solar_gen; rated_power = solar_rating),
        solar_conv = SIRENOpt.with(design.solar_conv; rated_power = solar_rating),
        wind_gen = SIRENOpt.with(design.wind_gen; rated_power = design.wind.rated_power),
        wind_conv = SIRENOpt.with(design.wind_conv; rated_power = design.wind.rated_power),
        wave_gen = SIRENOpt.with(design.wave_gen; rated_power = design.wave.rated_power),
        wave_conv = SIRENOpt.with(design.wave_conv; rated_power = design.wave.rated_power),
        diesel_gen = SIRENOpt.with(design.diesel_gen; rated_power = design.diesel.rated_power),
        diesel_conv = SIRENOpt.with(design.diesel_conv; rated_power = design.diesel.rated_power),
        battery = SIRENOpt.with(design.battery;
            max_charge_kw = batt_rate, max_discharge_kw = batt_rate),
        battery_conv = SIRENOpt.with(design.battery_conv; rated_power = batt_rate),
        h2 = SIRENOpt.with(design.h2; electrolyzer_power_kw = 0.0),
        desal = SIRENOpt.with(design.desal; plant_power_kw = 0.0),
        load_conv = SIRENOpt.with(design.load_conv; rated_power = max_load),
        controller = SIRENOpt.with(design.controller;
            prediction_window_hours = profiles.dt_hours * 2),
    )
end

function _comparison_scenario(profiles, n::Int, horizon_s, dt_s)
    return ShortHorizonScenario(
        name = :sirenolite_comparison_fixture,
        horizon_s = horizon_s,
        dt_s = dt_s,
        solar_irradiance_kw_per_m2 = profiles.solar_ts.values[1:n],
        wind_speed_m_s = profiles.wind_ts.values[1:n],
        wave_power_flux_kw_per_m = profiles.wave_ts.values[1:n],
        load_kw = profiles.load_ts.values[1:n],
        h2_demand_kg_per_h = zeros(n),
        desal_demand_m3_per_h = zeros(n),
        initial_battery_soc = 0.7,
        provenance_note = "SIRENO-lite CSV comparison fixture",
    )
end

function _comparison_ontology(design, scenario, profiles, n::Int)
    solar_rating = maximum(profiles.solar_ts.values[1:n]) *
        design.solar.area * design.solar.efficiency
    max_load = maximum(profiles.load_ts.values[1:n])
    return SIRENOLiteOntology(
        scenario = scenario,
        include_wind = true,
        include_wave = true,
        include_diesel = true,
        solar_area_m2 = design.solar.area,
        solar_efficiency = design.solar.efficiency,
        solar_converter_rating_kw = max(solar_rating, 1.0),
        solar_converter_efficiency = design.solar_conv.efficiency,
        battery_capacity_kwh = design.battery.capacity_kwh,
        battery_power_kw = design.battery.max_discharge_kw,
        battery_charge_efficiency = design.battery.charge_efficiency,
        battery_discharge_efficiency = design.battery.discharge_efficiency,
        battery_converter_efficiency = design.battery_conv.efficiency,
        load_converter_rating_kw = max(max_load, 1.0),
        load_converter_efficiency = design.load_conv.efficiency,
        wind_rated_power_kw = design.wind.rated_power,
        wind_generator_efficiency = design.wind_gen.efficiency,
        wind_converter_efficiency = design.wind_conv.efficiency,
        wave_capture_width_m = design.wave.capture_width,
        wave_rated_power_kw = design.wave.rated_power,
        wave_converter_efficiency = design.wave_conv.efficiency,
        diesel_rated_power_kw = design.diesel.rated_power,
        diesel_fuel_tank_l = design.diesel.fuel_tank_capacity,
        diesel_fuel_per_kwh_l = design.diesel.fuel_per_kwh,
        diesel_generator_efficiency = design.diesel_gen.efficiency,
        diesel_converter_efficiency = design.diesel_conv.efficiency,
    )
end

function _reference_summary(states, outputs, dt_h)
    load_served_kwh = sum(-o.load_power_kw for o in outputs) * dt_h
    renewable_kwh = sum(o.solar_power_kw + o.wind_power_kw + o.wave_power_kw +
        o.hydrokinetic_power_kw for o in outputs) * dt_h
    diesel_kwh = sum(o.diesel_power_kw for o in outputs) * dt_h
    return (
        model = :sirenolite_reference_simulator,
        model_family = "legacy SIRENO-lite-aligned SIRENOpt simulator",
        formulation = :forward_simulation,
        intervals = length(outputs),
        load_served_kwh = load_served_kwh,
        renewable_bus_kwh = renewable_kwh,
        diesel_bus_kwh = diesel_kwh,
        final_battery_soc = states[end].battery_soc,
        max_abs_bus_residual_kw = maximum(abs(o.net_bus_power_kw) for o in outputs),
        model_path_note = "reference simulator path; no ontology registry",
    )
end

function _ontology_summary(result, dt_h)
    rows = result.timeseries
    load_served_kwh = sum(row.load_kw * row.load_served_fraction for row in rows) * dt_h
    renewable_kwh = sum(row.solar_bus_power_kw + row.wind_bus_power_kw +
        row.wave_bus_power_kw + row.hydrokinetic_bus_power_kw for row in rows) * dt_h
    diesel_kwh = sum(row.diesel_bus_power_kw for row in rows) * dt_h
    return (
        model = :sirenopt_sirenolite_ontology,
        model_family = "SIRENOpt ontology SIRENO-lite comparison fixture",
        formulation = result.formulation.name,
        intervals = length(rows),
        load_served_kwh = load_served_kwh,
        renewable_bus_kwh = renewable_kwh,
        diesel_bus_kwh = diesel_kwh,
        final_battery_soc = result.states[end].battery_soc,
        max_abs_bus_residual_kw = result.replay_summary.max_abs_bus_balance_residual_kw,
        model_path_note = "ontology registry with package-backed wind/diesel and reported wave surrogate",
    )
end

function _comparison_metric_rows(reference, ontology)
    metrics = [
        (:load_served_kwh, "kWh"),
        (:renewable_bus_kwh, "kWh"),
        (:diesel_bus_kwh, "kWh"),
        (:final_battery_soc, "fraction"),
        (:max_abs_bus_residual_kw, "kW"),
    ]
    return [(
        metric = metric,
        unit = unit,
        reference_value = getproperty(reference, metric),
        sirenopt_value = getproperty(ontology, metric),
        difference = getproperty(ontology, metric) - getproperty(reference, metric),
        tolerance = metric == :max_abs_bus_residual_kw ? 1.0e-8 : "",
        status = metric == :max_abs_bus_residual_kw &&
            getproperty(ontology, metric) <= 1.0e-8 ? :pass : :reported_difference,
        comparison_note = "Fixed input comparison; differences are model-path differences, not an improvement claim.",
    ) for (metric, unit) in metrics]
end

function _reference_timeseries(reference_states, reference_outputs, dt_s)
    rows = NamedTuple[]
    for i in eachindex(reference_outputs)
        ref = reference_outputs[i]
        push!(rows, (
            time_s = (i - 1) * dt_s,
            load_served_kw = -ref.load_power_kw,
            renewable_bus_kw = ref.solar_power_kw + ref.wind_power_kw +
                ref.wave_power_kw + ref.hydrokinetic_power_kw,
            solar_bus_power_kw = ref.solar_power_kw,
            wind_bus_power_kw = ref.wind_power_kw,
            wave_bus_power_kw = ref.wave_power_kw,
            hydrokinetic_bus_power_kw = ref.hydrokinetic_power_kw,
            diesel_bus_power_kw = ref.diesel_power_kw,
            bus_residual_kw = ref.net_bus_power_kw,
            battery_soc = reference_states[i].battery_soc,
            model_family = "legacy SIRENO-lite-aligned SIRENOpt simulator",
        ))
    end
    return rows
end

function _sirenopt_timeseries(ontology_rows, dt_s)
    rows = NamedTuple[]
    for (i, row) in enumerate(ontology_rows)
        push!(rows, (
            time_s = (i - 1) * dt_s,
            load_served_kw = row.load_kw * row.load_served_fraction,
            renewable_bus_kw = row.solar_bus_power_kw + row.wind_bus_power_kw +
                row.wave_bus_power_kw + row.hydrokinetic_bus_power_kw,
            solar_bus_power_kw = row.solar_bus_power_kw,
            wind_bus_power_kw = row.wind_bus_power_kw,
            wave_bus_power_kw = row.wave_bus_power_kw,
            hydrokinetic_bus_power_kw = row.hydrokinetic_bus_power_kw,
            diesel_bus_power_kw = row.diesel_bus_power_kw,
            bus_residual_kw = row.bus_balance_residual_kw,
            battery_soc = row.battery_soc,
            model_family = "SIRENOpt ontology SIRENO-lite comparison fixture",
        ))
    end
    return rows
end

function _comparison_timeseries(reference_states, reference_outputs, ontology_rows, dt_s)
    rows = NamedTuple[]
    for i in eachindex(ontology_rows)
        ref = reference_outputs[i]
        row = ontology_rows[i]
        push!(rows, (
            time_s = (i - 1) * dt_s,
            reference_load_served_kw = -ref.load_power_kw,
            sirenopt_load_served_kw = row.load_kw * row.load_served_fraction,
            reference_renewable_bus_kw = ref.solar_power_kw + ref.wind_power_kw +
                ref.wave_power_kw + ref.hydrokinetic_power_kw,
            sirenopt_renewable_bus_kw = row.solar_bus_power_kw +
                row.wind_bus_power_kw + row.wave_bus_power_kw +
                row.hydrokinetic_bus_power_kw,
            reference_diesel_bus_kw = ref.diesel_power_kw,
            sirenopt_diesel_bus_kw = row.diesel_bus_power_kw,
            reference_bus_residual_kw = ref.net_bus_power_kw,
            sirenopt_bus_residual_kw = row.bus_balance_residual_kw,
            reference_battery_soc = reference_states[i].battery_soc,
            sirenopt_battery_soc = row.battery_soc,
        ))
    end
    return rows
end

function _model_difference_rows(system)
    rows = NamedTuple[
        (
            category = :reference_path,
            reference_model = "legacy SIRENO-lite-aligned SIRENOpt simulator",
            sirenopt_model = string(system.ontology.name),
            affected_quantity = "all outputs",
            difference_type = "reference-vs-ontology architecture",
            units = "",
            notes = "Reference path does not use the ontology registry; SIRENOpt path reports components, ports, residuals, and model paths.",
        ),
        (
            category = :resource_mapping,
            reference_model = "SIRENO-lite CSV W-shape inputs",
            sirenopt_model = "ShortHorizonScenario physical proxies",
            affected_quantity = "solar/wind/wave/load inputs",
            difference_type = "unit conversion and normalization",
            units = "kW/m^2, m/s, kW/m, kW",
            notes = "This fixture fixes equivalent SIRENOpt-facing inputs and does not claim native SIRENO-lite equation parity.",
        ),
        (
            category = :battery_sign,
            reference_model = "legacy simulator control setpoints",
            sirenopt_model = "ontology battery command",
            affected_quantity = "battery power",
            difference_type = "sign convention documented",
            units = "kW",
            notes = "SIRENOpt positive battery power is discharge to the bus.",
        ),
    ]
    for row in model_path_table(system)
        push!(rows, (
            category = row.block == :wave_wec ? :surrogate_path : :ontology_path,
            reference_model = "legacy SIRENO-lite-aligned simulator",
            sirenopt_model = string(row.model_path),
            affected_quantity = string(row.block),
            difference_type = row.block == :wave_wec ? "reported WEC surrogate" :
                "reported ontology model path",
            units = "",
            notes = isempty(row.fallback_policy) ? row.assumptions :
                row.fallback_policy,
        ))
    end
    return rows
end

function _comparison_model_paths(system)
    return [(
        comparison_role = row.block == :wave_wec ? :reported_surrogate_difference :
            :sirenopt_model_path,
        block = row.block,
        model_path = row.model_path,
        package = row.package,
        adapter = row.adapter,
        assumptions = row.assumptions,
        fallback_policy = row.fallback_policy,
    ) for row in model_path_table(system)]
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

function _write_comparison_svg(path, rows)
    width = 780
    height = 420
    left = 76.0
    right = 210.0
    top = 42.0
    bottom = 58.0
    plot_w = width - left - right
    plot_h = height - top - bottom
    xvals = [row.time_s for row in rows]
    series = [
        (name = "reference load", values = [row.reference_load_served_kw for row in rows],
            color = "#1f77b4"),
        (name = "SIRENOpt load", values = [row.sirenopt_load_served_kw for row in rows],
            color = "#d62728"),
        (name = "reference renewables", values = [row.reference_renewable_bus_kw for row in rows],
            color = "#2ca02c"),
        (name = "SIRENOpt renewables", values = [row.sirenopt_renewable_bus_kw for row in rows],
            color = "#9467bd"),
    ]
    yvals = reduce(vcat, (item.values for item in series))
    xlo, xhi = extrema(xvals)
    ylo, yhi = extrema(yvals)
    xhi == xlo && (xhi = xlo + 1)
    if yhi == ylo
        yhi += 1
        ylo -= 1
    end
    ypad = 0.08 * (yhi - ylo)
    ylo -= ypad
    yhi += ypad
    point(x, y) = (
        left + (x - xlo) / (xhi - xlo) * plot_w,
        top + plot_h - (y - ylo) / (yhi - ylo) * plot_h,
    )
    open(path, "w") do io
        println(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 $width $height\" role=\"img\" aria-label=\"SIRENO-lite comparison power\">")
        println(io, "<rect width=\"$width\" height=\"$height\" fill=\"#ffffff\"/>")
        println(io, "<text x=\"$left\" y=\"26\" font-family=\"Arial, sans-serif\" font-size=\"17\" font-weight=\"700\" fill=\"#1f2933\">SIRENO-lite comparison fixture</text>")
        println(io, "<line x1=\"$left\" y1=\"$(top + plot_h)\" x2=\"$(left + plot_w)\" y2=\"$(top + plot_h)\" stroke=\"#334155\"/>")
        println(io, "<line x1=\"$left\" y1=\"$top\" x2=\"$left\" y2=\"$(top + plot_h)\" stroke=\"#334155\"/>")
        for item in series
            pts = String[]
            for (x, y) in zip(xvals, item.values)
                xp, yp = point(x, y)
                push!(pts, string(round(xp; digits = 2), ",", round(yp; digits = 2)))
            end
            println(io, "<polyline fill=\"none\" stroke=\"$(item.color)\" stroke-width=\"2.0\" points=\"$(join(pts, " "))\"/>")
        end
        legend_x = left + plot_w + 22
        for (i, item) in enumerate(series)
            y = top + 14 + (i - 1) * 24
            println(io, "<line x1=\"$legend_x\" y1=\"$y\" x2=\"$(legend_x + 22)\" y2=\"$y\" stroke=\"$(item.color)\" stroke-width=\"2.4\"/>")
            println(io, "<text x=\"$(legend_x + 30)\" y=\"$(y + 4)\" font-family=\"Arial, sans-serif\" font-size=\"11\" fill=\"#1f2933\">$(item.name)</text>")
        end
        println(io, "<text x=\"$(left + plot_w / 2)\" y=\"398\" text-anchor=\"middle\" font-family=\"Arial, sans-serif\" font-size=\"12\" fill=\"#334155\">time_s</text>")
        println(io, "<text transform=\"translate(20 $(top + plot_h / 2)) rotate(-90)\" text-anchor=\"middle\" font-family=\"Arial, sans-serif\" font-size=\"12\" fill=\"#334155\">kW</text>")
        println(io, "</svg>")
    end
    return path
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_sirenolite_comparison_fixture()
    println("SIRENO-lite comparison fixture")
    println("  intervals: ", length(result.ontology_result.timeseries))
    println("  feasible ontology replay: ",
        result.ontology_result.replay_summary.feasible)
    println("  reports:")
    for path in values(result.reports)
        println("    ", path)
    end
end
