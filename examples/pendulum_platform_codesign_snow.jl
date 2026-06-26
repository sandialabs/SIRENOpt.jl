"""
Nonlinear pendulum-platform wind/PV/battery co-design with SNOW.

This is the short-horizon motion-aware surrogate requested for the ontology
paper. The mount point is fixed and the platform attitude is a pitch pendulum:
a ballast mass below the mount supplies nonlinear restoring torque while a
sinusoidal wave-like torque excites the platform. Wind thrust from the moving
base UnsteadyKineticRotorDynamics rotor feeds back into the same pitch equation, and
platform pitch changes PVlib plane-of-array geometry. The optimizer sizes the
PV array, wind rating, battery energy/power, and ballast mass while choosing
wind utilization, PV accepted bus power, and battery dispatch to satisfy a
constant 100 W load.

The NLP enforces hard residuals for bus balance, AgnosticStorageDynamics SOC
updates, PV availability, pendulum kinematics, and nonlinear pitch dynamics. It
is a surrogate motion case, not a validated hydrodynamic platform model.
"""

using Dates
using Printf
using Statistics

import PVlib
import Plots
import UnsteadyKineticRotorDynamics

using SIRENOpt
using SNOW
using Ipopt

ENV["GKSwstype"] = "100"

const PENDULUM_CODESIGN_CASE = "pendulum_platform_codesign_snow"
const PC_BUS_VOLTAGE = 40.0
const PC_LOAD_W = 100.0
const PC_LOAD_KW = PC_LOAD_W / 1000.0
const PC_DEFAULT_HORIZON_S = 180.0
const PC_DEFAULT_DT_S = 3.0
const PC_WAVE_PERIOD_S = 30.0
const PC_WAVE_TORQUE_NM = 55.0
const PC_WAVE_PHASE_RAD = pi / 7
const PC_W_PER_KW = 1000.0
const PC_SECONDS_PER_HOUR = 3600.0
const PC_J_PER_KWH = 3.6e6
const PC_GRAVITY = 9.80665
const PC_SMOOTH_HARDNESS = 1.0e6
const PC_MIN_SOURCE_FRACTION = 0.10
const PC_THETA_LIMIT_RAD = 0.32
const PC_OMEGA_LIMIT_RAD_S = 0.55

const PC_COST = (
    solar_per_m2 = 334.0,
    wind_per_kw = 4000.0,
    battery_per_kwh = 160.0,
    battery_power_per_kw = 40.0,
    ballast_per_kg = 5.0,
)

_pc_smooth_max(a, b) = SIRENOpt.smooth_max(a, b; hardness = PC_SMOOTH_HARDNESS)
_pc_smooth_min(a, b) = SIRENOpt.smooth_min(a, b; hardness = PC_SMOOTH_HARDNESS)
_pc_smooth_clamp(x, lo, hi) =
    SIRENOpt.smooth_clamp(x, lo, hi; hardness = PC_SMOOTH_HARDNESS)
_pc_smooth_abs(x) = SIRENOpt.smooth_abs(x; delta = 1.0e-8)
_real_value(x::Real) = Float64(x)

function _csv_value(value)
    if value isa Bool
        return value ? "1" : "0"
    elseif value isa Integer
        return string(value)
    elseif value isa Real
        return @sprintf("%.12g", _real_value(value))
    else
        text = string(value)
        return "\"" * replace(text, "\"" => "\"\"") * "\""
    end
end

function _write_csv(path, rows, columns)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, join(columns, ","))
        for row in rows
            println(io, join((_csv_value(get(row, column, "")) for column in columns), ","))
        end
    end
    return path
end

function _weather_at(t_s)
    minute = div(Int(round(t_s)), 60)
    second = mod(Int(round(t_s)), 60)
    time = PVlib.ZonedDateTime(2020, 6, 1, 12, minute, second,
        PVlib.TimeZone("America/Denver"))
    return PVlib.WeatherSample{Float64}(
        time = time,
        ghi = 770.0 + 20.0 * sin(2pi * t_s / 72.0 + 0.15),
        dni = 845.0 + 18.0 * sin(2pi * t_s / 81.0),
        dhi = 112.0 + 6.0 * cos(2pi * t_s / 63.0),
        temp_air = 20.0 + 0.3 * sin(2pi * t_s / 180.0),
        temp_dew = 10.0,
        relative_humidity = 50.0,
        pressure = 101_325.0,
        wind_speed = 1.5,
        wind_direction = 180.0,
        albedo = 0.10,
    )
end

function _wind_speed_at(t_s)
    return 7.4 + 0.45 * sin(2pi * t_s / 18.0 + 0.25) +
        0.15 * sin(2pi * t_s / 7.5)
end

function _converter_bus(model::PowerConverterModel, device_power_kw)
    eta = powerconverter_efficiency(model, device_power_kw)
    supply_weight = (one(device_power_kw) + tanh(PC_SMOOTH_HARDNESS * device_power_kw)) / 2
    signed_efficiency = supply_weight * eta + (one(device_power_kw) - supply_weight) / eta
    bus_power_kw = device_power_kw * signed_efficiency
    loss_w = _pc_smooth_abs(device_power_kw - bus_power_kw) * PC_W_PER_KW
    return (bus_power_kw = bus_power_kw, eta = eta, loss_w = loss_w)
end

function _converter_model_at_source(model::PowerConverterModel, source_voltage)
    return PowerConverterModel(model.params, model.state, source_voltage)
end

