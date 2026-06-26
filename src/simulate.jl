"""Advance system by one time step and return new state and outputs."""
function _platform_state_as(::Type{T}, state::PlatformState) where {T<:Real}
    return PlatformState{T}(
        convert(T, state.position),
        convert(T, state.velocity),
        convert(T, state.acceleration),
    )
end

function _state_real_type(design::SystemDesign, op::SystemOperation, dt_hours)
    return promote_type(
        typeof(dt_hours),
        typeof(design.bus.voltage_nominal),
        typeof(op.battery.soc_init),
        typeof(op.diesel.fuel_level),
        typeof(op.h2.tank_level_kg),
        typeof(op.desal.tank_level_m3),
        typeof(design.solar.area),
        typeof(design.wind.rotor_diameter),
        typeof(design.wave.capture_width),
        typeof(design.hydrokinetic.rotor_diameter),
        typeof(design.diesel.rated_power),
        typeof(design.solar_gen.rated_power),
        typeof(design.wind_gen.rated_power),
        typeof(design.wave_gen.rated_power),
        typeof(design.hydrokinetic_gen.rated_power),
        typeof(design.diesel_gen.rated_power),
        typeof(design.solar_conv.rated_power),
        typeof(design.wind_conv.rated_power),
        typeof(design.wave_conv.rated_power),
        typeof(design.hydrokinetic_conv.rated_power),
        typeof(design.diesel_conv.rated_power),
        typeof(design.battery.capacity_kwh),
        typeof(design.battery_conv.rated_power),
        typeof(design.h2.electrolyzer_power_kw),
        typeof(design.h2_conv.rated_power),
        typeof(design.desal.plant_power_kw),
        typeof(design.desal_conv.rated_power),
        typeof(design.load.critical_fraction),
        typeof(design.load_conv.rated_power),
        typeof(design.platform.base_mass),
    )
end

_positive_residual_part(x) = _plain_float(x) ? max(x, zero(x)) : smooth_max(x, zero(x))

function _battery_inventory_residual_kwh(design::BatteryDesign, soc_prev, soc_next,
        realized_power_kw, dt_hours)
    charge_kw = _positive_residual_part(-realized_power_kw)
    discharge_kw = _positive_residual_part(realized_power_kw)

    if design.storage_model !== nothing
        params = generic_storage_params(design)
        dt_s = dt_hours * _SECONDS_PER_HOUR_SIREN
        capacity_j = design.capacity_kwh * _J_PER_KWH
        e_prev = soc_prev * capacity_j
        e_post_charge = e_prev + charge_kw * _W_PER_KW * dt_s * params.charge_efficiency
        retention = exp(-params.standing_loss_rate * dt_s)
        e_after_standing = params.energy_min + (e_post_charge - params.energy_min) * retention
        e_expected = e_after_standing - discharge_kw * _W_PER_KW * dt_s / params.discharge_efficiency
        return soc_next * design.capacity_kwh - e_expected / _J_PER_KWH
    end

    expected_kwh = soc_prev * design.capacity_kwh +
        charge_kw * dt_hours * design.charge_efficiency -
        discharge_kw * dt_hours / design.discharge_efficiency
    return soc_next * design.capacity_kwh - expected_kwh
end

function _h2_inventory_residual_kg(design::H2Design, op::H2Op, level_prev, level_next,
        realized_power_kw, dt_hours, k::Int)
    production = realized_power_kw * dt_hours / design.specific_energy_kwh_per_kg
    demand = value_at(op.demand, k) * dt_hours
    return level_next - (level_prev + production - demand)
end

function _desal_inventory_residual_m3(design::DesalDesign, op::DesalOp, level_prev,
        level_next, realized_power_kw, dt_hours, k::Int)
    production = realized_power_kw * dt_hours / design.specific_energy_kwh_per_m3
    demand = value_at(op.demand, k) * dt_hours
    return level_next - (level_prev + production - demand)
end

_diesel_fuel_inventory_residual(fuel_prev, fuel_next, fuel_used) =
    fuel_next - fuel_prev + fuel_used

