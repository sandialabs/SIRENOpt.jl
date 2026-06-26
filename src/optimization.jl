"""Single-point objective: cost per kW or diesel fuel cost at index k."""
function objective_single_point(design::SystemDesign, op::SystemOperation;
    k::Int = 1, mode::Symbol = :cost_per_kw)

    p_load = load_demand(design.load, op.load, k)
    p_h2 = design.h2.electrolyzer_power_kw
    p_desal = design.desal.plant_power_kw
    p_demand = p_load + p_h2 + p_desal

    p_solar = solar_power(design.solar, op.solar, design.solar_gen, op.solar_gen,
        design.solar_conv, op.solar_conv, k)
    p_wind = wind_power(design.wind, op.wind, design.wind_gen, op.wind_gen,
        design.wind_conv, op.wind_conv, k)
    p_wave = wave_power(design.wave, op.wave, design.wave_gen, op.wave_gen,
        design.wave_conv, op.wave_conv, k)
    p_hydro = hydrokinetic_power(design.hydrokinetic, op.hydrokinetic,
        design.hydrokinetic_gen, op.hydrokinetic_gen,
        design.hydrokinetic_conv, op.hydrokinetic_conv, k)

    p_non_diesel = p_solar + p_wind + p_wave + p_hydro

    if mode == :diesel_fuel
        deficit = smooth_max(p_demand - p_non_diesel, zero(p_demand))
        return deficit * design.diesel.fuel_per_kwh
    else
        agg = aggregate_mass_cost_volume(design)
        return agg.cost / smooth_max(p_demand, oftype(p_demand, 1.0e-9))
    end
end

"""Dynamic objective using simulation over the profile."""
function objective_dynamic(design::SystemDesign, op::SystemOperation, dt_hours;
    mode::Symbol = :total_cost, control = controller_step,
    dynamics_method::Symbol = :explicit, dynamics_solver = nothing)

    states, outputs = simulate(design, op, dt_hours;
        control = control, dynamics_method = dynamics_method, dynamics_solver = dynamics_solver)
    total_energy = zero(dt_hours)
    total_fuel = zero(dt_hours)

    for k in eachindex(outputs)
        out = outputs[k]
        total_energy += smooth_max(-out.load_power_kw, zero(out.load_power_kw)) * dt_hours
        total_fuel += out.diesel_fuel_used
    end

    if mode == :diesel_fuel
        return total_fuel
    else
        agg = aggregate_mass_cost_volume(design)
        return agg.cost + total_fuel
    end
end

"""Check battery-only, battery+renewables, and full-system constraints."""
function check_constraints(design::SystemDesign, op::SystemOperation,
    spec::ConstraintSpec, dt_hours)

    load_profile = op.load.demand.values
    load_peak = smooth_max(load_profile)
    critical_load_peak = load_peak * design.load.critical_fraction

    battery_only_energy = critical_load_peak * spec.battery_only_hours
    battery_only_ok = design.battery.capacity_kwh >= battery_only_energy

    n = length(op.load.demand)
    p_non_diesel_avg = zero(load_peak)
    for k in 1:n
        p_non_diesel_avg += power_available_solar(design.solar, op.solar, k)
        p_non_diesel_avg += power_available_wind(design.wind, op.wind, k)
        p_non_diesel_avg += power_available_wave(design.wave, op.wave, k)
        p_non_diesel_avg += power_available_hydrokinetic(design.hydrokinetic, op.hydrokinetic, k)
    end
    p_non_diesel_avg /= n

    battery_plus_energy = design.battery.capacity_kwh + p_non_diesel_avg * spec.battery_plus_renewables_hours
    battery_plus_ok = battery_plus_energy >= critical_load_peak * spec.battery_plus_renewables_hours

    p_solar_full = converter_output(design.solar_conv, op.solar_conv,
        generator_output(design.solar_gen, op.solar_gen, design.solar_gen.rated_power))
    p_wind_full = converter_output(design.wind_conv, op.wind_conv,
        generator_output(design.wind_gen, op.wind_gen, design.wind_gen.rated_power))
    p_wave_full = converter_output(design.wave_conv, op.wave_conv,
        generator_output(design.wave_gen, op.wave_gen, design.wave_gen.rated_power))
    p_hydro_full = converter_output(design.hydrokinetic_conv, op.hydrokinetic_conv,
        generator_output(design.hydrokinetic_gen, op.hydrokinetic_gen,
            design.hydrokinetic_gen.rated_power))
    p_diesel_full, _ = diesel_power(design.diesel, op.diesel, design.diesel_gen, op.diesel_gen,
        design.diesel_conv, op.diesel_conv, design.diesel.rated_power, dt_hours)
    p_full_supply = p_diesel_full + p_solar_full + p_wind_full + p_wave_full + p_hydro_full

    p_load_full = -converter_output(design.load_conv, op.load_conv, -load_peak)
    p_h2_full = -converter_output(design.h2_conv, op.h2_conv, -design.h2.electrolyzer_power_kw)
    p_desal_full = -converter_output(design.desal_conv, op.desal_conv, -design.desal.plant_power_kw)
    p_full_demand = p_load_full + p_h2_full + p_desal_full
    full_system_ok = p_full_supply >= p_full_demand

    return (
        battery_only_ok = battery_only_ok,
        battery_plus_ok = battery_plus_ok,
        full_system_ok = full_system_ok,
        battery_only_margin = design.battery.capacity_kwh - battery_only_energy,
        battery_plus_margin = battery_plus_energy - critical_load_peak * spec.battery_plus_renewables_hours,
        full_system_margin = p_full_supply - p_full_demand,
    )
end