function build_pendulum_platform_codesign_case(; horizon_s = PC_DEFAULT_HORIZON_S,
        dt_s = PC_DEFAULT_DT_S)
    n = Int(round(horizon_s / dt_s))
    isapprox(n * dt_s, horizon_s; atol = 1.0e-9) ||
        throw(ArgumentError("horizon_s must be an integer multiple of dt_s"))
    times_s = [k * dt_s for k in 0:n]
    weather = [_weather_at(t) for t in times_s]
    solar_position = [PVlib.get_solar_position(35.1, -106.6, 1500.0, w)
        for w in weather]

    rotor_model = simple_ccblade_rotor_model(
        rotor_radius = 0.75,
        hub_radius = 0.08,
        blades = 2,
        n_sections = 3,
        chord_fraction = 0.10,
        omega_rad_s = 23.0,
        hub_height = 3.0,
        shear_exp = 0.08,
        dt_s = dt_s,
        fluid = :air,
    )
    generator_model = generatorse_pmsg_arms_model(
        rated_power_kw = 0.60,
        shaft_rpm = rotor_model.omega_rad_s * 60 / (2pi),
        rad_ag = 0.08,
        len_s = 0.08,
        h_s = 0.01,
        tau_p = 0.02,
        h_m = 0.003,
        h_ys = 0.01,
        h_yr = 0.01,
        b_st = 0.04,
        d_s = 0.04,
        t_ws = 0.004,
        n_r = 3.0,
        n_s = 3.0,
        b_r = 0.04,
        d_r = 0.04,
        t_wr = 0.004,
        D_shaft = 0.03,
    )
    pv_model = pvlib_solar_model(
        surface_tilt_deg = 30.0,
        surface_azimuth_deg = 180.0,
        altitude_m = 1500.0,
    )
    wind_converter = powerconverter_model(
        rated_power_kw = 0.60,
        reference_bus_voltage = PC_BUS_VOLTAGE,
        source_voltage = max(generator_model.phase_voltage_rms, 1.0),
        efficiency_floor = 0.88,
        efficiency_ceiling = 0.985,
    )
    pv_converter = powerconverter_model(
        rated_power_kw = 0.50,
        reference_bus_voltage = PC_BUS_VOLTAGE,
        source_voltage = 32.0,
        efficiency_floor = 0.90,
        efficiency_ceiling = 0.985,
    )
    battery_converter = powerconverter_model(
        rated_power_kw = 0.50,
        reference_bus_voltage = PC_BUS_VOLTAGE,
        source_voltage = PC_BUS_VOLTAGE,
        efficiency_floor = 0.90,
        efficiency_ceiling = 0.985,
    )
    load_converter = powerconverter_model(
        rated_power_kw = 0.20,
        reference_bus_voltage = PC_BUS_VOLTAGE,
        source_voltage = PC_BUS_VOLTAGE,
        efficiency_floor = 0.98,
        efficiency_ceiling = 0.995,
    )
    storage_template = SIRENOpt.AgnosticStorageDynamics.StorageParams(
        energy_capacity = 1.0,
        charge_rate_max = 1.0,
        discharge_rate_max = 1.0,
        standing_loss_rate = 0.0,
    )

    return (
        n = n,
        dt_s = dt_s,
        dt_hours = dt_s / PC_SECONDS_PER_HOUR,
        horizon_s = horizon_s,
        times_s = times_s,
        weather = weather,
        solar_position = solar_position,
        rotor_model = rotor_model,
        generator_model = generator_model,
        pv_model = pv_model,
        wind_converter = wind_converter,
        pv_converter = pv_converter,
        battery_converter = battery_converter,
        load_converter = load_converter,
        storage_template = storage_template,
        pv_base_tilt_deg = 30.0,
        base_platform_mass_kg = 55.0,
        base_pitch_inertia_kg_m2 = 2600.0,
        component_pitch_radius_m = 0.35,
        ballast_arm_m = 1.20,
        linear_damping_nm_s = 60.0,
        quadratic_damping_scale = 0.045,
        solar_mass_per_area_kg_m2 = 14.0,
        wind_mass_base_kg = 8.0,
        wind_mass_per_kw_kg = 45.0,
        battery_mass_per_kwh_kg = 18.0,
        converter_mass_kg = 0.75,
        initial_soc = 0.55,
    )
end

function _indices(n)
    cursor = 0
    idx_design = (cursor + 1):(cursor + 5)
    cursor = last(idx_design)
    idx_batt = (cursor + 1):(cursor + n)
    cursor = last(idx_batt)
    idx_wind_use = (cursor + 1):(cursor + n)
    cursor = last(idx_wind_use)
    idx_pv_bus = (cursor + 1):(cursor + n)
    cursor = last(idx_pv_bus)
    idx_soc = (cursor + 1):(cursor + n + 1)
    cursor = last(idx_soc)
    idx_theta = (cursor + 1):(cursor + n + 1)
    cursor = last(idx_theta)
    idx_omega = (cursor + 1):(cursor + n + 1)
    cursor = last(idx_omega)
    idx_alpha = (cursor + 1):(cursor + n)
    return (
        design = idx_design,
        battery = idx_batt,
        wind_use = idx_wind_use,
        pv_bus = idx_pv_bus,
        soc = idx_soc,
        theta = idx_theta,
        omega = idx_omega,
        alpha = idx_alpha,
        n = n,
        n_nodes = n + 1,
        nvars = last(idx_alpha),
    )
end

function _unpack(x, idx)
    return (
        design = view(x, idx.design),
        battery = view(x, idx.battery),
        wind_use = view(x, idx.wind_use),
        pv_bus = view(x, idx.pv_bus),
        soc = view(x, idx.soc),
        theta = view(x, idx.theta),
        omega = view(x, idx.omega),
        alpha = view(x, idx.alpha),
    )
end

function _design_from_x(case, xd)
    solar_area_m2, wind_rating_kw, battery_kwh, battery_power_kw, ballast_kg = xd
    T = promote_type(typeof(solar_area_m2), typeof(wind_rating_kw), typeof(battery_kwh),
        typeof(battery_power_kw), typeof(ballast_kg))
    battery = BatteryDesign{T}(
        capacity_kwh = battery_kwh,
        max_charge_kw = battery_power_kw,
        max_discharge_kw = battery_power_kw,
        charge_efficiency = T(sqrt(0.92)),
        discharge_efficiency = T(sqrt(0.92)),
        reserve_soc = T(0.05),
        mass = T(case.battery_mass_per_kwh_kg) * battery_kwh,
        storage_model = case.storage_template,
    )
    return (
        solar_area_m2 = solar_area_m2,
        wind_rating_kw = wind_rating_kw,
        battery_kwh = battery_kwh,
        battery_power_kw = battery_power_kw,
        ballast_kg = ballast_kg,
        battery = battery,
    )