"""Advance the differentiable plant one time step from explicit control setpoints."""
function plant_step(design::SystemDesign, op::SystemOperation, state::SystemState,
    setpoints::ControlSetpoints, k::Int, dt_hours;
    dynamics_method::Symbol = :explicit, dynamics_solver = nothing)

    solar_op = SolarOp{typeof(setpoints.solar_curtailment)}(
        resource = op.solar.resource,
        curtailment = setpoints.solar_curtailment,
        pv_weather = op.solar.pv_weather,
        pv_solar_position = op.solar.pv_solar_position,
    )
    wind_op = WindOp{typeof(setpoints.wind_curtailment)}(
        op.wind.resource,
        op.wind.air_density + zero(setpoints.wind_curtailment),
        setpoints.wind_curtailment)
    wave_op = WaveOp{typeof(setpoints.wave_curtailment)}(
        op.wave.resource, setpoints.wave_curtailment)
    hydro_op = HydrokineticOp{typeof(setpoints.hydrokinetic_curtailment)}(
        op.hydrokinetic.resource,
        op.hydrokinetic.fluid_density + zero(setpoints.hydrokinetic_curtailment),
        setpoints.hydrokinetic_curtailment)

    p_solar = solar_power(design.solar, solar_op, design.solar_gen, op.solar_gen,
        design.solar_conv, op.solar_conv, k)
    p_wind = wind_power(design.wind, wind_op, design.wind_gen, op.wind_gen,
        design.wind_conv, op.wind_conv, k)
    p_wave = wave_power(design.wave, wave_op, design.wave_gen, op.wave_gen,
        design.wave_conv, op.wave_conv, k)
    p_hydro = hydrokinetic_power(design.hydrokinetic, hydro_op,
        design.hydrokinetic_gen, op.hydrokinetic_gen,
        design.hydrokinetic_conv, op.hydrokinetic_conv, k)

    p_diesel, fuel_used = diesel_power(design.diesel, op.diesel, design.diesel_gen, op.diesel_gen,
        design.diesel_conv, op.diesel_conv, setpoints.diesel_power_kw, dt_hours)

    battery_soc, battery_device_power = battery_step(design.battery, op.battery,
        state.battery_soc, setpoints.battery_power_kw, dt_hours)
    p_battery = converter_output(design.battery_conv, op.battery_conv, battery_device_power)

    p_load_device = load_demand(design.load, op.load, k) * setpoints.load_served_fraction
    p_load = converter_output(design.load_conv, op.load_conv, -p_load_device)

    h2_level, h2_power_device = h2_step(design.h2, op.h2, state.h2_level_kg,
        setpoints.h2_power_kw, dt_hours, k)
    p_h2 = converter_output(design.h2_conv, op.h2_conv, -h2_power_device)

    desal_level, desal_power_device = desal_step(design.desal, op.desal, state.desal_level_m3,
        setpoints.desal_power_kw, dt_hours, k)
    p_desal = converter_output(design.desal_conv, op.desal_conv, -desal_power_device)

    # Positive values supply the bus; negative values consume.
    net_bus_power = p_solar + p_wind + p_wave + p_hydro + p_diesel + p_battery + p_load + p_h2 + p_desal
    bus_balance_residual = net_bus_power
    bus_voltage = design.bus.voltage_nominal + design.bus.droop_gain * net_bus_power
    bus_voltage = smooth_clamp(bus_voltage, design.bus.voltage_min, design.bus.voltage_max)

    battery_inventory_residual = _battery_inventory_residual_kwh(
        design.battery, state.battery_soc, battery_soc, battery_device_power, dt_hours)
    h2_inventory_residual = _h2_inventory_residual_kg(
        design.h2, op.h2, state.h2_level_kg, h2_level, h2_power_device, dt_hours, k)
    desal_inventory_residual = _desal_inventory_residual_m3(
        design.desal, op.desal, state.desal_level_m3, desal_level, desal_power_device, dt_hours, k)

    fuel_level = smooth_max(state.diesel_fuel_level - fuel_used, zero(state.diesel_fuel_level))
    diesel_fuel_inventory_residual = _diesel_fuel_inventory_residual(
        state.diesel_fuel_level, fuel_level, fuel_used)
    controller_state = state.controller
    fuel_used_period = controller_state.diesel_fuel_used_in_period + fuel_used
    controller_state = ControllerState(fuel_used_period)

    platform_load = platform_wrench(design.platform, op.platform, k)
    platform_state = dynamics_step(design.platform, state.platform, platform_load, dt_hours * 3600;
        method = dynamics_method,
        solve_residual = dynamics_solver,
        time_s = state.time * 3600,
        wave = op.platform.wave_components,
        direction_mode = op.platform.direction_mode,
        validate_coefficients = op.platform.validate_hydrodynamic_coefficients,
        max_relative_coefficient_change = op.platform.max_relative_hydrodynamic_coefficient_change,
        coefficient_diagnostic_callback = op.platform.coefficient_diagnostic_callback,
        throw_on_coefficient_diagnostic =
            op.platform.throw_on_hydrodynamic_coefficient_diagnostic ||
            op.platform.validate_hydrodynamic_coefficients)

    Tstate = promote_type(
        typeof(state.time + dt_hours),
        typeof(bus_voltage),
        typeof(battery_soc),
        typeof(fuel_level),
        typeof(h2_level),
        typeof(desal_level),
        typeof(controller_state.diesel_fuel_used_in_period),
        _platform_state_real_type(platform_state),
    )
    new_state = SystemState{Tstate}(
        convert(Tstate, state.time + dt_hours),
        convert(Tstate, bus_voltage),
        convert(Tstate, battery_soc),
        convert(Tstate, fuel_level),
        convert(Tstate, h2_level),
        convert(Tstate, desal_level),
        ControllerState{Tstate}(convert(Tstate, controller_state.diesel_fuel_used_in_period)),
        _platform_state_as(Tstate, platform_state),
    )

    Tout = promote_type(
        typeof(p_solar),
        typeof(p_wind),
        typeof(p_wave),
        typeof(p_hydro),
        typeof(p_diesel),
        typeof(p_battery),
        typeof(p_load),
        typeof(p_h2),
        typeof(p_desal),
        typeof(net_bus_power),
        typeof(bus_voltage),
        typeof(fuel_used),
        typeof(bus_balance_residual),
        typeof(battery_inventory_residual),
        typeof(diesel_fuel_inventory_residual),
        typeof(h2_inventory_residual),
        typeof(desal_inventory_residual),
    )
    outputs = SystemOutputs{Tout}(
        solar_power_kw = convert(Tout, p_solar),
        wind_power_kw = convert(Tout, p_wind),
        wave_power_kw = convert(Tout, p_wave),
        hydrokinetic_power_kw = convert(Tout, p_hydro),
        diesel_power_kw = convert(Tout, p_diesel),
        battery_power_kw = convert(Tout, p_battery),
        load_power_kw = convert(Tout, p_load),
        h2_power_kw = convert(Tout, p_h2),
        desal_power_kw = convert(Tout, p_desal),
        net_bus_power_kw = convert(Tout, net_bus_power),
        bus_voltage = convert(Tout, bus_voltage),
        diesel_fuel_used = convert(Tout, fuel_used),
        bus_balance_residual_kw = convert(Tout, bus_balance_residual),
        battery_inventory_residual_kwh = convert(Tout, battery_inventory_residual),
        diesel_fuel_inventory_residual = convert(Tout, diesel_fuel_inventory_residual),
        h2_inventory_residual_kg = convert(Tout, h2_inventory_residual),
        desal_inventory_residual_m3 = convert(Tout, desal_inventory_residual),
    )

    return new_state, outputs
