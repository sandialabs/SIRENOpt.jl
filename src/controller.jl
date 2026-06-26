"""Predict whether the battery will be exhausted using conservative non-diesel history."""
function predict_battery_exhaustion(design::SystemDesign, op::SystemOperation,
    state::SystemState, k::Int, dt_hours)

    window_hours = design.controller.prediction_window_hours
    n = smooth_clamp_index(round(window_hours / dt_hours), 1, k)
    if n <= 1
        return false
    end
    k0 = smooth_clamp_index(k - n + 1, 1, k)
    p_non_diesel = zero(state.battery_soc)
    p_load = zero(state.battery_soc)
    for i in k0:k
        p_non_diesel += power_available_solar(design.solar, op.solar, i)
        p_non_diesel += power_available_wind(design.wind, op.wind, i)
        p_non_diesel += power_available_wave(design.wave, op.wave, i)
        p_non_diesel += power_available_hydrokinetic(design.hydrokinetic, op.hydrokinetic, i)
        p_load += load_demand(design.load, op.load, i)
    end
    p_non_diesel /= n
    p_load /= n
    p_non_diesel *= design.controller.conservative_fraction
    net = p_non_diesel - p_load
    if net >= 0
        return false
    end
    battery_energy = state.battery_soc * design.battery.capacity_kwh
    hours_to_empty = battery_energy / (-net)
    return hours_to_empty < window_hours
end

"""Compute smooth control setpoints for gradient-based co-design studies."""
function smooth_controller_step(design::SystemDesign, op::SystemOperation,
    state::SystemState, k::Int, dt_hours)

    p_load_critical = load_demand(design.load, op.load, k; critical_only = true)
    p_load_optional = load_demand(design.load, op.load, k; optional_only = true)
    p_load = p_load_critical + p_load_optional

    reserve_gate = smooth_step(state.battery_soc - design.controller.battery_reserve_soc)
    voltage_gate = smooth_step(state.bus_voltage - design.bus.voltage_min)
    optional_gate = reserve_gate * voltage_gate

    h2_gate = smooth_step(design.h2.tank_capacity_kg - state.h2_level_kg)
    desal_gate = smooth_step(design.desal.tank_capacity_m3 - state.desal_level_m3)

    p_load_served = p_load_critical + optional_gate * p_load_optional
    load_served_fraction = p_load_served / smooth_max(p_load, oftype(p_load, 1.0e-9))
    p_h2 = optional_gate * h2_gate * design.h2.electrolyzer_power_kw
    p_desal = optional_gate * desal_gate * design.desal.plant_power_kw

    over_voltage = smooth_max(state.bus_voltage - design.bus.voltage_nominal - design.controller.voltage_deadband,
        zero(state.bus_voltage))
    under_voltage = smooth_max(design.bus.voltage_nominal - design.controller.voltage_deadband - state.bus_voltage,
        zero(state.bus_voltage))

    solar_curt = smooth_clamp(op.solar.curtailment + over_voltage - under_voltage, zero(over_voltage), one(over_voltage))
    wind_curt = smooth_clamp(op.wind.curtailment + over_voltage - under_voltage, zero(over_voltage), one(over_voltage))
    wave_curt = smooth_clamp(op.wave.curtailment + over_voltage - under_voltage, zero(over_voltage), one(over_voltage))
    hydro_curt = smooth_clamp(op.hydrokinetic.curtailment + over_voltage - under_voltage,
        zero(over_voltage), one(over_voltage))

    solar_op = SolarOp{typeof(solar_curt)}(
        resource = op.solar.resource,
        curtailment = solar_curt,
        pv_weather = op.solar.pv_weather,
        pv_solar_position = op.solar.pv_solar_position,
    )
    wind_op = WindOp{typeof(wind_curt)}(op.wind.resource, op.wind.air_density + zero(wind_curt), wind_curt)
    wave_op = WaveOp{typeof(wave_curt)}(op.wave.resource, wave_curt)
    hydro_op = HydrokineticOp{typeof(hydro_curt)}(
        op.hydrokinetic.resource,
        op.hydrokinetic.fluid_density + zero(hydro_curt),
        hydro_curt,
    )

    p_solar = solar_power(design.solar, solar_op, design.solar_gen, op.solar_gen,
        design.solar_conv, op.solar_conv, k)
    p_wind = wind_power(design.wind, wind_op, design.wind_gen, op.wind_gen,
        design.wind_conv, op.wind_conv, k)
    p_wave = wave_power(design.wave, wave_op, design.wave_gen, op.wave_gen,
        design.wave_conv, op.wave_conv, k)
    p_hydro = hydrokinetic_power(design.hydrokinetic, hydro_op,
        design.hydrokinetic_gen, op.hydrokinetic_gen,
        design.hydrokinetic_conv, op.hydrokinetic_conv, k)

    demand_total = p_load_served + p_h2 + p_desal
    p_non_diesel = p_solar + p_wind + p_wave + p_hydro
    deficit = demand_total - p_non_diesel

    battery_power = smooth_clamp(deficit, -design.battery.max_charge_kw, design.battery.max_discharge_kw)
    diesel_needed = smooth_max(deficit - battery_power, zero(deficit))
    diesel_setpoint = smooth_clamp(diesel_needed, zero(deficit), design.diesel.rated_power)
    remainder = deficit - diesel_setpoint
    battery_power = smooth_clamp(remainder, -design.battery.max_charge_kw, design.battery.max_discharge_kw)

    return ControlSetpoints(
        solar_curtailment = solar_curt,
        wind_curtailment = wind_curt,
        wave_curtailment = wave_curt,
        hydrokinetic_curtailment = hydro_curt,
        load_served_fraction = load_served_fraction,
        diesel_power_kw = diesel_setpoint,
        battery_power_kw = battery_power,
        h2_power_kw = p_h2,
        desal_power_kw = p_desal,
    )
