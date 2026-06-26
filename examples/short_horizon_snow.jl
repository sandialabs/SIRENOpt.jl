"""
Short-horizon AD SNOW optimization with variable SIRENO-Lite-derived profiles.

This example uses noisy high-resolution profiles derived from the SIRENO-Lite
CSV data and optimizes stable subsystem design variables plus block-wise
curtailment, diesel, battery, hydrogen, and desalination controls.
Defaults are intentionally compact so ForwardAD derivatives remain practical;
set SIRENO_SHORT_HORIZON_S and SIRENO_SHORT_DT_S to scale up.

Requires:
  - SNOW.jl
  - Ipopt.jl
  - Snopt.jl for the default solver, with automatic fallback to Ipopt

Run from the SIRENOpt.jl checkout with:
  julia --project=examples examples/short_horizon_snow.jl

The script also activates examples/Project.toml automatically when it is run
from an IDE in Julia's default @v#.# environment. Do not `dev ./SIRENOpt.jl`
into a global/default environment for this example; use the examples project so
the local package stack and compat bounds are isolated from other packages such
as REopt.

Useful environment controls:
  - SIRENO_SHORT_SOLVER=snopt|ipopt
  - SIRENO_SHORT_DERIVATIVES=ad|fd
  - SIRENO_SHORT_DESIGN_VARS=stable|all|none|solar_area,...
  - SIRENO_SHORT_CONTROL_VARS=stable|all|none|battery_power_kw,diesel_power_kw,...
  - SIRENO_SHORT_SCALE_<VARIABLE_NAME>=...
  - SIRENO_SHORT_LB_<VARIABLE_NAME>=...
  - SIRENO_SHORT_UB_<VARIABLE_NAME>=...
  - SIRENO_SHORT_LOG_DIR=examples/solver_logs
"""

import Pkg
using Dates

const SHORT_HORIZON_PROJECT = @__DIR__

function activate_short_horizon_project()
    project_file = joinpath(SHORT_HORIZON_PROJECT, "Project.toml")
    if Base.active_project() != project_file
        Pkg.activate(SHORT_HORIZON_PROJECT; io = devnull)
    end
    return project_file
end

function load_short_horizon_packages()
    try
        @eval using SIRENOpt
        @eval using SNOW
        @eval using Ipopt
        @eval using OptimizationParameters
        @eval import ForwardDiff
        @eval import Plots
    catch err
        project_file = joinpath(SHORT_HORIZON_PROJECT, "Project.toml")
        script_file = joinpath(SHORT_HORIZON_PROJECT, "short_horizon_snow.jl")
        println(stderr,
            "Failed to load short_horizon_snow.jl dependencies from $(project_file).\n" *
            "Instantiate the examples environment once with:\n" *
            "  julia --project=$(SHORT_HORIZON_PROJECT) -e 'import Pkg; Pkg.instantiate()'\n" *
            "Then run:\n" *
            "  julia --project=$(SHORT_HORIZON_PROJECT) $(script_file)")
        rethrow(err)
    end
end

activate_short_horizon_project()
load_short_horizon_packages()

ENV["GKSwstype"] = "100"

const PLOT_CYCLE = [
    "#348ABD",
    "#A60628",
    "#009E73",
    "#7A68A6",
    "#D55E00",
    "#CC79A7",
]

Plots.default(
    size = (400, 300),
    dpi = 150,
    linewidth = 1.5,
    markersize = 3,
    legend = :best,
    legend_foreground_color = nothing,
    foreground_color_legend = nothing,
    background_color_legend = nothing,
    framestyle = :axes,
    grid = false,
    guidefontsize = 10,
    tickfontsize = 10,
    legendfontsize = 10,
    titlefontsize = 10,
    left_margin = 18Plots.mm,
    right_margin = 6Plots.mm,
    bottom_margin = 10Plots.mm,
    top_margin = 5Plots.mm,
    palette = PLOT_CYCLE,
)

const HAS_SNOPT = try
    @eval using Snopt
    true
catch err
    @warn "Snopt.jl is not available; falling back to Ipopt when requested" exception = err
    false
end

const T = Float64

_smooth_replay_scalar(x::Real) = ForwardDiff.Dual{Nothing}(Float64(x), 0.0)
_smooth_replay_vector(xs) = [_smooth_replay_scalar(x) for x in xs]
_real_value(x::ForwardDiff.Dual) = ForwardDiff.value(x)
_real_value(x::Real) = Float64(x)

const COST = (
    solar_per_m2 = 334.0,
    wind_per_kw = 4000.0,
    wave_per_kw = 2000.0,
    wave_per_m = 1500.0,
    hydro_per_kw = 5000.0,
    diesel_per_kw = 400.0,
    battery_per_kwh = 300.0,
    h2_electrolyzer_per_kw = 1500.0,
    h2_tank_per_kg = 35.0,
    desal_per_kw = 2500.0,
    desal_tank_per_m3 = 750.0,
)

const OBJECTIVE_SCALE = 1.0e3
const BUS_DROOP_GAIN = parse(Float64, get(ENV, "SIRENO_SHORT_BUS_DROOP_GAIN", "0.005"))

data_path = joinpath(@__DIR__, "..", "data", "sirenolite_load_resource_data.csv")
if !isfile(data_path)
    error("SIRENO-Lite data file not found at $(data_path).")
end

profiles = short_horizon_profiles(
    data_path;
    start_hour = parse(Float64, get(ENV, "SIRENO_SHORT_START_HOUR", "24.0")),
    horizon_s = parse(Float64, get(ENV, "SIRENO_SHORT_HORIZON_S", "20.0")),
    dt_s = parse(Float64, get(ENV, "SIRENO_SHORT_DT_S", "0.05")),
    seed = parse(Int, get(ENV, "SIRENO_SHORT_SEED", "11")),
    peak_load_kw = parse(Float64, get(ENV, "SIRENO_SHORT_PEAK_LOAD_KW", "20.0")),
    h2_daily_demand_g = parse(Float64, get(ENV, "SIRENO_SHORT_H2_RATE_GPH", "400.0")),
    water_daily_demand_l = parse(Float64, get(ENV, "SIRENO_SHORT_WATER_RATE_LPH", "265.0")),
    noise_frac = (solar = 0.10, wind = 0.18, wave = 0.15, load = 0.07),
)

load_ts = profiles.load_ts

hydro_unit = profiles.wave_ts.values ./ max(maximum(profiles.wave_ts.values), eps(T))
hydro_time_s = (profiles.t_hours .- first(profiles.t_hours)) .* 3600.0
hydro_values = clamp.(0.55 .+ 1.25 .* hydro_unit .+ 0.08 .* sin.(2π .* hydro_time_s ./ 7.0), 0.2, 2.5)
hydro_ts = TimeSeries(profiles.t_hours, hydro_values)

N = length(profiles.t_hours)
dt_hours = profiles.dt_hours
block_s = 1.0
block = max(1, Int(round(block_s / (dt_hours * 3600))))
nb = cld(N, block)
block_t = collect(T, 1:nb)

function block_average(values)
    averaged = Vector{T}(undef, nb)
    counts = zeros(T, nb)
    fill!(averaged, zero(T))
    for k in 1:N
        b = Int(cld(k, block))
        averaged[b] += values[k]
        counts[b] += 1
    end
    for b in 1:nb
        averaged[b] /= counts[b]
    end
    return averaged, counts
end