end

function _component_mass(case, design)
    solar_mass = case.solar_mass_per_area_kg_m2 * design.solar_area_m2
    wind_mass = case.wind_mass_base_kg + case.wind_mass_per_kw_kg * design.wind_rating_kw
    battery_mass = case.battery_mass_per_kwh_kg * design.battery_kwh
    converter_mass = 4 * case.converter_mass_kg
    return case.base_platform_mass_kg + solar_mass + wind_mass + battery_mass +
        converter_mass + case.generator_model.mass_kg
end

function _pitch_inertia(case, design)
    component_mass = _component_mass(case, design)
    return case.base_pitch_inertia_kg_m2 +
        component_mass * case.component_pitch_radius_m^2 +
        design.ballast_kg * case.ballast_arm_m^2
end

function _wave_torque(t_s)
    return PC_WAVE_TORQUE_NM * sin(2pi * t_s / PC_WAVE_PERIOD_S + PC_WAVE_PHASE_RAD)
end

function _pendulum_torques(case, design, theta, omega, wind_pitch_moment, t_s)
    restoring = -design.ballast_kg * PC_GRAVITY * case.ballast_arm_m * sin(theta)
    linear_damping = -case.linear_damping_nm_s * omega
    quadratic_damping = -case.quadratic_damping_scale * design.ballast_kg *
        case.ballast_arm_m^2 * _pc_smooth_abs(omega) * omega
    wave = _wave_torque(t_s) + zero(theta + omega)
    total = wave + wind_pitch_moment + restoring + linear_damping + quadratic_damping
    return (
        total = total,
        wave = wave,
        wind = wind_pitch_moment,
        restoring = restoring,
        linear_damping = linear_damping,
        quadratic_damping = quadratic_damping,
    )
end

function _initial_rotor_state(case, prototype = 0.0)
    model = case.rotor_model
    z = zero(prototype)
    arm = (z, z, model.hub_height + z)
    ops, info = UnsteadyKineticRotorDynamics.windturbine_op_motion(
        _wind_speed_at(0.0) + z,
        model.omega_rad_s,
        model.pitch_rad,
        model.radii,
        model.precone_rad,
        model.yaw_rad,
        model.tilt_rad,
        model.azimuth_rad,
        model.hub_height,
        model.shear_exp,
        1.225 + z;
        base_pos = (z, z, z),
        base_vel = (z, z, z),
        base_angles = (z, z, z),
        base_omega = (z, z, z),
        arm = arm,
        mu = model.dynamic_viscosity + z,
        asound = model.sound_speed + z,
    )
    return UnsteadyKineticRotorDynamics.UnsteadyState(
        model.sections,
        ops;
        V_wake_old = info.Vhub_eff,
        time = z,
    )
end

function _wind_snapshot!(case, rotor_state, theta, omega, wind_rating_kw, t_s)
    model = case.rotor_model
    z = zero(theta + omega + wind_rating_kw)
    wind_speed = _wind_speed_at(t_s) + z
    arm = (z, z, model.hub_height + z)
    ops, info = UnsteadyKineticRotorDynamics.windturbine_op_motion(
        wind_speed,
        model.omega_rad_s,
        model.pitch_rad,
        model.radii,
        model.precone_rad,
        model.yaw_rad,
        model.tilt_rad,
        model.azimuth_rad,
        model.hub_height,
        model.shear_exp,
        1.225 + z;
        base_pos = (z, z, z),
        base_vel = (z, z, z),
        base_angles = (z, theta, z),
        base_omega = (z, omega, z),
        arm = arm,
        mu = model.dynamic_viscosity + z,
        asound = model.sound_speed + z,
    )
    rotor_loads = UnsteadyKineticRotorDynamics.unsteady_loads_step!(
        rotor_state,
        model.rotor,
        model.sections,
        ops,
        model.params;
        dt = case.dt_s + z,
        azimuth = model.azimuth_rad + z,
        omega = model.omega_rad_s + z,
    )
    thrust_n = rotor_loads.thrust_n
    torque_nm = rotor_loads.torque_nm
    shaft_kw = _pc_smooth_max(rotor_loads.shaft_power_w / PC_W_PER_KW,
        zero(rotor_loads.shaft_power_w))
    eta = clamp(case.generator_model.efficiency, 0.0, 1.0) + zero(shaft_kw)
    generated_kw = _pc_smooth_min(shaft_kw * eta,
        case.generator_model.rated_power_kw + zero(shaft_kw))
    capped_kw = _pc_smooth_min(generated_kw, wind_rating_kw)
    wind_conv = _converter_bus(case.wind_converter, capped_kw)
    pitch_moment = thrust_n * model.hub_height * cos(theta)
    return (
        wind_speed_m_s = wind_speed,
        effective_hub_speed_m_s = info.Vhub_eff,
        effective_yaw_rad = info.yaw_eff,
        effective_tilt_rad = info.tilt_eff,
        thrust_n = thrust_n,
        torque_nm = torque_nm,
        shaft_power_kw = shaft_kw,
        generator_power_kw = capped_kw,
        bus_power_kw = wind_conv.bus_power_kw,
        converter_efficiency = wind_conv.eta,
        converter_loss_w = wind_conv.loss_w,
        pitch_moment_nm = pitch_moment,
    )
end

