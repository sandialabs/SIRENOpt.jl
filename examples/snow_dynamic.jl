"""
Dynamic optimization example using SNOW.

This script solves a simultaneous design + control + state optimization
problem and produces a control plot and design summary.

Requires:
  - SNOW.jl
  - Ipopt.jl
  - Plots.jl
"""

using SIRENOpt
using SNOW
using Ipopt
import Plots

const T = Float64

# -------------------------
# Profiles (24 hours)
# -------------------------

hours = collect(0.0:1.0:24.0)
N = length(hours)

solar_profile = [max(0.0, sin((h - 6.0) * pi / 12.0)) for h in hours]
wind_profile = [4.5 + 1.0 * sin((h + 3.0) * pi / 12.0) for h in hours]
wave_profile = fill(2.0, N)
load_profile = [7.0 + 1.5 * sin((h + 1.0) * pi / 12.0) for h in hours]

solar_ts = TimeSeries(hours, solar_profile)
wind_ts = TimeSeries(hours, wind_profile)
wave_ts = TimeSeries(hours, wave_profile)
load_ts = TimeSeries(hours, load_profile)

op = SystemOperation{T}(
    solar = SolarOp{T}(resource = solar_ts),
    wind = WindOp{T}(resource = wind_ts),
    wave = WaveOp{T}(resource = wave_ts),
    load = LoadOp{T}(demand = load_ts),
    battery = BatteryOp{T}(soc_init = 0.6),
)

dt_hours = 1.0

# -------------------------
# Base design + cost model
# -------------------------

base_design = SystemDesign{T}()

base_design = SIRENOpt.with(base_design;
    solar = SIRENOpt.with(base_design.solar; efficiency = 0.2),
    wind = SIRENOpt.with(base_design.wind; rotor_diameter = 20.0, cp = 0.45),
    wave = SIRENOpt.with(base_design.wave; capture_width = 0.0, rated_power = 0.0),
    diesel = SIRENOpt.with(base_design.diesel; fuel_per_kwh = 4.0, fill_period_hours = 24.0),
    battery = SIRENOpt.with(base_design.battery; reserve_soc = 0.2),
    solar_gen = SIRENOpt.with(base_design.solar_gen; efficiency = 0.97),
    wind_gen = SIRENOpt.with(base_design.wind_gen; efficiency = 0.96),
    wave_gen = SIRENOpt.with(base_design.wave_gen; efficiency = 0.96),
    diesel_gen = SIRENOpt.with(base_design.diesel_gen; efficiency = 0.95),
    solar_conv = SIRENOpt.with(base_design.solar_conv; efficiency = 0.98),
    wind_conv = SIRENOpt.with(base_design.wind_conv; efficiency = 0.98),
    wave_conv = SIRENOpt.with(base_design.wave_conv; efficiency = 0.98),
    diesel_conv = SIRENOpt.with(base_design.diesel_conv; efficiency = 0.98),
    battery_conv = SIRENOpt.with(base_design.battery_conv; efficiency = 0.98),
    load_conv = SIRENOpt.with(base_design.load_conv; efficiency = 0.99),
)

const COST = (
    solar_per_m2 = 5.0,
    wind_per_kw = 200.0,
    diesel_per_kw = 200.0,
    battery_per_kwh = 80.0,
)

function capital_cost(design::SystemDesign{T}) where {T}
    return COST.solar_per_m2 * design.solar.area +
        COST.wind_per_kw * design.wind.rated_power +
        COST.diesel_per_kw * design.diesel.rated_power +
        COST.battery_per_kwh * design.battery.capacity_kwh
end

function prepare_design(design::SystemDesign{T}, op::SystemOperation{T}) where {T}
    max_solar = maximum(op.solar.resource.values)
    max_load = maximum(op.load.demand.values)
    solar_rating = max_solar * design.solar.area * design.solar.efficiency
    batt_rate = max(design.battery.capacity_kwh, T(1.0))

    return SIRENOpt.with(design;
        solar_gen = SIRENOpt.with(design.solar_gen; rated_power = solar_rating),
        solar_conv = SIRENOpt.with(design.solar_conv; rated_power = solar_rating),
        wind_gen = SIRENOpt.with(design.wind_gen; rated_power = design.wind.rated_power),
        wind_conv = SIRENOpt.with(design.wind_conv; rated_power = design.wind.rated_power),
        wave_gen = SIRENOpt.with(design.wave_gen; rated_power = design.wave.rated_power),
        wave_conv = SIRENOpt.with(design.wave_conv; rated_power = design.wave.rated_power),
        diesel_gen = SIRENOpt.with(design.diesel_gen; rated_power = design.diesel.rated_power),
        diesel_conv = SIRENOpt.with(design.diesel_conv; rated_power = design.diesel.rated_power),
        battery = SIRENOpt.with(design.battery; max_charge_kw = batt_rate, max_discharge_kw = batt_rate),
        battery_conv = SIRENOpt.with(design.battery_conv; rated_power = batt_rate),
        load_conv = SIRENOpt.with(design.load_conv; rated_power = max_load),
    )