solar_block, block_counts = block_average(profiles.solar_ts.values)
wind_block, _ = block_average(profiles.wind_ts.values)
wave_block, _ = block_average(profiles.wave_ts.values)
hydro_block, _ = block_average(hydro_ts.values)
load_block, _ = block_average(load_ts.values)
h2_block, _ = block_average(profiles.h2_ts.values)
desal_block, _ = block_average(profiles.desal_ts.values)
dt_block_hours = block_counts .* dt_hours

op = SystemOperation{T}(
    solar = SolarOp{T}(resource = profiles.solar_ts),
    wind = WindOp{T}(resource = profiles.wind_ts, air_density = 1.225),
    wave = WaveOp{T}(resource = profiles.wave_ts),
    hydrokinetic = HydrokineticOp{T}(resource = hydro_ts, fluid_density = 1025.0),
    load = LoadOp{T}(demand = load_ts),
    h2 = H2Op{T}(demand = profiles.h2_ts),
    desal = DesalOp{T}(demand = profiles.desal_ts),
    battery = BatteryOp{T}(soc_init = 0.7),
)

op_blocks = SystemOperation{T}(
    solar = SolarOp{T}(resource = TimeSeries(block_t, solar_block)),
    wind = WindOp{T}(resource = TimeSeries(block_t, wind_block), air_density = 1.225),
    wave = WaveOp{T}(resource = TimeSeries(block_t, wave_block)),
    hydrokinetic = HydrokineticOp{T}(resource = TimeSeries(block_t, hydro_block), fluid_density = 1025.0),
    load = LoadOp{T}(demand = TimeSeries(block_t, load_block)),
    h2 = H2Op{T}(demand = TimeSeries(block_t, h2_block)),
    desal = DesalOp{T}(demand = TimeSeries(block_t, desal_block)),
    battery = BatteryOp{T}(soc_init = op.battery.soc_init),
)

function prepare_design(design::SystemDesign, op::SystemOperation)
    max_solar = maximum(op.solar.resource.values)
    max_load = maximum(op.load.demand.values)
    solar_rating = max_solar * design.solar.area * design.solar.efficiency
    batt_rate = smooth_max(design.battery.capacity_kwh, oftype(design.battery.capacity_kwh, 1.0))

    return SIRENOpt.with(design;
        solar_gen = SIRENOpt.with(design.solar_gen; rated_power = solar_rating),
        solar_conv = SIRENOpt.with(design.solar_conv; rated_power = solar_rating),
        wind_gen = SIRENOpt.with(design.wind_gen; rated_power = design.wind.rated_power),
        wind_conv = SIRENOpt.with(design.wind_conv; rated_power = design.wind.rated_power),
        wave_gen = SIRENOpt.with(design.wave_gen; rated_power = design.wave.rated_power),
        wave_conv = SIRENOpt.with(design.wave_conv; rated_power = design.wave.rated_power),
        hydrokinetic_gen = SIRENOpt.with(design.hydrokinetic_gen; rated_power = design.hydrokinetic.rated_power),
        hydrokinetic_conv = SIRENOpt.with(design.hydrokinetic_conv; rated_power = design.hydrokinetic.rated_power),
        diesel_gen = SIRENOpt.with(design.diesel_gen; rated_power = design.diesel.rated_power),
        diesel_conv = SIRENOpt.with(design.diesel_conv; rated_power = design.diesel.rated_power),
        battery = SIRENOpt.with(design.battery; max_charge_kw = batt_rate, max_discharge_kw = batt_rate),
        battery_conv = SIRENOpt.with(design.battery_conv; rated_power = batt_rate),
        h2_conv = SIRENOpt.with(design.h2_conv; rated_power = design.h2.electrolyzer_power_kw),
        desal_conv = SIRENOpt.with(design.desal_conv; rated_power = design.desal.plant_power_kw),
        load_conv = SIRENOpt.with(design.load_conv; rated_power = max_load),
        bus = BusDesign{typeof(max_load)}(
            voltage_nominal = oftype(max_load, 1.0),
            voltage_min = oftype(max_load, 0.95),
            voltage_max = oftype(max_load, 1.05),
            droop_gain = oftype(max_load, BUS_DROOP_GAIN)),
        controller = SIRENOpt.with(design.controller; prediction_window_hours = dt_hours * 200),
    )
end

base_design = prepare_design(SystemDesign{T}(), op)
base_design = SIRENOpt.with(base_design; platform = platform_from_supported_mass(base_design))

const STABLE_DESIGN_VAR_NAMES = (
    :solar_area,
    :wind_rotor_diameter,
    :wind_rated_power,
    :hydrokinetic_rotor_diameter,
    :hydrokinetic_rated_power,
    :diesel_rated_power,
    :battery_capacity_kwh,
    :h2_electrolyzer_power_kw,
    :h2_tank_capacity_kg,
    :desal_plant_power_kw,
    :desal_tank_capacity_m3,
)
const WEC_DESIGN_VAR_NAMES = (:wave_capture_width, :wave_rated_power)
const ALL_DESIGN_VAR_NAMES = (STABLE_DESIGN_VAR_NAMES..., WEC_DESIGN_VAR_NAMES...)

const STABLE_CONTROL_VAR_NAMES = (
    :solar_curtailment,
    :wind_curtailment,
    :hydrokinetic_curtailment,
    :diesel_power_kw,
    :battery_power_kw,
    :h2_power_kw,
    :desal_power_kw,
)
const WEC_CONTROL_VAR_NAMES = (:wave_curtailment,)
const ALL_CONTROL_VAR_NAMES = (STABLE_CONTROL_VAR_NAMES..., WEC_CONTROL_VAR_NAMES...)

function env_float(name::AbstractString, default::Real)
    return parse(Float64, get(ENV, name, string(default)))
end

env_name(prefix::AbstractString, name::Symbol) = string(prefix, uppercase(String(name)))
variable_lower(name::Symbol, default::Real) = env_float(env_name("SIRENO_SHORT_LB_", name), default)
variable_upper(name::Symbol, default::Real) = env_float(env_name("SIRENO_SHORT_UB_", name), default)
variable_scaling(name::Symbol, default::Real) = env_float(env_name("SIRENO_SHORT_SCALE_", name), default)

function parse_enabled_symbols(env_key::AbstractString, default_group::Tuple, all_names::Tuple;
    groups = (; stable = default_group, all = all_names, none = ()))

    raw = strip(get(ENV, env_key, "stable"))
    isempty(raw) && return Symbol[]
    key = Symbol(lowercase(raw))
    if hasproperty(groups, key)
        return collect(getproperty(groups, key))
    end
    names = [Symbol(strip(name)) for name in split(raw, ",") if !isempty(strip(name))]
    unknown = setdiff(names, collect(all_names))
    isempty(unknown) || error("Unknown $(env_key) entries: $(unknown). Valid entries: $(collect(all_names))")
    return names
end

enabled_design_var_names = parse_enabled_symbols(
    "SIRENO_SHORT_DESIGN_VARS",
    STABLE_DESIGN_VAR_NAMES,
    ALL_DESIGN_VAR_NAMES,
)
is_design_var_enabled(name::Symbol) = name in enabled_design_var_names