end

"""Advance system by one time step using a controller policy to generate setpoints."""
function simulate_step(design::SystemDesign, op::SystemOperation, state::SystemState,
    k::Int, dt_hours; control = controller_step, dynamics_method::Symbol = :explicit,
    dynamics_solver = nothing)

    setpoints = control(design, op, state, k, dt_hours)
    return plant_step(design, op, state, setpoints, k, dt_hours;
        dynamics_method = dynamics_method, dynamics_solver = dynamics_solver)
end

"""Simulate over the length of the load profile, returning states and outputs."""
function simulate(design::SystemDesign, op::SystemOperation, dt_hours;
    control = controller_step, dynamics_method::Symbol = :explicit, dynamics_solver = nothing)

    n = length(op.load.demand)
    Tstate = _state_real_type(design, op, dt_hours)
    states = Vector{SystemState{Tstate}}(undef, n)
    outputs = Vector{SystemOutputs{Tstate}}(undef, n)

    state = SystemState{Tstate}(
        zero(Tstate),
        convert(Tstate, design.bus.voltage_nominal),
        convert(Tstate, op.battery.soc_init),
        convert(Tstate, op.diesel.fuel_level),
        convert(Tstate, op.h2.tank_level_kg),
        convert(Tstate, op.desal.tank_level_m3),
        ControllerState{Tstate}(zero(Tstate)),
        _initial_platform_state(design.platform, Tstate),
    )

    for k in 1:n
        states[k] = state
        state, outputs[k] = simulate_step(design, op, state, k, dt_hours;
            control = control, dynamics_method = dynamics_method, dynamics_solver = dynamics_solver)
    end

    return states, outputs
end

"""In-place simulation into preallocated arrays."""
function simulate!(states::AbstractVector{SystemState}, outputs::AbstractVector{SystemOutputs},
    design::SystemDesign, op::SystemOperation, dt_hours;
    control = controller_step, dynamics_method::Symbol = :explicit, dynamics_solver = nothing)

    n = length(outputs)
    Tstate = _state_real_type(design, op, dt_hours)
    state = SystemState{Tstate}(
        zero(Tstate),
        convert(Tstate, design.bus.voltage_nominal),
        convert(Tstate, op.battery.soc_init),
        convert(Tstate, op.diesel.fuel_level),
        convert(Tstate, op.h2.tank_level_kg),
        convert(Tstate, op.desal.tank_level_m3),
        ControllerState{Tstate}(zero(Tstate)),
        _initial_platform_state(design.platform, Tstate),
    )

    for k in 1:n
        states[k] = state
        state, outputs[k] = simulate_step(design, op, state, k, dt_hours;
            control = control, dynamics_method = dynamics_method, dynamics_solver = dynamics_solver)
    end

    return states, outputs
end