end

function battery_soc_next(design::SystemDesign{T}, soc, power_kw, dt_hours) where {T}
    cap = design.battery.capacity_kwh
    p_dis = smooth_max(power_kw, zero(power_kw))
    p_chg = smooth_max(-power_kw, zero(power_kw))
    soc_next = soc -
        (p_dis * dt_hours) / (cap * design.battery.discharge_efficiency) +
        (p_chg * dt_hours) * design.battery.charge_efficiency / cap
    return soc_next
end

# -------------------------
# Design variables + bounds
# -------------------------

varspec = DesignVarSpec{T}(vars = DesignVar{T}[
    DesignVar{T}(name = :solar_area, initial = 60.0, lower = 0.0, upper = 400.0),
    DesignVar{T}(name = :wind_rated_power, initial = 40.0, lower = 0.0, upper = 200.0),
    DesignVar{T}(name = :diesel_rated_power, initial = 60.0, lower = 0.0, upper = 200.0),
    DesignVar{T}(name = :battery_capacity_kwh, initial = 120.0, lower = 20.0, upper = 400.0),
])

n_design = length(varspec.vars)

# Control + state variables (multiple shooting)
idx_design = 1:n_design
idx_batt = (last(idx_design) + 1):(last(idx_design) + N)
idx_diesel = (last(idx_batt) + 1):(last(idx_batt) + N)
idx_soc = (last(idx_diesel) + 1):(last(idx_diesel) + N)

function unpack(x)
    xd = view(x, idx_design)
    u_batt = view(x, idx_batt)
    u_diesel = view(x, idx_diesel)
    soc = view(x, idx_soc)
    return xd, u_batt, u_diesel, soc
end

# -------------------------
# Constraints
# -------------------------

n_init = 1
n_dyn = N - 1
n_power = N
n_diesel = N
n_batt = 2N
ng = n_init + n_dyn + n_power + n_diesel + n_batt

function obj!(g, x)
    xd, u_batt, u_diesel, soc = unpack(x)
    design = design_from_x(base_design, varspec, xd)
    design = prepare_design(design, op)

    # Initial SOC equality
    g[1] = soc[1] - op.battery.soc_init

    g_dyn_start = 2
    g_power_start = 1 + n_init + n_dyn
    g_diesel_start = g_power_start + n_power
    g_batt_start = g_diesel_start + n_diesel

    batt_rate = design.battery.capacity_kwh

    total_fuel = zero(T)

    for k in 1:N
        p_solar = solar_power(design.solar, op.solar, design.solar_gen, op.solar_gen,
            design.solar_conv, op.solar_conv, k)
        p_wind = wind_power(design.wind, op.wind, design.wind_gen, op.wind_gen,
            design.wind_conv, op.wind_conv, k)
        p_wave = wave_power(design.wave, op.wave, design.wave_gen, op.wave_gen,
            design.wave_conv, op.wave_conv, k)

        soc_next = battery_soc_next(design, soc[k], u_batt[k], dt_hours)
        p_batt_bus = converter_output(design.battery_conv, op.battery_conv, u_batt[k])

        p_load_bus = converter_output(design.load_conv, op.load_conv,
            -load_demand(design.load, op.load, k))

        g[g_power_start + k - 1] = p_solar + p_wind + p_wave + u_diesel[k] + p_batt_bus + p_load_bus

        if k < N
            g[g_dyn_start + k - 1] = soc[k + 1] - soc_next
        end

        g[g_diesel_start + k - 1] = design.diesel.rated_power - u_diesel[k]
        g[g_batt_start + (2k - 2)] = batt_rate - u_batt[k]
        g[g_batt_start + (2k - 1)] = batt_rate + u_batt[k]

        total_fuel += u_diesel[k] * design.diesel.fuel_per_kwh * dt_hours
    end

    return capital_cost(design) + total_fuel
end

# -------------------------
# Initial guess + bounds
# -------------------------

xd0 = varspec_x0(varspec)

u_batt0 = fill(0.0, N)
u_diesel0 = fill(0.0, N)