required_h2_power_guess = maximum(
    (value_at(op_blocks.h2.demand, b) * base_design.h2.specific_energy_kwh_per_kg
        for b in 1:nb);
    init = zero(T),
)
required_desal_power_guess = maximum(
    (value_at(op_blocks.desal.demand, b) * base_design.desal.specific_energy_kwh_per_m3
        for b in 1:nb);
    init = zero(T),
)
h2_electrolyzer_initial = min(
    max(base_design.h2.electrolyzer_power_kw, required_h2_power_guess),
    variable_upper(:h2_electrolyzer_power_kw, 30.0),
)
desal_plant_initial = min(
    max(base_design.desal.plant_power_kw, required_desal_power_guess),
    variable_upper(:desal_plant_power_kw, 30.0),
)

design_parameters = (
    solar_area = OptimizationParameter(base_design.solar.area;
        lb = variable_lower(:solar_area, 0.0), ub = variable_upper(:solar_area, 600.0),
        scaling = variable_scaling(:solar_area, 1.0 / 100.0),
        dv = is_design_var_enabled(:solar_area), description = "Solar collection area (m^2)"),
    wind_rotor_diameter = OptimizationParameter(base_design.wind.rotor_diameter;
        lb = variable_lower(:wind_rotor_diameter, 1.0), ub = variable_upper(:wind_rotor_diameter, 45.0),
        scaling = variable_scaling(:wind_rotor_diameter, 1.0 / 20.0),
        dv = is_design_var_enabled(:wind_rotor_diameter), description = "Wind rotor diameter (m)"),
    wind_rated_power = OptimizationParameter(base_design.wind.rated_power;
        lb = variable_lower(:wind_rated_power, 0.0), ub = variable_upper(:wind_rated_power, 200.0),
        scaling = variable_scaling(:wind_rated_power, 1.0 / 50.0),
        dv = is_design_var_enabled(:wind_rated_power), description = "Wind rated power (kW)"),
    wave_capture_width = OptimizationParameter(base_design.wave.capture_width;
        lb = variable_lower(:wave_capture_width, 0.0), ub = variable_upper(:wave_capture_width, 120.0),
        scaling = variable_scaling(:wave_capture_width, 1.0 / 50.0),
        dv = is_design_var_enabled(:wave_capture_width), description = "Wave capture width (m), disabled by default"),
    wave_rated_power = OptimizationParameter(base_design.wave.rated_power;
        lb = variable_lower(:wave_rated_power, 0.0), ub = variable_upper(:wave_rated_power, 200.0),
        scaling = variable_scaling(:wave_rated_power, 1.0 / 50.0),
        dv = is_design_var_enabled(:wave_rated_power), description = "Wave/WEC rated power (kW), disabled by default"),
    hydrokinetic_rotor_diameter = OptimizationParameter(base_design.hydrokinetic.rotor_diameter;
        lb = variable_lower(:hydrokinetic_rotor_diameter, 0.5), ub = variable_upper(:hydrokinetic_rotor_diameter, 12.0),
        scaling = variable_scaling(:hydrokinetic_rotor_diameter, 1.0 / 5.0),
        dv = is_design_var_enabled(:hydrokinetic_rotor_diameter), description = "Hydrokinetic rotor diameter (m)"),
    hydrokinetic_rated_power = OptimizationParameter(max(base_design.hydrokinetic.rated_power, 10.0);
        lb = variable_lower(:hydrokinetic_rated_power, 0.0), ub = variable_upper(:hydrokinetic_rated_power, 150.0),
        scaling = variable_scaling(:hydrokinetic_rated_power, 1.0 / 40.0),
        dv = is_design_var_enabled(:hydrokinetic_rated_power), description = "Hydrokinetic rated power (kW)"),
    diesel_rated_power = OptimizationParameter(base_design.diesel.rated_power;
        lb = variable_lower(:diesel_rated_power, 0.0), ub = variable_upper(:diesel_rated_power, 200.0),
        scaling = variable_scaling(:diesel_rated_power, 1.0 / 50.0),
        dv = is_design_var_enabled(:diesel_rated_power), description = "Diesel rated power (kW)"),
    battery_capacity_kwh = OptimizationParameter(base_design.battery.capacity_kwh;
        lb = variable_lower(:battery_capacity_kwh, 0.1), ub = variable_upper(:battery_capacity_kwh, 50.0),
        scaling = variable_scaling(:battery_capacity_kwh, 1.0 / 10.0),
        dv = is_design_var_enabled(:battery_capacity_kwh), description = "Battery capacity (kWh)"),
    h2_electrolyzer_power_kw = OptimizationParameter(h2_electrolyzer_initial;
        lb = variable_lower(:h2_electrolyzer_power_kw, 0.0), ub = variable_upper(:h2_electrolyzer_power_kw, 30.0),
        scaling = variable_scaling(:h2_electrolyzer_power_kw, 1.0 / 10.0),
        dv = is_design_var_enabled(:h2_electrolyzer_power_kw), description = "Hydrogen electrolyzer power (kW)"),
    h2_tank_capacity_kg = OptimizationParameter(base_design.h2.tank_capacity_kg;
        lb = variable_lower(:h2_tank_capacity_kg, 0.01), ub = variable_upper(:h2_tank_capacity_kg, 250.0),
        scaling = variable_scaling(:h2_tank_capacity_kg, 1.0 / 100.0),
        dv = is_design_var_enabled(:h2_tank_capacity_kg), description = "Hydrogen tank capacity (kg)"),
    desal_plant_power_kw = OptimizationParameter(desal_plant_initial;
        lb = variable_lower(:desal_plant_power_kw, 0.0), ub = variable_upper(:desal_plant_power_kw, 30.0),
        scaling = variable_scaling(:desal_plant_power_kw, 1.0 / 10.0),
        dv = is_design_var_enabled(:desal_plant_power_kw), description = "Desalination plant power (kW)"),
    desal_tank_capacity_m3 = OptimizationParameter(base_design.desal.tank_capacity_m3;
        lb = variable_lower(:desal_tank_capacity_m3, 0.01), ub = variable_upper(:desal_tank_capacity_m3, 250.0),
        scaling = variable_scaling(:desal_tank_capacity_m3, 1.0 / 100.0),
        dv = is_design_var_enabled(:desal_tank_capacity_m3), description = "Potable-water tank capacity (m^3)"),
)

function active_design_varspec(parameters)
    vars = DesignVar{T}[]
    for name in propertynames(parameters)
        get_dv(parameters, name) || continue
        push!(vars, DesignVar{T}(
            name = name,
            initial = get_x0(parameters, name),
            lower = get_lb(parameters, name),
            upper = get_ub(parameters, name),
        ))
    end
    return DesignVarSpec{T}(vars = vars)
end

varspec = active_design_varspec(design_parameters)

function design_from_scaled_x(base_design::SystemDesign, varspec::DesignVarSpec, parameters, xd)
    values = get_values(parameters, xd)
    physical_x = [getproperty(values, v.name) for v in varspec.vars]
    return design_from_x(base_design, varspec, physical_x)
end

function upper_or_fixed(parameters, name::Symbol, fixed_value)
    return get_dv(parameters, name) ? get_ub(parameters, name) : fixed_value
end

enabled_control_var_names = parse_enabled_symbols(
    "SIRENO_SHORT_CONTROL_VARS",
    STABLE_CONTROL_VAR_NAMES,
    ALL_CONTROL_VAR_NAMES,
)
is_control_var_enabled(name::Symbol) = name in enabled_control_var_names