function _pvlib_snapshot(case, solar_area_m2, theta, k)
    model = case.pv_model
    tilt = _pc_smooth_clamp(
        case.pv_base_tilt_deg + 180.0 / pi * theta,
        oftype(theta, 2.0),
        oftype(theta, 88.0),
    )
    module_area = model.pv_module.area + zero(solar_area_m2)
    scale = solar_area_m2 / _pc_smooth_max(module_area, oftype(solar_area_m2, 1.0e-9))
    total = PVlib.get_total_irradiance(
        tilt + zero(solar_area_m2),
        model.surface_azimuth_deg + zero(solar_area_m2),
        case.weather[k],
        case.solar_position[k],
        model.albedo + zero(solar_area_m2),
    )
    cell_temp = PVlib.sapm_cell_temperature(total, case.weather[k];
        a = model.pv_module.a,
        b = model.pv_module.b,
        deltaT = model.pv_module.dtc,
    )
    effective = PVlib.sapm_effective_irradiance(
        total,
        model.pv_module,
        case.solar_position[k],
        tilt + zero(solar_area_m2),
        model.surface_azimuth_deg + zero(solar_area_m2),
        model.altitude_m + zero(solar_area_m2),
    )
    dc = PVlib.sapm_dc_components(model.pv_module, effective, cell_temp)
    dc_power_kw = _pc_smooth_max(scale * dc.p_mp / PC_W_PER_KW, zero(solar_area_m2))
    return (
        tilt_deg = tilt,
        poa_global_w_m2 = total.poa_global,
        cell_temperature_c = cell_temp.cell_temperature,
        dc_power_kw = dc_power_kw,
        dc_voltage_v = dc.v_mp + zero(solar_area_m2),
        dc_current_a = scale * dc.i_mp,
    )
end

function _battery_bus(case, design, soc, command_kw)
    params = generic_storage_params(design.battery)
    initial_energy = soc * design.battery.capacity_kwh * PC_J_PER_KWH
    charge_kw = command_kw >= zero(command_kw) ? zero(command_kw) : -command_kw
    discharge_kw = command_kw >= zero(command_kw) ? command_kw : zero(command_kw)
    storage = SIRENOpt.AgnosticStorageDynamics.simulate_storage(
        [charge_kw * PC_W_PER_KW],
        [discharge_kw * PC_W_PER_KW],
        params;
        dt = case.dt_s,
        initial_energy = initial_energy,
    )
    soc_next = storage.energy[end] / (design.battery.capacity_kwh * PC_J_PER_KWH)
    device_kw = (storage.discharge_power[1] - storage.charge_power[1]) / PC_W_PER_KW
    conv = _converter_bus(case.battery_converter, device_kw)
    return (
        soc_next = soc_next,
        device_power_kw = device_kw,
        bus_power_kw = conv.bus_power_kw,
        converter_efficiency = conv.eta,
        converter_loss_w = conv.loss_w,
    )
end

_load_bus(case) = _converter_bus(case.load_converter, -PC_LOAD_KW).bus_power_kw

function _inverse_converter_device_power(model::PowerConverterModel, bus_power_kw)
    eta = powerconverter_efficiency(model, bus_power_kw)
    return bus_power_kw >= zero(bus_power_kw) ? bus_power_kw / eta : bus_power_kw * eta
end

function _capital_cost(case, design)
    return PC_COST.solar_per_m2 * design.solar_area_m2 +
        PC_COST.wind_per_kw * design.wind_rating_kw +
        PC_COST.battery_per_kwh * design.battery_kwh +
        PC_COST.battery_power_per_kw * design.battery_power_kw +
        PC_COST.ballast_per_kg * design.ballast_kg
end

function _initial_guess(case, idx)
    xd0 = [1.05, 0.012, 0.0012, 0.022, 56.0]
    design0 = _design_from_x(case, xd0)
    theta = zeros(case.n + 1)
    omega = zeros(case.n + 1)
    alpha = zeros(case.n)
    soc = fill(case.initial_soc, case.n + 1)
    battery = zeros(case.n)
    wind_use = zeros(case.n)
    pv_bus = zeros(case.n)
    rotor_state = _initial_rotor_state(case)
    load_bus_kw = _load_bus(case)

    for k in 1:case.n
        wind = _wind_snapshot!(case, rotor_state, theta[k], omega[k],
            design0.wind_rating_kw, case.times_s[k])
        torques = _pendulum_torques(case, design0, theta[k], omega[k],
            wind.pitch_moment_nm, case.times_s[k])
        alpha[k] = torques.total / _pitch_inertia(case, design0)
        omega[k + 1] = omega[k] + case.dt_s * alpha[k]
        theta[k + 1] = theta[k] + case.dt_s * omega[k + 1]

        pv = _pvlib_snapshot(case, design0.solar_area_m2, theta[k], k)
        pv_converter = _converter_model_at_source(case.pv_converter,
            _pc_smooth_max(pv.dc_voltage_v, oftype(pv.dc_voltage_v, 1.0e-6)))
        pv_available_bus = _converter_bus(pv_converter, pv.dc_power_kw).bus_power_kw
        target_source_bus = -load_bus_kw
        wind_use[k] = clamp(
            0.45 * target_source_bus / max(wind.bus_power_kw, 1.0e-6),
            0.05,
            0.95,
        )
        wind_bus = wind_use[k] * wind.bus_power_kw
        pv_bus[k] = clamp(target_source_bus - wind_bus, 0.0, pv_available_bus)
        source_bus = wind_bus + pv_bus[k]
        needed = -(source_bus + load_bus_kw)
        battery[k] = clamp(_inverse_converter_device_power(case.battery_converter, needed),
            -xd0[4], xd0[4])
        batt = _battery_bus(case, design0, soc[k], battery[k])
        soc[k + 1] = clamp(batt.soc_next, 0.10, 0.90)
    end
    soc[1] = case.initial_soc
    return vcat(xd0, battery, wind_use, pv_bus, soc, theta, omega, alpha)
end

function _constraint_counts(n)
    n_init = 3
    n_soc = n
    n_bus = n
    n_pv_availability = 2n
    n_omega = n
    n_theta = n
    n_dyn = n
    n_battery_power = 2n
    n_motion = 4n
    n_terminal = 1
    n_source = 2
    return (
        init = n_init,
        soc = n_soc,
        bus = n_bus,
        pv_availability = n_pv_availability,
        omega = n_omega,
        theta = n_theta,
        dynamics = n_dyn,
        battery_power = n_battery_power,
        motion = n_motion,
        terminal = n_terminal,
        source = n_source,
        total = n_init + n_soc + n_bus + n_pv_availability + n_omega + n_theta + n_dyn +
            n_battery_power + n_motion + n_terminal + n_source,
    )