soc0 = fill(op.battery.soc_init, N)

design0 = prepare_design(design_from_x(base_design, varspec, xd0), op)
for k in 1:N
    p_solar = solar_power(design0.solar, op.solar, design0.solar_gen, op.solar_gen,
        design0.solar_conv, op.solar_conv, k)
    p_wind = wind_power(design0.wind, op.wind, design0.wind_gen, op.wind_gen,
        design0.wind_conv, op.wind_conv, k)
    p_wave = wave_power(design0.wave, op.wave, design0.wave_gen, op.wave_gen,
        design0.wave_conv, op.wave_conv, k)
    p_load_bus = converter_output(design0.load_conv, op.load_conv,
        -load_demand(design0.load, op.load, k))
    demand = -p_load_bus
    deficit = max(0.0, demand - (p_solar + p_wind + p_wave))
    u_diesel0[k] = min(deficit, varspec.vars[3].upper)
end

x0 = vcat(xd0, u_batt0, u_diesel0, soc0)

(lx_design, ux_design) = varspec_bounds(varspec)

batt_upper = varspec.vars[4].upper  # battery capacity upper bound (1C)
diesel_upper = varspec.vars[3].upper

lx = vcat(
    lx_design,
    fill(-batt_upper, N),
    fill(0.0, N),
    fill(0.0, N),
)
ux = vcat(
    ux_design,
    fill(batt_upper, N),
    fill(diesel_upper, N),
    fill(1.0, N),
)

lg = vcat(zeros(n_init + n_dyn), zeros(n_power + n_diesel + n_batt))
ug = vcat(zeros(n_init + n_dyn), fill(Inf, n_power + n_diesel + n_batt))

# -------------------------
# Solve
# -------------------------

options = Options(derivatives = ForwardFD(), solver = IPOPT(Dict("print_level" => 0)))
x_opt, f_opt, status, _ = minimize(obj!, x0, ng, lx, ux, lg, ug, options)

println("status: ", status)
println("f*: ", f_opt)

xd_opt, u_batt_opt, u_diesel_opt, soc_opt = unpack(x_opt)
opt_design = prepare_design(design_from_x(base_design, varspec, xd_opt), op)

println("\nOptimized design:")
println("  solar area (m^2): ", opt_design.solar.area)
println("  wind rated power (kW): ", opt_design.wind.rated_power)
println("  diesel rated power (kW): ", opt_design.diesel.rated_power)
println("  battery capacity (kWh): ", opt_design.battery.capacity_kwh)

# -------------------------
# Recompute signals for plotting
# -------------------------

p_solar = similar(u_batt_opt)
p_wind = similar(u_batt_opt)
p_wave = similar(u_batt_opt)
p_batt = similar(u_batt_opt)
p_load = similar(u_batt_opt)

for k in 1:N
    p_solar[k] = solar_power(opt_design.solar, op.solar, opt_design.solar_gen, op.solar_gen,
        opt_design.solar_conv, op.solar_conv, k)
    p_wind[k] = wind_power(opt_design.wind, op.wind, opt_design.wind_gen, op.wind_gen,
        opt_design.wind_conv, op.wind_conv, k)
    p_wave[k] = wave_power(opt_design.wave, op.wave, opt_design.wave_gen, op.wave_gen,
        opt_design.wave_conv, op.wave_conv, k)

    _, p_batt_device = battery_step(opt_design.battery, op.battery, soc_opt[k], u_batt_opt[k], dt_hours)
    p_batt[k] = converter_output(opt_design.battery_conv, op.battery_conv, p_batt_device)

    p_load[k] = -converter_output(opt_design.load_conv, op.load_conv,
        -load_demand(opt_design.load, op.load, k))
end

# -------------------------
# Plot controls + state
# -------------------------

ENV["GKSwstype"] = "100"

p1 = Plots.plot(hours, [p_solar p_wind u_diesel_opt p_batt p_load],
    label = ["Solar" "Wind" "Diesel" "Battery" "Load"],
    xlabel = "Hour",
    ylabel = "Power (kW)",
    title = "Optimized Power Flows",
    lw = 2,
)

p2 = Plots.plot(hours, soc_opt,
    label = "SOC",
    xlabel = "Hour",
    ylabel = "State of Charge",
    title = "Battery SOC",
    lw = 2,
    ylim = (0.0, 1.0),
)

plt = Plots.plot(p1, p2, layout = (2, 1), size = (900, 700))
output_path = joinpath(@__DIR__, "snow_dynamic_controls.png")
Plots.savefig(plt, output_path)

println("\nSaved plot to: ", output_path)