control_parameters = (
    solar_curtailment = OptimizationParameter(0.0;
        lb = variable_lower(:solar_curtailment, 0.0), ub = variable_upper(:solar_curtailment, 1.0),
        scaling = variable_scaling(:solar_curtailment, 1.0),
        dv = is_control_var_enabled(:solar_curtailment), description = "Solar curtailment fraction"),
    wind_curtailment = OptimizationParameter(0.0;
        lb = variable_lower(:wind_curtailment, 0.0), ub = variable_upper(:wind_curtailment, 1.0),
        scaling = variable_scaling(:wind_curtailment, 1.0),
        dv = is_control_var_enabled(:wind_curtailment), description = "Wind curtailment fraction"),
    wave_curtailment = OptimizationParameter(0.0;
        lb = variable_lower(:wave_curtailment, 0.0), ub = variable_upper(:wave_curtailment, 1.0),
        scaling = variable_scaling(:wave_curtailment, 1.0),
        dv = is_control_var_enabled(:wave_curtailment), description = "Wave curtailment fraction, disabled by default"),
    hydrokinetic_curtailment = OptimizationParameter(0.0;
        lb = variable_lower(:hydrokinetic_curtailment, 0.0), ub = variable_upper(:hydrokinetic_curtailment, 1.0),
        scaling = variable_scaling(:hydrokinetic_curtailment, 1.0),
        dv = is_control_var_enabled(:hydrokinetic_curtailment), description = "Hydrokinetic curtailment fraction"),
    load_served_fraction = OptimizationParameter(1.0;
        lb = 1.0, ub = 1.0,
        scaling = variable_scaling(:load_served_fraction, 1.0),
        dv = false, description = "Fixed full-load service in constrained formulation"),
    diesel_power_kw = OptimizationParameter(0.0;
        lb = variable_lower(:diesel_power_kw, 0.0), ub = variable_upper(:diesel_power_kw, upper_or_fixed(design_parameters, :diesel_rated_power, base_design.diesel.rated_power)),
        scaling = variable_scaling(:diesel_power_kw, 1.0 / 50.0),
        dv = is_control_var_enabled(:diesel_power_kw), description = "Diesel dispatch command (kW)"),
    battery_power_kw = OptimizationParameter(0.0;
        lb = variable_lower(:battery_power_kw, -upper_or_fixed(design_parameters, :battery_capacity_kwh, base_design.battery.capacity_kwh)),
        ub = variable_upper(:battery_power_kw, upper_or_fixed(design_parameters, :battery_capacity_kwh, base_design.battery.capacity_kwh)),
        scaling = variable_scaling(:battery_power_kw, 1.0 / 10.0),
        dv = is_control_var_enabled(:battery_power_kw), description = "Battery command, positive discharge (kW)"),
    h2_power_kw = OptimizationParameter(0.0;
        lb = variable_lower(:h2_power_kw, 0.0), ub = variable_upper(:h2_power_kw, upper_or_fixed(design_parameters, :h2_electrolyzer_power_kw, base_design.h2.electrolyzer_power_kw)),
        scaling = variable_scaling(:h2_power_kw, 1.0 / 10.0),
        dv = is_control_var_enabled(:h2_power_kw), description = "Electrolyzer power command (kW)"),
    desal_power_kw = OptimizationParameter(0.0;
        lb = variable_lower(:desal_power_kw, 0.0), ub = variable_upper(:desal_power_kw, upper_or_fixed(design_parameters, :desal_plant_power_kw, base_design.desal.plant_power_kw)),
        scaling = variable_scaling(:desal_power_kw, 1.0 / 10.0),
        dv = is_control_var_enabled(:desal_power_kw), description = "Desalination power command (kW)"),
)

active_control_names = [name for name in propertynames(control_parameters) if get_dv(control_parameters, name)]
n_control_active = length(active_control_names)

function active_control_values(parameters, xc, b::Int)
    if n_control_active == 0
        return get_values(parameters, T[])
    end
    i0 = (b - 1) * n_control_active + 1
    return get_values(parameters, view(xc, i0:(i0 + n_control_active - 1)))
end

function scaled_control_guess_and_bounds(parameters, physical_initials::NamedTuple, nb::Int)
    x0_one, lx_one, ux_one = assemble_input(parameters)
    x0 = Vector{T}(undef, nb * length(x0_one))
    lx = repeat(T.(lx_one), nb)
    ux = repeat(T.(ux_one), nb)
    for b in 1:nb
        local_values = map(propertynames(parameters)) do name
            value = hasproperty(physical_initials, name) ? getproperty(physical_initials, name)[b] : get_x0(parameters, name)
            OptimizationParameter(value;
                lb = get_lb(parameters, name), ub = get_ub(parameters, name),
                scaling = get_scaling(parameters, name), dv = get_dv(parameters, name))
        end
        local_named = NamedTuple{propertynames(parameters)}(local_values)
        xb, _, _ = assemble_input(local_named)
        i0 = (b - 1) * length(x0_one) + 1
        x0[i0:(i0 + length(x0_one) - 1)] .= T.(xb)
    end
    return x0, lx, ux
end

n_design = length(varspec.vars)
idx_design = 1:n_design
idx_control = (last(idx_design) + 1):(last(idx_design) + n_control_active * nb)
idx_soc = (last(idx_control) + 1):(last(idx_control) + nb + 1)
idx_h2 = (last(idx_soc) + 1):(last(idx_soc) + nb + 1)
idx_desal = (last(idx_h2) + 1):(last(idx_h2) + nb + 1)

function unpack(x)
    xd = view(x, idx_design)
    xc = view(x, idx_control)
    soc = view(x, idx_soc)
    h2_level = view(x, idx_h2)
    desal_level = view(x, idx_desal)
    return xd, xc, soc, h2_level, desal_level
end

function control_setpoints_from_values(values)
    Tcmd = promote_type((typeof(getproperty(values, name)) for name in propertynames(values))...)
    return ControlSetpoints{Tcmd}(
        convert(Tcmd, values.solar_curtailment),
        convert(Tcmd, values.wind_curtailment),
        convert(Tcmd, values.wave_curtailment),
        convert(Tcmd, values.hydrokinetic_curtailment),
        one(Tcmd),
        convert(Tcmd, values.diesel_power_kw),
        convert(Tcmd, values.battery_power_kw),
        convert(Tcmd, values.h2_power_kw),
        convert(Tcmd, values.desal_power_kw),
    )
end

function block_controller(xc, block)
    return (design, op, state, k, dt_hours) -> begin
        b = Int(cld(k, block))
        return control_setpoints_from_values(active_control_values(control_parameters, xc, b))
    end
end

function capital_cost(design::SystemDesign)
    return COST.solar_per_m2 * design.solar.area +
        COST.wind_per_kw * design.wind.rated_power +
        COST.wave_per_kw * design.wave.rated_power +
        COST.wave_per_m * design.wave.capture_width +
        COST.hydro_per_kw * design.hydrokinetic.rated_power +
        COST.diesel_per_kw * design.diesel.rated_power +
        COST.battery_per_kwh * design.battery.capacity_kwh +
        COST.h2_electrolyzer_per_kw * design.h2.electrolyzer_power_kw +
        COST.h2_tank_per_kg * design.h2.tank_capacity_kg +
        COST.desal_per_kw * design.desal.plant_power_kw +
        COST.desal_tank_per_m3 * design.desal.tank_capacity_m3
end