end

function _constraint_ranges(counts)
    cursor = 0
    init = (cursor + 1):(cursor + counts.init)
    cursor = last(init)
    soc = (cursor + 1):(cursor + counts.soc)
    cursor = last(soc)
    bus = (cursor + 1):(cursor + counts.bus)
    cursor = last(bus)
    pv_availability = (cursor + 1):(cursor + counts.pv_availability)
    cursor = last(pv_availability)
    omega = (cursor + 1):(cursor + counts.omega)
    cursor = last(omega)
    theta = (cursor + 1):(cursor + counts.theta)
    cursor = last(theta)
    dynamics = (cursor + 1):(cursor + counts.dynamics)
    cursor = last(dynamics)
    battery_power = (cursor + 1):(cursor + counts.battery_power)
    cursor = last(battery_power)
    motion = (cursor + 1):(cursor + counts.motion)
    cursor = last(motion)
    terminal = (cursor + 1):(cursor + counts.terminal)
    cursor = last(terminal)
    source = (cursor + 1):(cursor + counts.source)
    return (
        init = init,
        soc = soc,
        bus = bus,
        pv_availability = pv_availability,
        omega = omega,
        theta = theta,
        dynamics = dynamics,
        battery_power = battery_power,
        motion = motion,
        terminal = terminal,
        source = source,
    )
end

function _fill_constraints!(g, case, idx, ranges, x; record = false)
    parts = _unpack(x, idx)
    design = _design_from_x(case, parts.design)
    load_bus_kw = _load_bus(case)
    load_energy_kwh = PC_LOAD_KW * case.horizon_s / PC_SECONDS_PER_HOUR
    wind_energy_kwh = zero(eltype(x))
    pv_energy_kwh = zero(eltype(x))
    rows = Dict{String,Any}[]

    g[ranges.init[1]] = parts.soc[1] - case.initial_soc
    g[ranges.init[2]] = parts.theta[1]
    g[ranges.init[3]] = parts.omega[1]

    rotor_state = _initial_rotor_state(case, zero(first(x)))
    inertia = _pitch_inertia(case, design)
    component_mass = _component_mass(case, design)

    for k in 1:case.n
        theta_next = parts.theta[k] + case.dt_s * parts.omega[k + 1]
        omega_next = parts.omega[k] + case.dt_s * parts.alpha[k]
        wind = _wind_snapshot!(case, rotor_state, parts.theta[k], parts.omega[k],
            design.wind_rating_kw, case.times_s[k])
        torques = _pendulum_torques(case, design, parts.theta[k], parts.omega[k],
            wind.pitch_moment_nm, case.times_s[k])
        dyn_residual = inertia * parts.alpha[k] - torques.total

        pv = _pvlib_snapshot(case, design.solar_area_m2, parts.theta[k], k)
        pv_converter = _converter_model_at_source(case.pv_converter,
            _pc_smooth_max(pv.dc_voltage_v, oftype(pv.dc_voltage_v, 1.0e-6)))
        pv_conv = _converter_bus(pv_converter, pv.dc_power_kw)
        batt = _battery_bus(case, design, parts.soc[k], parts.battery[k])
        wind_bus_kw = parts.wind_use[k] * wind.bus_power_kw
        pv_bus_kw = parts.pv_bus[k]
        bus_residual_kw = wind_bus_kw + pv_bus_kw + batt.bus_power_kw + load_bus_kw
        pv_utilization = pv_bus_kw /
            _pc_smooth_max(pv_conv.bus_power_kw, oftype(pv_bus_kw, 1.0e-9))

        g[ranges.soc[k]] = parts.soc[k + 1] - batt.soc_next
        g[ranges.bus[k]] = bus_residual_kw
        g[ranges.pv_availability[2k - 1]] = pv_bus_kw
        g[ranges.pv_availability[2k]] = pv_conv.bus_power_kw - pv_bus_kw
        g[ranges.omega[k]] = parts.omega[k + 1] - omega_next
        g[ranges.theta[k]] = parts.theta[k + 1] - theta_next
        g[ranges.dynamics[k]] = dyn_residual / 120.0
        g[ranges.battery_power[2k - 1]] = design.battery_power_kw - parts.battery[k]
        g[ranges.battery_power[2k]] = design.battery_power_kw + parts.battery[k]
        g[ranges.motion[4k - 3]] = PC_THETA_LIMIT_RAD - parts.theta[k + 1]
        g[ranges.motion[4k - 2]] = PC_THETA_LIMIT_RAD + parts.theta[k + 1]
        g[ranges.motion[4k - 1]] = PC_OMEGA_LIMIT_RAD_S - parts.omega[k + 1]
        g[ranges.motion[4k]] = PC_OMEGA_LIMIT_RAD_S + parts.omega[k + 1]

        wind_energy_kwh += wind_bus_kw * case.dt_hours
        pv_energy_kwh += pv_bus_kw * case.dt_hours

        if record
            push!(rows, Dict{String,Any}(
                "case" => PENDULUM_CODESIGN_CASE,
                "step" => k,
                "time_s" => case.times_s[k],
                "dt_s" => case.dt_s,
                "load_w" => PC_LOAD_W,
                "theta_rad" => _real_value(parts.theta[k + 1]),
                "omega_rad_s" => _real_value(parts.omega[k + 1]),
                "alpha_rad_s2" => _real_value(parts.alpha[k]),
                "pitch_inertia_kg_m2" => _real_value(inertia),
                "wave_torque_nm" => _real_value(torques.wave),
                "wind_pitch_moment_nm" => _real_value(torques.wind),
                "ballast_restoring_torque_nm" => _real_value(torques.restoring),
                "linear_damping_torque_nm" => _real_value(torques.linear_damping),
                "quadratic_damping_torque_nm" => _real_value(torques.quadratic_damping),
                "pendulum_dynamic_residual_nm" => _real_value(dyn_residual),
                "wind_speed_m_s" => _real_value(wind.wind_speed_m_s),
                "wind_effective_hub_speed_m_s" => _real_value(wind.effective_hub_speed_m_s),
                "wind_effective_yaw_rad" => _real_value(wind.effective_yaw_rad),
                "wind_effective_tilt_rad" => _real_value(wind.effective_tilt_rad),
                "wind_thrust_n" => _real_value(wind.thrust_n),
                "wind_torque_nm" => _real_value(wind.torque_nm),
                "wind_shaft_power_kw" => _real_value(wind.shaft_power_kw),
                "wind_generator_power_kw" => _real_value(wind.generator_power_kw),
                "wind_utilization" => _real_value(parts.wind_use[k]),
                "wind_bus_power_kw" => _real_value(wind_bus_kw),
                "wind_converter_efficiency" => _real_value(wind.converter_efficiency),
                "pv_tilt_deg" => _real_value(pv.tilt_deg),
                "pv_poa_global_w_m2" => _real_value(pv.poa_global_w_m2),
                "pv_dc_power_kw" => _real_value(pv.dc_power_kw),
                "pv_available_bus_power_kw" => _real_value(pv_conv.bus_power_kw),
                "pv_utilization" => _real_value(pv_utilization),
                "pv_bus_power_kw" => _real_value(pv_bus_kw),
                "pv_converter_efficiency" => _real_value(pv_conv.eta),
                "battery_command_kw" => _real_value(parts.battery[k]),
                "battery_device_power_kw" => _real_value(batt.device_power_kw),
                "battery_bus_power_kw" => _real_value(batt.bus_power_kw),
                "battery_soc" => _real_value(parts.soc[k + 1]),
                "bus_residual_w" => _real_value(bus_residual_kw * PC_W_PER_KW),
                "component_mass_kg" => _real_value(component_mass),
                "ballast_mass_kg" => _real_value(design.ballast_kg),
            ))
        end
    end
    g[only(ranges.terminal)] = parts.soc[end] - case.initial_soc
    g[first(ranges.source)] = wind_energy_kwh / load_energy_kwh - PC_MIN_SOURCE_FRACTION
    g[last(ranges.source)] = pv_energy_kwh / load_energy_kwh - PC_MIN_SOURCE_FRACTION

    return (
        rows = rows,
        wind_energy_kwh = wind_energy_kwh,
        pv_energy_kwh = pv_energy_kwh,
    )
