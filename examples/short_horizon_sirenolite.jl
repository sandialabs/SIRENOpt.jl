"""
Short-horizon (1 minute) simulation at 0.01 s timestep using SIRENO-Lite inputs.

This example builds high-resolution wind/solar/wave profiles by interpolating the
SIRENO-Lite CSV data and injecting band-limited noise, then runs a closed-loop
simulation with the default SIRENOpt design.
"""

using SIRENOpt
using Statistics

const T = Float64

data_path = joinpath(@__DIR__, "..", "data", "sirenolite_load_resource_data.csv")
if !isfile(data_path)
    error("SIRENO-Lite data file not found at $(data_path).")
end

profiles = short_horizon_profiles(
    data_path;
    start_hour = 12.0,
    horizon_s = 60.0,
    dt_s = 0.01,
    seed = 4,
)

platform_force = TimeSeries(profiles.t_hours, 500.0 .* profiles.wave_ts.values)

op = SystemOperation{T}(
    solar = SolarOp{T}(resource = profiles.solar_ts),
    wind = WindOp{T}(resource = profiles.wind_ts, air_density = 1.225),
    wave = WaveOp{T}(resource = profiles.wave_ts),
    load = LoadOp{T}(demand = profiles.load_ts),
    h2 = H2Op{T}(demand = profiles.h2_ts),
    desal = DesalOp{T}(demand = profiles.desal_ts),
    battery = BatteryOp{T}(soc_init = 0.7),
    platform = PlatformOp{T}(external_force = platform_force),
)

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
        controller = SIRENOpt.with(design.controller; prediction_window_hours = profiles.dt_hours * 200),
    )
end

design = prepare_design(SystemDesign{T}(), op)
design = SIRENOpt.with(design; platform = platform_from_supported_mass(design))

states, outputs = simulate(design, op, profiles.dt_hours)

function summary(values)
    return (min = minimum(values), mean = mean(values), max = maximum(values))
end

solar_p = [o.solar_power_kw for o in outputs]
wind_p = [o.wind_power_kw for o in outputs]
wave_p = [o.wave_power_kw for o in outputs]
diesel_p = [o.diesel_power_kw for o in outputs]
load_p = [o.load_power_kw for o in outputs]
bus_v = [o.bus_voltage for o in outputs]
batt_soc = [s.battery_soc for s in states]
platform_pos = [s.platform.position for s in states]
platform_vel = [s.platform.velocity for s in states]

println("Short-horizon run")
println("  steps: ", length(outputs), " dt_s: ", profiles.dt_hours * 3600)
println("  solar resource (kW/m^2): ", summary(profiles.solar_ts.values))
println("  wind speed (m/s): ", summary(profiles.wind_ts.values))
println("  wave resource (kW/m): ", summary(profiles.wave_ts.values))
println("  load (kW): ", summary(profiles.load_ts.values))
println("  solar power (kW): ", summary(solar_p))
println("  wind power (kW): ", summary(wind_p))
println("  wave power (kW): ", summary(wave_p))
println("  diesel power (kW): ", summary(diesel_p))
println("  load power (kW): ", summary(load_p))
println("  bus voltage: ", summary(bus_v))
println("  battery soc: ", summary(batt_soc))
println("  platform position: ", summary(platform_pos))
println("  platform velocity: ", summary(platform_vel))