clamp_nonnegative(command, capacity) = smooth_min(smooth_max(command, zero(command)), capacity)
h2_production_kg(design::H2Design, power_kw, dt_hours) = power_kw * dt_hours / design.specific_energy_kwh_per_kg
desal_production_m3(design::DesalDesign, power_kw, dt_hours) = power_kw * dt_hours / design.specific_energy_kwh_per_m3

n_init = 3
n_dyn_soc = nb
n_dyn_h2 = nb
n_dyn_desal = nb
n_power = nb
n_diesel = nb
n_batt = 2nb
n_h2_cap = nb
n_desal_cap = nb
n_h2_storage = nb
n_desal_storage = nb
ng = n_init + n_dyn_soc + n_dyn_h2 + n_dyn_desal + n_power + n_diesel + n_batt + n_h2_cap + n_desal_cap + n_h2_storage + n_desal_storage

function obj!(g, x)
    xd, xc, soc, h2_level, desal_level = unpack(x)
    design = prepare_design(design_from_scaled_x(base_design, varspec, design_parameters, xd), op_blocks)
    design = SIRENOpt.with(design; platform = platform_from_supported_mass(design))

    g[1] = soc[1] - op_blocks.battery.soc_init
    g[2] = h2_level[1] - op_blocks.h2.tank_level_kg
    g[3] = desal_level[1] - op_blocks.desal.tank_level_m3
    g_soc_start = n_init + 1
    g_h2_start = g_soc_start + n_dyn_soc
    g_desal_start = g_h2_start + n_dyn_h2
    g_power_start = g_desal_start + n_dyn_desal
    g_diesel_start = g_power_start + n_power
    g_batt_start = g_diesel_start + n_diesel
    g_h2_cap_start = g_batt_start + n_batt
    g_desal_cap_start = g_h2_cap_start + n_h2_cap
    g_h2_storage_start = g_desal_cap_start + n_desal_cap
    g_desal_storage_start = g_h2_storage_start + n_h2_storage

    total_fuel = zero(eltype(x))

    for b in 1:nb
        dtb = dt_block_hours[b]
        control_values = active_control_values(control_parameters, xc, b)

        solar_op = SolarOp{typeof(control_values.solar_curtailment)}(
            resource = op_blocks.solar.resource,
            curtailment = control_values.solar_curtailment,
            pv_weather = op_blocks.solar.pv_weather,
            pv_solar_position = op_blocks.solar.pv_solar_position)
        wind_op = WindOp{typeof(control_values.wind_curtailment)}(
            resource = op_blocks.wind.resource,
            air_density = op_blocks.wind.air_density + zero(control_values.wind_curtailment),
            curtailment = control_values.wind_curtailment)
        wave_op = WaveOp{typeof(control_values.wave_curtailment)}(
            resource = op_blocks.wave.resource,
            curtailment = control_values.wave_curtailment)
        hydro_op = HydrokineticOp{typeof(control_values.hydrokinetic_curtailment)}(
            resource = op_blocks.hydrokinetic.resource,
            fluid_density = op_blocks.hydrokinetic.fluid_density + zero(control_values.hydrokinetic_curtailment),
            curtailment = control_values.hydrokinetic_curtailment)

        p_solar = solar_power(design.solar, solar_op, design.solar_gen, op_blocks.solar_gen,
            design.solar_conv, op_blocks.solar_conv, b)
        p_wind = wind_power(design.wind, wind_op, design.wind_gen, op_blocks.wind_gen,
            design.wind_conv, op_blocks.wind_conv, b)
        p_wave = wave_power(design.wave, wave_op, design.wave_gen, op_blocks.wave_gen,
            design.wave_conv, op_blocks.wave_conv, b)
        p_hydro = hydrokinetic_power(design.hydrokinetic, hydro_op,
            design.hydrokinetic_gen, op_blocks.hydrokinetic_gen,
            design.hydrokinetic_conv, op_blocks.hydrokinetic_conv, b)
        p_diesel, fuel_used = diesel_power(design.diesel, op_blocks.diesel,
            design.diesel_gen, op_blocks.diesel_gen,
            design.diesel_conv, op_blocks.diesel_conv, control_values.diesel_power_kw, dtb)
        soc_next, p_batt_device = battery_step(design.battery, op_blocks.battery,
            soc[b], control_values.battery_power_kw, dtb)
        p_batt = converter_output(design.battery_conv, op_blocks.battery_conv, p_batt_device)
        p_load = converter_output(design.load_conv, op_blocks.load_conv,
            -load_demand(design.load, op_blocks.load, b))
        h2_power_device = clamp_nonnegative(control_values.h2_power_kw, design.h2.electrolyzer_power_kw)
        p_h2 = converter_output(design.h2_conv, op_blocks.h2_conv, -h2_power_device)
        desal_power_device = clamp_nonnegative(control_values.desal_power_kw, design.desal.plant_power_kw)
        p_desal = converter_output(design.desal_conv, op_blocks.desal_conv, -desal_power_device)

        h2_demand = value_at(op_blocks.h2.demand, b) * dtb
        desal_demand = value_at(op_blocks.desal.demand, b) * dtb
        h2_production = h2_production_kg(design.h2, h2_power_device, dtb)
        desal_production = desal_production_m3(design.desal, desal_power_device, dtb)
        h2_next = h2_level[b] + h2_production - h2_demand
        desal_next = desal_level[b] + desal_production - desal_demand

        g[g_soc_start + b - 1] = soc[b + 1] - soc_next
        g[g_h2_start + b - 1] = h2_level[b + 1] - h2_next
        g[g_desal_start + b - 1] = desal_level[b + 1] - desal_next
        g[g_power_start + b - 1] = p_solar + p_wind + p_wave + p_hydro + p_diesel + p_batt + p_load + p_h2 + p_desal
        g[g_diesel_start + b - 1] = design.diesel.rated_power - control_values.diesel_power_kw
        g[g_batt_start + 2b - 2] = design.battery.max_discharge_kw - control_values.battery_power_kw
        g[g_batt_start + 2b - 1] = design.battery.max_charge_kw + control_values.battery_power_kw
        g[g_h2_cap_start + b - 1] = design.h2.electrolyzer_power_kw - control_values.h2_power_kw
        g[g_desal_cap_start + b - 1] = design.desal.plant_power_kw - control_values.desal_power_kw
        g[g_h2_storage_start + b - 1] = design.h2.tank_capacity_kg - h2_level[b + 1]
        g[g_desal_storage_start + b - 1] = design.desal.tank_capacity_m3 - desal_level[b + 1]

        total_fuel += fuel_used
    end

    objective_value = capital_cost(design) + 200.0 * total_fuel
    return objective_value / OBJECTIVE_SCALE
end

# -------------------------
# Initial guess + bounds
# -------------------------

xd0, lx_design, ux_design = assemble_input(design_parameters)

u_solar_curt0 = zeros(T, nb)
u_wind_curt0 = zeros(T, nb)
u_wave_curt0 = zeros(T, nb)
u_hydro_curt0 = zeros(T, nb)
u_batt0 = zeros(T, nb)
u_diesel0 = zeros(T, nb)
u_h2_0 = zeros(T, nb)
u_desal0 = zeros(T, nb)
counts = zeros(T, nb)
soc0 = fill(op_blocks.battery.soc_init, nb + 1)
h2_level0 = fill(op_blocks.h2.tank_level_kg, nb + 1)
desal_level0 = fill(op_blocks.desal.tank_level_m3, nb + 1)