end

function _bounds(case, idx)
    lx_design = [0.05, 0.005, 0.0010, 0.020, 5.0]
    ux_design = [3.00, 0.500, 0.0800, 0.400, 140.0]
    lx = vcat(
        lx_design,
        fill(-ux_design[4], case.n),
        fill(0.0, case.n),
        fill(0.0, case.n),
        fill(0.05, idx.n_nodes),
        fill(-PC_THETA_LIMIT_RAD, idx.n_nodes),
        fill(-PC_OMEGA_LIMIT_RAD_S, idx.n_nodes),
        fill(-1.40, case.n),
    )
    ux = vcat(
        ux_design,
        fill(ux_design[4], case.n),
        fill(1.0, case.n),
        fill(0.60, case.n),
        fill(0.95, idx.n_nodes),
        fill(PC_THETA_LIMIT_RAD, idx.n_nodes),
        fill(PC_OMEGA_LIMIT_RAD_S, idx.n_nodes),
        fill(1.40, case.n),
    )
    return lx, ux
end

function _solve_pendulum_platform_codesign(; horizon_s = PC_DEFAULT_HORIZON_S,
        dt_s = PC_DEFAULT_DT_S, max_iter = 500, print_level = 0,
        derivative_mode = "ad")
    case = build_pendulum_platform_codesign_case(horizon_s = horizon_s, dt_s = dt_s)
    idx = _indices(case.n)
    counts = _constraint_counts(case.n)
    ranges = _constraint_ranges(counts)
    x0 = _initial_guess(case, idx)
    lx, ux = _bounds(case, idx)

    lg = zeros(counts.total)
    ug = fill(Inf, counts.total)
    for range in (ranges.init, ranges.soc, ranges.bus, ranges.omega,
            ranges.theta, ranges.dynamics, ranges.terminal)
        ug[range] .= 0.0
    end

    function obj!(g, x)
        _fill_constraints!(g, case, idx, ranges, x; record = false)
        parts = _unpack(x, idx)
        design = _design_from_x(case, parts.design)
        curtailment_metric = sum((1 .- parts.wind_use).^2)
        motion_metric = sum(abs2, parts.theta) + 0.1 * sum(abs2, parts.omega)
        return _capital_cost(case, design) / PC_LOAD_W +
            1.0e-5 * curtailment_metric + 1.0e-4 * motion_metric
    end

    solver = IPOPT(Dict(
        "print_level" => print_level,
        "max_iter" => max_iter,
        "tol" => 1.0e-7,
        "constr_viol_tol" => 1.0e-7,
        "acceptable_tol" => 1.0e-6,
    ))
    derivatives = lowercase(derivative_mode) == "fd" ? ForwardFD() : ForwardAD()
    options = Options(derivatives = derivatives, solver = solver)
    solve_start = time()
    x_opt, f_opt, status, _ = minimize(obj!, x0, counts.total, lx, ux, lg, ug, options)
    solve_seconds = time() - solve_start
    g = zeros(counts.total)
    replay = _fill_constraints!(g, case, idx, ranges, x_opt; record = true)
    return (
        case = case,
        idx = idx,
        counts = counts,
        ranges = ranges,
        x = x_opt,
        objective = f_opt,
        status = string(status),
        solve_seconds = solve_seconds,
        g = g,
        replay = replay,
        derivatives = lowercase(derivative_mode) == "fd" ? "ForwardFD" : "ForwardAD",
    )
end