end

"""Compute control setpoints for sources, diesel, battery, and optional loads."""
function controller_step(design::SystemDesign, op::SystemOperation,
    state::SystemState, k::Int, dt_hours)

    # 1) Determine highest-priority electrical load.
    p_load_critical = load_demand(design.load, op.load, k; critical_only = true)
    p_load_optional = load_demand(design.load, op.load, k; optional_only = true)
    p_load = p_load_critical + p_load_optional

    h2_allowed = state.h2_level_kg < design.h2.tank_capacity_kg
    desal_allowed = state.desal_level_m3 < design.desal.tank_capacity_m3

    # 2) Shed optional loads if battery reserve or voltage is threatened, or forecast exhaustion.
    optional_allowed = true
    if state.battery_soc <= design.controller.battery_reserve_soc
        optional_allowed = false
    end
    if state.bus_voltage < design.bus.voltage_min
        optional_allowed = false
    end
    if predict_battery_exhaustion(design, op, state, k, dt_hours)
        optional_allowed = false
    end

    p_load_served = p_load_critical + (optional_allowed ? p_load_optional : zero(p_load_optional))
    load_served_fraction = p_load_served / smooth_max(p_load, oftype(p_load, 1.0e-9))

    p_h2 = optional_allowed && h2_allowed ? design.h2.electrolyzer_power_kw : zero(p_load)
    p_desal = optional_allowed && desal_allowed ? design.desal.plant_power_kw : zero(p_load)

    # 3) Compute renewable curtailment based on bus voltage error.
    voltage_error = design.bus.voltage_nominal - state.bus_voltage
    if smooth_abs(voltage_error) <= design.controller.voltage_deadband
        solar_curt = op.solar.curtailment
        wind_curt = op.wind.curtailment
        wave_curt = op.wave.curtailment
        hydro_curt = op.hydrokinetic.curtailment
    elseif voltage_error > 0
        solar_curt = zero(p_load)
        wind_curt = zero(p_load)
        wave_curt = zero(p_load)
        hydro_curt = zero(p_load)
    else
        solar_curt = smooth_min(one(p_load), op.solar.curtailment + smooth_abs(voltage_error))
        wind_curt = smooth_min(one(p_load), op.wind.curtailment + smooth_abs(voltage_error))
        wave_curt = smooth_min(one(p_load), op.wave.curtailment + smooth_abs(voltage_error))
        hydro_curt = smooth_min(one(p_load), op.hydrokinetic.curtailment + smooth_abs(voltage_error))
    end

    solar_op = SolarOp{typeof(solar_curt)}(
        resource = op.solar.resource,
        curtailment = solar_curt,
        pv_weather = op.solar.pv_weather,
        pv_solar_position = op.solar.pv_solar_position,
    )
    wind_op = WindOp{typeof(wind_curt)}(op.wind.resource, op.wind.air_density + zero(wind_curt), wind_curt)
    wave_op = WaveOp{typeof(wave_curt)}(op.wave.resource, wave_curt)
    hydro_op = HydrokineticOp{typeof(hydro_curt)}(
        op.hydrokinetic.resource,
        op.hydrokinetic.fluid_density + zero(hydro_curt),
        hydro_curt,
    )

    p_solar = solar_power(design.solar, solar_op, design.solar_gen, op.solar_gen,
        design.solar_conv, op.solar_conv, k)
    p_wind = wind_power(design.wind, wind_op, design.wind_gen, op.wind_gen,
        design.wind_conv, op.wind_conv, k)
    p_wave = wave_power(design.wave, wave_op, design.wave_gen, op.wave_gen,
        design.wave_conv, op.wave_conv, k)
    p_hydro = hydrokinetic_power(design.hydrokinetic, hydro_op,
        design.hydrokinetic_gen, op.hydrokinetic_gen,
        design.hydrokinetic_conv, op.hydrokinetic_conv, k)

    demand_total = p_load_served + p_h2 + p_desal
    p_non_diesel = p_solar + p_wind + p_wave + p_hydro
    deficit = demand_total - p_non_diesel

    # 4) Use battery to buffer deficit, then diesel within fuel rationing.
    battery_power = smooth_clamp(deficit, -design.battery.max_charge_kw, design.battery.max_discharge_kw)

    fuel_rate_limit = design.diesel.fuel_tank_capacity / design.diesel.fill_period_hours
    max_diesel_power = fuel_rate_limit / design.diesel.fuel_per_kwh
    diesel_needed = smooth_max(deficit - battery_power, zero(deficit))
    diesel_setpoint = smooth_clamp(diesel_needed, zero(deficit), max_diesel_power)

    remainder = deficit - diesel_setpoint
    battery_power = smooth_clamp(remainder, -design.battery.max_charge_kw, design.battery.max_discharge_kw)

    return ControlSetpoints(
        solar_curtailment = solar_curt,
        wind_curtailment = wind_curt,
        wave_curtailment = wave_curt,
        hydrokinetic_curtailment = hydro_curt,
        load_served_fraction = load_served_fraction,
        diesel_power_kw = diesel_setpoint,
        battery_power_kw = battery_power,
        h2_power_kw = p_h2,
        desal_power_kw = p_desal,
    )
end