design0 = prepare_design(design_from_scaled_x(base_design, varspec, design_parameters, xd0), op_blocks)
for b in 1:nb
    dtb = dt_block_hours[b]
    p_solar = solar_power(design0.solar, op_blocks.solar, design0.solar_gen, op_blocks.solar_gen,
        design0.solar_conv, op_blocks.solar_conv, b)
    p_wind = wind_power(design0.wind, op_blocks.wind, design0.wind_gen, op_blocks.wind_gen,
        design0.wind_conv, op_blocks.wind_conv, b)
    p_wave = wave_power(design0.wave, op_blocks.wave, design0.wave_gen, op_blocks.wave_gen,
        design0.wave_conv, op_blocks.wave_conv, b)
    p_hydro = hydrokinetic_power(design0.hydrokinetic, op_blocks.hydrokinetic,
        design0.hydrokinetic_gen, op_blocks.hydrokinetic_gen,
        design0.hydrokinetic_conv, op_blocks.hydrokinetic_conv, b)
    u_h2_0[b] = min(
        design0.h2.electrolyzer_power_kw,
        value_at(op_blocks.h2.demand, b) * design0.h2.specific_energy_kwh_per_kg,
    )
    u_desal0[b] = min(
        design0.desal.plant_power_kw,
        value_at(op_blocks.desal.demand, b) * design0.desal.specific_energy_kwh_per_m3,
    )
    p_load_bus = converter_output(design0.load_conv, op_blocks.load_conv,
        -load_demand(design0.load, op_blocks.load, b))
    demand = -p_load_bus + u_h2_0[b] + u_desal0[b]
    deficit = max(zero(T), demand - (p_solar + p_wind + p_wave + p_hydro))
    u_diesel0[b] += min(deficit, design0.diesel.rated_power)
    h2_level0[b + 1] = h2_level0[b] + h2_production_kg(design0.h2, u_h2_0[b], dtb) - value_at(op_blocks.h2.demand, b) * dtb
    desal_level0[b + 1] = desal_level0[b] + desal_production_m3(design0.desal, u_desal0[b], dtb) - value_at(op_blocks.desal.demand, b) * dtb
    counts[b] += 1
end
for b in 1:nb
    if counts[b] > 0
        u_diesel0[b] /= counts[b]
    end
end

control_initials = (
    solar_curtailment = u_solar_curt0,
    wind_curtailment = u_wind_curt0,
    wave_curtailment = u_wave_curt0,
    hydrokinetic_curtailment = u_hydro_curt0,
    diesel_power_kw = u_diesel0,
    battery_power_kw = u_batt0,
    h2_power_kw = u_h2_0,
    desal_power_kw = u_desal0,
)
xc0, lx_control, ux_control = scaled_control_guess_and_bounds(control_parameters, control_initials, nb)

x0 = vcat(xd0, xc0, soc0, h2_level0, desal_level0)

h2_level_upper = upper_or_fixed(design_parameters, :h2_tank_capacity_kg, base_design.h2.tank_capacity_kg)
desal_level_upper = upper_or_fixed(design_parameters, :desal_tank_capacity_m3, base_design.desal.tank_capacity_m3)

lx = vcat(lx_design, lx_control, fill(0.0, nb + 1), fill(0.0, nb + 1), fill(0.0, nb + 1))
ux = vcat(ux_design, ux_control, fill(1.0, nb + 1), fill(h2_level_upper, nb + 1), fill(desal_level_upper, nb + 1))

lg = vcat(
    zeros(n_init + n_dyn_soc + n_dyn_h2 + n_dyn_desal + n_power),
    zeros(n_diesel + n_batt + n_h2_cap + n_desal_cap + n_h2_storage + n_desal_storage),
)
ug = vcat(
    zeros(n_init + n_dyn_soc + n_dyn_h2 + n_dyn_desal + n_power),
    fill(Inf, n_diesel + n_batt + n_h2_cap + n_desal_cap + n_h2_storage + n_desal_storage),
)

# -------------------------
# Solve
# -------------------------

max_iter = parse(Int, get(ENV, "SIRENO_SHORT_MAX_ITER", "100"))
derivative_mode = lowercase(get(ENV, "SIRENO_SHORT_DERIVATIVES", "ad"))
derivatives = derivative_mode == "fd" ? ForwardFD() : ForwardAD()
print_level = parse(Int, get(ENV, "SIRENO_SHORT_PRINT_LEVEL", "5"))
file_print_level = parse(Int, get(ENV, "SIRENO_SHORT_FILE_PRINT_LEVEL", string(max(print_level, 5))))
log_dir = get(ENV, "SIRENO_SHORT_LOG_DIR", joinpath(@__DIR__, "solver_logs"))
mkpath(log_dir)
run_stamp = Dates.format(now(), "yyyymmdd_HHMMSS")
solver_mode_requested = lowercase(get(ENV, "SIRENO_SHORT_SOLVER", HAS_SNOPT ? "snopt" : "ipopt"))
solver_mode = solver_mode_requested == "snopt" && !HAS_SNOPT ? "ipopt" : solver_mode_requested

if solver_mode == "snopt"
    snopt_print_path = joinpath(log_dir, "snopt_short_horizon_snow_$(run_stamp).out")
    snopt_summary_path = joinpath(log_dir, "snopt_short_horizon_snow_$(run_stamp).summary.out")
    println("solver: SNOPT")
    println("SNOPT print file: ", snopt_print_path)
    println("SNOPT summary file: ", snopt_summary_path)
    println("SNOPT Major print level: ", print_level)
    solver = SNOW.SNOPT(options = Dict(
        "Major iterations limit" => max_iter,
        "Print file" => snopt_print_path,
        "Summary file" => snopt_summary_path,
        "Major print level" => print_level,
        "Minor print level" => 0,
    ))
    solver_log_path = snopt_print_path
else
    solver_log_path = joinpath(log_dir, "ipopt_short_horizon_snow_$(run_stamp).out")
    println("solver: IPOPT")
    println("Ipopt log: ", solver_log_path)
    println("Ipopt print_level: ", print_level, " file_print_level: ", file_print_level)
    solver = IPOPT(Dict(
        "print_level" => print_level,
        "file_print_level" => file_print_level,
        "output_file" => solver_log_path,
        "max_iter" => max_iter,
        "bound_relax_factor" => 0.0,
        "honor_original_bounds" => "yes",
    ))
end

println("design variables: ", [v.name for v in varspec.vars])
println("design variable scaling: ",
    Dict(v.name => get_scaling(design_parameters, v.name) for v in varspec.vars))
println("control variables: ", active_control_names)
println("control variable scaling: ",
    Dict(name => get_scaling(control_parameters, name) for name in active_control_names))
println("WEC design/control variables are available with SIRENO_SHORT_DESIGN_VARS=all and SIRENO_SHORT_CONTROL_VARS=all, but are disabled by default.")
options = Options(derivatives = derivatives, solver = solver)

x_opt, f_opt, status, _ = minimize(obj!, x0, ng, lx, ux, lg, ug, options)

println("status: ", status)
println("f*: ", f_opt)
println("derivatives: ", derivative_mode == "fd" ? "ForwardFD" : "ForwardAD")
println("solver log: ", solver_log_path)
if solver_mode == "snopt"
    println("solver summary: ", snopt_summary_path)
end