function _summary(result)
    case = result.case
    idx = result.idx
    parts = _unpack(result.x, idx)
    design = _design_from_x(case, parts.design)
    rows = result.replay.rows
    bus = [row["bus_residual_w"] for row in rows]
    dyn = [row["pendulum_dynamic_residual_nm"] for row in rows]
    wind_bus = [row["wind_bus_power_kw"] for row in rows]
    pv_bus = [row["pv_bus_power_kw"] for row in rows]
    batt_bus = [row["battery_bus_power_kw"] for row in rows]
    load_energy_kwh = PC_LOAD_KW * case.horizon_s / PC_SECONDS_PER_HOUR
    return Dict{String,Any}(
        "case" => PENDULUM_CODESIGN_CASE,
        "scope" => "snownlp_nonlinear_pendulum_wind_pv_battery_codesign",
        "method" => "direct_transcription_with_nonlinear_pendulum_residual_and_package_backed_component_feedback",
        "solver_status" => result.status,
        "derivatives" => result.derivatives,
        "solve_seconds" => result.solve_seconds,
        "steps" => case.n,
        "dt_s" => case.dt_s,
        "horizon_s" => case.horizon_s,
        "samples_per_wave_period" => PC_WAVE_PERIOD_S / case.dt_s,
        "load_w" => PC_LOAD_W,
        "objective_cost_per_load_w_usd_per_w" => result.objective,
        "solar_area_m2" => design.solar_area_m2,
        "wind_capacity_w" => design.wind_rating_kw * PC_W_PER_KW,
        "battery_capacity_wh" => design.battery_kwh * 1000,
        "battery_power_capacity_w" => design.battery_power_kw * PC_W_PER_KW,
        "ballast_mass_kg" => design.ballast_kg,
        "component_mass_kg" => _component_mass(case, design),
        "pitch_inertia_kg_m2" => _pitch_inertia(case, design),
        "wind_energy_fraction_of_load" => sum(wind_bus) * case.dt_hours / load_energy_kwh,
        "pv_energy_fraction_of_load" => sum(pv_bus) * case.dt_hours / load_energy_kwh,
        "mean_wind_bus_power_w" => mean(wind_bus) * PC_W_PER_KW,
        "mean_pv_bus_power_w" => mean(pv_bus) * PC_W_PER_KW,
        "mean_battery_bus_power_w" => mean(batt_bus) * PC_W_PER_KW,
        "final_battery_soc" => parts.soc[end],
        "min_battery_soc" => minimum(parts.soc),
        "max_battery_soc" => maximum(parts.soc),
        "max_abs_bus_residual_w" => maximum(abs.(bus)),
        "max_abs_pendulum_dynamic_residual_nm" => maximum(abs.(dyn)),
        "max_abs_theta_rad" => maximum(abs.(parts.theta)),
        "max_abs_omega_rad_s" => maximum(abs.(parts.omega)),
        "uses_nonlinear_pendulum_platform" => true,
        "uses_periodic_wave_torque" => true,
        "uses_unsteadykinetic_moving_base_wind" => true,
        "uses_pvlib_attitude_coupled_solar" => true,
        "uses_powerconverterdynamics" => true,
        "uses_agnosticstoragedynamics" => true,
    )
end

function _plot_solution(rows, figure_dir)
    isempty(figure_dir) && return String[]
    mkpath(figure_dir)
    t = [row["time_s"] for row in rows]
    theta = [row["theta_rad"] for row in rows]
    omega = [row["omega_rad_s"] for row in rows]
    alpha = [row["alpha_rad_s2"] for row in rows]
    wave = [row["wave_torque_nm"] for row in rows]
    wind_moment = [row["wind_pitch_moment_nm"] for row in rows]
    restoring = [row["ballast_restoring_torque_nm"] for row in rows]
    damping = [row["linear_damping_torque_nm"] + row["quadratic_damping_torque_nm"] for row in rows]
    dyn = [row["pendulum_dynamic_residual_nm"] for row in rows]
    wind_bus = [row["wind_bus_power_kw"] * PC_W_PER_KW for row in rows]
    pv_bus = [row["pv_bus_power_kw"] * PC_W_PER_KW for row in rows]
    batt_bus = [row["battery_bus_power_kw"] * PC_W_PER_KW for row in rows]
    soc = [row["battery_soc"] for row in rows]
    bus = [row["bus_residual_w"] for row in rows]
    vhub = [row["wind_effective_hub_speed_m_s"] for row in rows]
    thrust = [row["wind_thrust_n"] for row in rows]
    pv_poa = [row["pv_poa_global_w_m2"] for row in rows]
    pv_tilt = [row["pv_tilt_deg"] for row in rows]

    Plots.default(
        size = (840, 760),
        dpi = 170,
        linewidth = 1.8,
        foreground_color_legend = nothing,
        background_color = :white,
        fontfamily = "Computer Modern",
    )

    p_motion_1 = Plots.plot(t, theta,
        label = "Pitch angle",
        xlabel = "Time (s)",
        ylabel = "Theta (rad)",
        title = "Optimized nonlinear pendulum platform")
    Plots.plot!(p_motion_1, t, fill(PC_THETA_LIMIT_RAD, length(t)),
        label = "Angle limit", linestyle = :dash)
    Plots.plot!(p_motion_1, t, fill(-PC_THETA_LIMIT_RAD, length(t)),
        label = "", linestyle = :dash)
    p_motion_2 = Plots.plot(t, [omega alpha],
        label = ["Pitch rate" "Pitch acceleration"],
        xlabel = "Time (s)",
        ylabel = "Rate / acceleration")
    p_motion_3 = Plots.plot(t, [wave wind_moment restoring damping],
        label = ["Wave torque" "Wind moment" "Ballast restoring" "Damping"],
        xlabel = "Time (s)",
        ylabel = "Torque (N m)")
    motion_path = joinpath(figure_dir, "pendulum_platform_motion.png")
    Plots.savefig(Plots.plot(p_motion_1, p_motion_2, p_motion_3, layout = (3, 1)),
        motion_path)

    p_power_1 = Plots.plot(t, [wind_bus pv_bus batt_bus fill(PC_LOAD_W, length(t))],
        label = ["Wind bus" "PV bus" "Battery bus" "Load"],
        xlabel = "Time (s)",
        ylabel = "Power (W)",
        title = "Optimized 40 V bus balance")
    p_power_2 = Plots.plot(t, bus,
        label = "Bus residual",
        xlabel = "Time (s)",
        ylabel = "Residual (W)")
    p_power_3 = Plots.plot(t, soc,
        label = "Battery SOC",
        xlabel = "Time (s)",
        ylabel = "SOC")
    power_path = joinpath(figure_dir, "pendulum_platform_power_bus.png")
    Plots.savefig(Plots.plot(p_power_1, p_power_2, p_power_3, layout = (3, 1)),
        power_path)

    p_io_1 = Plots.plot(t, [vhub thrust],
        label = ["Effective hub speed (m/s)" "Thrust (N)"],
        xlabel = "Time (s)",
        ylabel = "Wind I/O",
        title = "Motion-coupled component inputs")
    p_io_2 = Plots.plot(t, [pv_poa pv_tilt],
        label = ["PV POA (W/m2)" "PV tilt (deg)"],
        xlabel = "Time (s)",
        ylabel = "PV I/O")
    p_io_3 = Plots.plot(t, dyn,
        label = "Pendulum residual",
        xlabel = "Time (s)",
        ylabel = "Residual (N m)")
    io_path = joinpath(figure_dir, "pendulum_platform_component_io.png")
    Plots.savefig(Plots.plot(p_io_1, p_io_2, p_io_3, layout = (3, 1)), io_path)

    return [motion_path, power_path, io_path]
end

function run_pendulum_platform_codesign_snow(;
        output_dir = joinpath(@__DIR__, "results"),
        figure_dir = joinpath(@__DIR__, "results", "pendulum_platform_codesign_figures"),
        horizon_s = parse(Float64, get(ENV, "SIRENOPT_PC_HORIZON_S",
            string(PC_DEFAULT_HORIZON_S))),
        dt_s = parse(Float64, get(ENV, "SIRENOPT_PC_DT_S", string(PC_DEFAULT_DT_S))),
        max_iter = parse(Int, get(ENV, "SIRENOPT_PC_MAX_ITER", "500")),
        print_level = parse(Int, get(ENV, "SIRENOPT_PC_PRINT_LEVEL", "0")),
        derivative_mode = get(ENV, "SIRENOPT_PC_DERIVATIVES", "fd"))
    result = _solve_pendulum_platform_codesign(
        horizon_s = horizon_s,
        dt_s = dt_s,
        max_iter = max_iter,
        print_level = print_level,
        derivative_mode = derivative_mode,
    )
    summary = _summary(result)
    rows = result.replay.rows
    figures = _plot_solution(rows, figure_dir)
    summary_path = joinpath(output_dir, "pendulum_platform_codesign_summary.csv")
    timeseries_path = joinpath(output_dir, "pendulum_platform_codesign_timeseries.csv")
    summary_columns = [
        "case", "scope", "method", "solver_status", "derivatives",
        "solve_seconds", "steps", "dt_s", "horizon_s",
        "samples_per_wave_period", "load_w",
        "objective_cost_per_load_w_usd_per_w", "solar_area_m2",
        "wind_capacity_w", "battery_capacity_wh", "battery_power_capacity_w",
        "ballast_mass_kg", "component_mass_kg", "pitch_inertia_kg_m2",
        "wind_energy_fraction_of_load", "pv_energy_fraction_of_load",
        "mean_wind_bus_power_w", "mean_pv_bus_power_w",
        "mean_battery_bus_power_w", "final_battery_soc",
        "min_battery_soc", "max_battery_soc", "max_abs_bus_residual_w",
        "max_abs_pendulum_dynamic_residual_nm", "max_abs_theta_rad",
        "max_abs_omega_rad_s", "uses_nonlinear_pendulum_platform",
        "uses_periodic_wave_torque", "uses_unsteadykinetic_moving_base_wind",
        "uses_pvlib_attitude_coupled_solar", "uses_powerconverterdynamics",
        "uses_agnosticstoragedynamics",
    ]
    timeseries_columns = [
        "case", "step", "time_s", "dt_s", "load_w",
        "theta_rad", "omega_rad_s", "alpha_rad_s2",
        "pitch_inertia_kg_m2", "wave_torque_nm", "wind_pitch_moment_nm",
        "ballast_restoring_torque_nm", "linear_damping_torque_nm",
        "quadratic_damping_torque_nm", "pendulum_dynamic_residual_nm",
        "wind_speed_m_s", "wind_effective_hub_speed_m_s",
        "wind_effective_yaw_rad", "wind_effective_tilt_rad",
        "wind_thrust_n", "wind_torque_nm", "wind_shaft_power_kw",
        "wind_generator_power_kw", "wind_utilization", "wind_bus_power_kw",
        "wind_converter_efficiency", "pv_tilt_deg", "pv_poa_global_w_m2",
        "pv_dc_power_kw", "pv_available_bus_power_kw", "pv_utilization",
        "pv_bus_power_kw", "pv_converter_efficiency", "battery_command_kw",
        "battery_device_power_kw", "battery_bus_power_kw", "battery_soc",
        "bus_residual_w", "component_mass_kg", "ballast_mass_kg",
    ]
    _write_csv(summary_path, [summary], summary_columns)
    _write_csv(timeseries_path, rows, timeseries_columns)
    return (
        summary = summary,
        rows = rows,
        summary_path = summary_path,
        timeseries_path = timeseries_path,
        figure_paths = figures,
        raw = result,
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_pendulum_platform_codesign_snow()
    println("Pendulum/SIRENOpt dynamic co-design")
    println("  status: ", result.summary["solver_status"])
    println("  steps: ", result.summary["steps"], ", dt: ",
        result.summary["dt_s"], " s")
    println("  max bus residual: ",
        @sprintf("%.4g", result.summary["max_abs_bus_residual_w"]), " W")
    println("  max pendulum residual: ",
        @sprintf("%.4g", result.summary["max_abs_pendulum_dynamic_residual_nm"]),
        " N m")
end