xd_opt, xc_opt, soc_opt, h2_opt, desal_opt = unpack(x_opt)
opt_design = prepare_design(design_from_scaled_x(base_design, varspec, design_parameters, xd_opt), op)

function control_block_vector(xc, name::Symbol)
    values = Vector{T}(undef, nb)
    for b in 1:nb
        values[b] = getproperty(active_control_values(control_parameters, xc, b), name)
    end
    return values
end

u_solar_curt_opt = control_block_vector(xc_opt, :solar_curtailment)
u_wind_curt_opt = control_block_vector(xc_opt, :wind_curtailment)
u_wave_curt_opt = control_block_vector(xc_opt, :wave_curtailment)
u_hydro_curt_opt = control_block_vector(xc_opt, :hydrokinetic_curtailment)
u_batt_opt = control_block_vector(xc_opt, :battery_power_kw)
u_diesel_opt = control_block_vector(xc_opt, :diesel_power_kw)
u_h2_opt = control_block_vector(xc_opt, :h2_power_kw)
u_desal_opt = control_block_vector(xc_opt, :desal_power_kw)

function initial_system_state(design::SystemDesign, op::SystemOperation, dt_hours)
    Tstate = SIRENOpt._state_real_type(design, op, dt_hours)
    return SystemState{Tstate}(
        zero(Tstate),
        convert(Tstate, design.bus.voltage_nominal),
        convert(Tstate, op.battery.soc_init),
        convert(Tstate, op.diesel.fuel_level),
        convert(Tstate, op.h2.tank_level_kg),
        convert(Tstate, op.desal.tank_level_m3),
        ControllerState{Tstate}(zero(Tstate)),
        PlatformState{Tstate}(zero(Tstate), zero(Tstate), zero(Tstate)),
    )
end

function replay_block_controls(design::SystemDesign, op::SystemOperation, xc)
    state = initial_system_state(design, op, dt_hours)
    states = Vector{typeof(state)}(undef, nb)
    outputs = Vector{SystemOutputs{typeof(state.time)}}(undef, nb)
    for b in 1:nb
        states[b] = state
        setpoints = control_setpoints_from_values(active_control_values(control_parameters, xc, b))
        state, outputs[b] = plant_step(design, op, state, setpoints, b, dt_block_hours[b])
    end
    return states, outputs, state
end

function group_extrema(g)
    return (
        init = extrema(abs.(g[1:n_init])),
        soc = extrema(abs.(g[(n_init + 1):(n_init + n_dyn_soc)])),
        h2 = extrema(abs.(g[(n_init + n_dyn_soc + 1):(n_init + n_dyn_soc + n_dyn_h2)])),
        desal = extrema(abs.(g[(n_init + n_dyn_soc + n_dyn_h2 + 1):(n_init + n_dyn_soc + n_dyn_h2 + n_dyn_desal)])),
        power = extrema(abs.(g[(n_init + n_dyn_soc + n_dyn_h2 + n_dyn_desal + 1):(n_init + n_dyn_soc + n_dyn_h2 + n_dyn_desal + n_power)])),
    )
end

equality_count = n_init + n_dyn_soc + n_dyn_h2 + n_dyn_desal + n_power

function equality_residual(g)
    return maximum(abs.(g[1:equality_count]))
end

function inequality_violation(g)
    equality_count < ng || return zero(eltype(g))
    inequality_rows = (equality_count + 1):ng
    lower_violation = maximum(max.(lg[inequality_rows] .- g[inequality_rows], zero(eltype(g))))
    upper_violation = maximum(max.(g[inequality_rows] .- ug[inequality_rows], zero(eltype(g))))
    return max(lower_violation, upper_violation)
end

g_hard = zeros(T, ng)
f_hard_check = obj!(g_hard, x_opt)
x_smooth = _smooth_replay_vector(x_opt)
Tsm = eltype(x_smooth)
g_smooth_dual = zeros(Tsm, ng)
f_smooth_dual = obj!(g_smooth_dual, x_smooth)
g_smooth = _real_value.(g_smooth_dual)
f_smooth_check = _real_value(f_smooth_dual)
opt_design_blocks = prepare_design(design_from_scaled_x(base_design, varspec, design_parameters, xd_opt), op_blocks)
opt_design_blocks = SIRENOpt.with(opt_design_blocks; platform = platform_from_supported_mass(opt_design_blocks))
block_states, block_outputs, block_terminal = replay_block_controls(opt_design_blocks, op_blocks, xc_opt)
block_net = [o.net_bus_power_kw for o in block_outputs]
block_soc_replay = vcat([s.battery_soc for s in block_states], block_terminal.battery_soc)
block_h2_replay = vcat([s.h2_level_kg for s in block_states], block_terminal.h2_level_kg)
block_desal_replay = vcat([s.desal_level_m3 for s in block_states], block_terminal.desal_level_m3)

println("  smooth NLP objective check f(x_opt): ", f_smooth_check)
println("  hard replay objective check f(x_opt): ", f_hard_check)
println("  max |smooth NLP equality residual|: ", equality_residual(g_smooth))
println("  max smooth NLP inequality violation: ", inequality_violation(g_smooth))
println("  smooth NLP residual groups: ", group_extrema(g_smooth))
println("  max |hard replay equality residual|: ", equality_residual(g_hard))
println("  max hard replay inequality violation: ", inequality_violation(g_hard))
println("  hard replay residual groups: ", group_extrema(g_hard))
println("  max |hard block replay net bus power| (kW): ", maximum(abs.(block_net)))
println("  max |hard soc replay - opt state|: ", maximum(abs.(block_soc_replay .- collect(soc_opt))))
println("  max |hard h2 replay - opt state| (kg): ", maximum(abs.(block_h2_replay .- collect(h2_opt))))
println("  max |hard water replay - opt state| (m^3): ", maximum(abs.(block_desal_replay .- collect(desal_opt))))

println("\nOptimized design:")
println("  solar area (m^2): ", opt_design.solar.area)
println("  wind rotor diameter (m): ", opt_design.wind.rotor_diameter)
println("  wind rated power (kW): ", opt_design.wind.rated_power)
println("  wave capture width (m): ", opt_design.wave.capture_width)
println("  wave rated power (kW): ", opt_design.wave.rated_power)
println("  hydrokinetic rotor diameter (m): ", opt_design.hydrokinetic.rotor_diameter)
println("  hydrokinetic rated power (kW): ", opt_design.hydrokinetic.rated_power)
println("  diesel rated power (kW): ", opt_design.diesel.rated_power)
println("  battery capacity (kWh): ", opt_design.battery.capacity_kwh)
println("  h2 electrolyzer power (kW): ", opt_design.h2.electrolyzer_power_kw)
println("  h2 tank capacity (kg): ", opt_design.h2.tank_capacity_kg)
println("  desal plant power (kW): ", opt_design.desal.plant_power_kw)
println("  desal tank capacity (m^3): ", opt_design.desal.tank_capacity_m3)
println("  control blocks: ", nb, " (", block_s, " s)")
println("  peak load (kW): ", maximum(load_ts.values))

# -------------------------
# Plot controls
# -------------------------

control_opt = block_controller(xc_opt, block)
states, outputs = simulate(opt_design, op, dt_hours; control = control_opt)

function expand_blocks(block_values)
    expanded = similar(profiles.t_hours)
    for k in 1:N
        b = Int(cld(k, block))
        expanded[k] = block_values[b]
    end
    return expanded
end

u_batt_ts = expand_blocks(u_batt_opt)
u_diesel_ts = expand_blocks(u_diesel_opt)
u_h2_ts = expand_blocks(u_h2_opt)
u_desal_ts = expand_blocks(u_desal_opt)
u_solar_curt_ts = expand_blocks(u_solar_curt_opt)
u_wind_curt_ts = expand_blocks(u_wind_curt_opt)
u_wave_curt_ts = expand_blocks(u_wave_curt_opt)
u_hydro_curt_ts = expand_blocks(u_hydro_curt_opt)

time_s = (profiles.t_hours .- profiles.t_hours[1]) .* 3600.0
block_time_s = vcat(zero(T), cumsum(dt_block_hours) .* 3600.0)
batt_soc = [s.battery_soc for s in states]
h2_level = [s.h2_level_kg for s in states]
desal_level = [s.desal_level_m3 for s in states]
bus_v = [o.bus_voltage for o in outputs]
p_solar = [o.solar_power_kw for o in outputs]
p_wind = [o.wind_power_kw for o in outputs]
p_wave = [o.wave_power_kw for o in outputs]
p_hydro = [o.hydrokinetic_power_kw for o in outputs]
p_diesel = [o.diesel_power_kw for o in outputs]
p_batt = [o.battery_power_kw for o in outputs]
p_load = [o.load_power_kw for o in outputs]
p_h2 = [o.h2_power_kw for o in outputs]
p_desal = [o.desal_power_kw for o in outputs]
p_net = [o.net_bus_power_kw for o in outputs]
generation_kw = p_solar .+ p_wind .+ p_wave .+ p_hydro .+ p_diesel .+ max.(p_batt, zero(T))
consumption_kw = .-p_load .- p_h2 .- p_desal .+ max.(-p_batt, zero(T))
h2_prod_rate = u_h2_ts ./ opt_design.h2.specific_energy_kwh_per_kg
desal_prod_rate = u_desal_ts ./ opt_design.desal.specific_energy_kwh_per_m3
h2_demand_rate_gph = profiles.h2_ts.values .* 1000.0
h2_prod_rate_gph = h2_prod_rate .* 1000.0
desal_demand_rate_lph = profiles.desal_ts.values .* 1000.0
desal_prod_rate_lph = desal_prod_rate .* 1000.0
battery_fill = batt_soc
h2_fill = h2_level ./ max(opt_design.h2.tank_capacity_kg, eps(T))
desal_fill = desal_level ./ max(opt_design.desal.tank_capacity_m3, eps(T))
h2_fill_opt = collect(h2_opt) ./ max(opt_design.h2.tank_capacity_kg, eps(T))
desal_fill_opt = collect(desal_opt) ./ max(opt_design.desal.tank_capacity_m3, eps(T))
battery_fill_opt = collect(soc_opt)
battery_fill_delta = battery_fill .- first(battery_fill)
h2_fill_delta = h2_fill .- first(h2_fill)
desal_fill_delta = desal_fill .- first(desal_fill)
battery_fill_opt_delta = battery_fill_opt .- first(battery_fill_opt)
h2_fill_opt_delta = h2_fill_opt .- first(h2_fill_opt)
desal_fill_opt_delta = desal_fill_opt .- first(desal_fill_opt)

println("  peak H2 demand rate (g/h): ", maximum(h2_demand_rate_gph))
println("  peak water demand rate (L/h): ", maximum(desal_demand_rate_lph))
if maximum(h2_demand_rate_gph) == 0.0 && maximum(desal_demand_rate_lph) == 0.0
    println("  note: selected window has zero optional-load demand; H2 and water storage states will remain flat unless SIRENO_SHORT_START_HOUR is changed.")
end
net_block_sim, _ = block_average(p_net)
println("  max |net bus power| in simulation (kW): ", maximum(abs.(p_net)))
println("  max |net bus power| block-average in simulation (kW): ", maximum(abs.(net_block_sim)))
println("  battery fill delta (sim): ", extrema(battery_fill_delta))
println("  h2 level range (g): ", extrema(h2_level .* 1000.0))
println("  water level range (L): ", extrema(desal_level .* 1000.0))
println("  bus voltage range (p.u.): ", extrema(bus_v))

p0 = Plots.plot(time_s, [profiles.solar_ts.values profiles.wind_ts.values profiles.wave_ts.values hydro_ts.values load_ts.values],
    label = ["Solar resource" "Wind speed" "Wave resource" "Hydro current" "Load"],
    xlabel = "Time (s)",
    ylabel = "Resource / Load",
    title = "Input Profiles",
)

p1 = Plots.plot(time_s, [generation_kw consumption_kw p_net],
    label = ["Generation" "Consumption" "Net Bus Power"],
    xlabel = "Time (s)",
    ylabel = "Power (kW)",
    title = "Realized Supply and Demand",
)

p2 = Plots.plot(time_s, [u_batt_ts u_diesel_ts u_h2_ts u_desal_ts],
    label = ["Battery Cmd" "Diesel Cmd" "H2 Cmd" "Desal Cmd"],
    xlabel = "Time (s)",
    ylabel = "Power (kW)",
    title = "Block Controls",
)

p3 = Plots.plot(time_s, [u_solar_curt_ts u_wind_curt_ts u_wave_curt_ts u_hydro_curt_ts],
    label = ["Solar Curt" "Wind Curt" "Wave Curt" "Hydro Curt"],
    xlabel = "Time (s)",
    ylabel = "Fraction",
    title = "Curtailment",
    ylim = (0.0, 1.05),
)

p4 = Plots.plot(time_s, [battery_fill_delta h2_fill_delta desal_fill_delta],
    label = ["Battery Fill Delta (sim)" "H2 Fill Delta (sim)" "Water Fill Delta (sim)"],
    xlabel = "Time (s)",
    ylabel = "Delta Fill Fraction",
    title = "Storage Fill Fraction Changes",
)
Plots.plot!(p4, block_time_s, battery_fill_opt_delta, label = "Battery Fill Delta (opt)", lw = 1.5, ls = :dash)
Plots.plot!(p4, block_time_s, h2_fill_opt_delta, label = "H2 Fill Delta (opt)", lw = 1.5, ls = :dashdot)
Plots.plot!(p4, block_time_s, desal_fill_opt_delta, label = "Water Fill Delta (opt)", lw = 1.5, ls = :dot)

p5 = Plots.plot(time_s, [h2_demand_rate_gph h2_prod_rate_gph desal_demand_rate_lph desal_prod_rate_lph],
    label = ["H2 Demand (g/h)" "H2 Production (g/h)" "Water Demand (L/h)" "Water Production (L/h)"],
    xlabel = "Time (s)",
    ylabel = "Rate",
    title = "Optional-Load Demand and Production Rates",
)

p6 = Plots.plot(time_s, bus_v,
    label = "Bus Voltage",
    xlabel = "Time (s)",
    ylabel = "Voltage (p.u.)",
    title = "Bus Voltage",
)

plt = Plots.plot(
    p1, p2, p3, p4, p5, p6;
    layout = (6, 1),
    size = (700, 1900),
    left_margin = 18Plots.mm,
    bottom_margin = 10Plots.mm,
    top_margin = 5Plots.mm,
    right_margin = 6Plots.mm,
)
output_path = joinpath(@__DIR__, "short_horizon_snow_controls.png")
Plots.savefig(plt, output_path)

println("\nSaved plot to: ", output_path)
