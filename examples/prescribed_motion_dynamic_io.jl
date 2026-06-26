"""
Prescribed-motion wind/solar/battery shooting exercise.

This is a one-shot dynamic I/O exercise rather than an optimizer. A placeholder
platform receives logged component masses and loads, but returns prescribed
surge, sway, and heave motion. The wind turbine uses the moving-base
UnsteadyKineticRotorDynamics path, wind torque-derived shaft power is
converted by GeneratorSE and PowerConverterDynamics, PVlib power is passed
through a PowerConverterDynamics converter, and battery charge/discharge is
advanced with AgnosticStorageDynamics. The bus draw is a constant 100 W at 40 V.
"""

using Dates
import ForwardDiff
using Printf
using Statistics

import PVlib
import Plots
import UnsteadyKineticRotorDynamics

using SIRENOpt

ENV["GKSwstype"] = "100"

const PRESCRIBED_MOTION_CASE = "prescribed_motion_dynamic_io"
const PM_BUS_VOLTAGE = 40.0
const PM_LOAD_W = 100.0
const PM_LOAD_KW = PM_LOAD_W / 1000.0
const PM_LOAD_CURRENT_A = PM_LOAD_W / PM_BUS_VOLTAGE
const PM_DEFAULT_STEPS = 10
const PM_DEFAULT_DT_S = 1.5
const PM_SURGE_PERIOD_S = 30.0
const PM_SWAY_PERIOD_S = 20.0
const PM_HEAVE_PERIOD_S = 12.0
const PM_W_PER_KW = 1000.0
const PM_SECONDS_PER_HOUR = 3600.0
const PM_J_PER_KWH = 3.6e6
const PM_GRAVITY = 9.80665

_real_value(x::ForwardDiff.Dual) = ForwardDiff.value(x)
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
        ghi = 760.0 + 22.0 * sin(2pi * t_s / 18.0 + 0.2),
        dni = 840.0 + 18.0 * sin(2pi * t_s / 21.0),
        dhi = 115.0 + 6.0 * cos(2pi * t_s / 16.0),
        temp_air = 21.0 + 0.2 * sin(2pi * t_s / 30.0),
        temp_dew = 10.0,
        relative_humidity = 50.0,
        pressure = 101_325.0,
        wind_speed = 1.5,
        wind_direction = 180.0,
        albedo = 0.10,
    )
end

function _motion_state(t_s, x)
    surge_amp, sway_amp, heave_amp = x[1], x[2], x[3]
    zero_t = zero(surge_amp + sway_amp + heave_amp)
    t = t_s + zero_t

    ws = 2pi / PM_SURGE_PERIOD_S
    wy = 2pi / PM_SWAY_PERIOD_S
    wh = 2pi / PM_HEAVE_PERIOD_S
    sway_phase = oftype(t, pi / 5)
    heave_phase = oftype(t, pi / 4)

    surge = surge_amp * sin(ws * t)
    sway = sway_amp * sin(wy * t + sway_phase)
    heave = heave_amp * sin(wh * t + heave_phase)

    surge_dot = surge_amp * ws * cos(ws * t)
    sway_dot = sway_amp * wy * cos(wy * t + sway_phase)
    heave_dot = heave_amp * wh * cos(wh * t + heave_phase)

    surge_ddot = -surge_amp * ws^2 * sin(ws * t)
    sway_ddot = -sway_amp * wy^2 * sin(wy * t + sway_phase)
    heave_ddot = -heave_amp * wh^2 * sin(wh * t + heave_phase)

    return (
        position = (surge, sway, heave),
        velocity = (surge_dot, sway_dot, heave_dot),
        acceleration = (surge_ddot, sway_ddot, heave_ddot),
    )
end

function _converter_model_at_source(model::PowerConverterModel, source_voltage)
    return PowerConverterModel(model.params, model.state, source_voltage)
end

function _converter_snapshot(model::PowerConverterModel, device_power_kw)
    eta = powerconverter_efficiency(model, device_power_kw)
    bus_power_kw = device_power_kw >= zero(device_power_kw) ?
        device_power_kw * eta : device_power_kw / eta
    source_voltage = model.source_voltage + zero(device_power_kw)
    bus_current_a = bus_power_kw * PM_W_PER_KW / (model.state.bus_voltage + zero(device_power_kw))
    source_current_a =
        abs(device_power_kw) * PM_W_PER_KW /
        max(source_voltage, oftype(source_voltage, 1.0e-9))
    loss_w = abs(device_power_kw - bus_power_kw) * PM_W_PER_KW
    return (
        eta = eta,
        bus_power_kw = bus_power_kw,
        source_current_a = source_current_a,
        bus_current_a = bus_current_a,
        loss_w = loss_w,
    )
end

function _pvlib_snapshot(model::PvlibSolarModel, array_area_m2, weather, solar_position)
    module_area = model.pv_module.area + zero(array_area_m2)
    scale = array_area_m2 / SIRENOpt.smooth_max(module_area, oftype(array_area_m2, 1.0e-9))
    total = PVlib.get_total_irradiance(
        model.surface_tilt_deg + zero(array_area_m2),
        model.surface_azimuth_deg + zero(array_area_m2),
        weather,
        solar_position,
        model.albedo + zero(array_area_m2),
    )
    cell_temp = PVlib.sapm_cell_temperature(total, weather;
        a = model.pv_module.a,
        b = model.pv_module.b,
        deltaT = model.pv_module.dtc,
    )
    effective = PVlib.sapm_effective_irradiance(
        total,
        model.pv_module,
        solar_position,
        model.surface_tilt_deg + zero(array_area_m2),
        model.surface_azimuth_deg + zero(array_area_m2),
        model.altitude_m + zero(array_area_m2),
    )
    dc = PVlib.sapm_dc_components(model.pv_module, effective, cell_temp)
    dc_power_kw = SIRENOpt.smooth_max(scale * dc.p_mp / PM_W_PER_KW, zero(array_area_m2))
    dc_current_a = scale * dc.i_mp
    return (
        total_irradiance = total,
        cell_temperature = cell_temp,
        effective_irradiance = effective,
        dc = dc,
        array_scale = scale,
        dc_power_kw = dc_power_kw,
        dc_voltage_v = dc.v_mp + zero(array_area_m2),
        dc_current_a = dc_current_a,
    )
end

function _battery_device_command(deficit_bus_kw, converter_model, battery_bias_kw)
    eta = powerconverter_efficiency(converter_model, deficit_bus_kw)
    device_power_kw = deficit_bus_kw >= zero(deficit_bus_kw) ?
        deficit_bus_kw / eta : deficit_bus_kw * eta
    return device_power_kw + battery_bias_kw
end

function _central_difference_gradient(f, x; rel_step = 1.0e-5)
    grad = similar(x, Float64)
    for i in eachindex(x)
        h = rel_step * max(abs(Float64(x[i])), 1.0)
        xp = copy(x)
        xm = copy(x)
        xp[i] += h
        xm[i] -= h
        grad[i] = (f(xp) - f(xm)) / (2h)
    end
    return grad
end

function build_prescribed_motion_dynamic_io_case(; n_steps = PM_DEFAULT_STEPS,
        dt_s = PM_DEFAULT_DT_S)
    times_s = [k * dt_s for k in 0:n_steps]
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
        hub_height = 4.0,
        shear_exp = 0.08,
        dt_s = dt_s,
        fluid = :air,
    )
    generator_model = generatorse_pmsg_arms_model(
        rated_power_kw = 0.35,
        shaft_rpm = rotor_model.omega_rad_s * 60 / (2pi),
    )
    pv_model = pvlib_solar_model(
        surface_tilt_deg = 30.0,
        surface_azimuth_deg = 180.0,
        altitude_m = 1500.0,
    )
    wind_converter = powerconverter_model(
        rated_power_kw = 0.35,
        reference_bus_voltage = PM_BUS_VOLTAGE,
        source_voltage = max(generator_model.phase_voltage_rms, 1.0),
        efficiency_floor = 0.88,
        efficiency_ceiling = 0.985,
    )
    pv_converter = powerconverter_model(
        rated_power_kw = 0.25,
        reference_bus_voltage = PM_BUS_VOLTAGE,
        source_voltage = 32.0,
        efficiency_floor = 0.90,
        efficiency_ceiling = 0.985,
    )
    battery_converter = powerconverter_model(
        rated_power_kw = 0.25,
        reference_bus_voltage = PM_BUS_VOLTAGE,
        source_voltage = PM_BUS_VOLTAGE,
        efficiency_floor = 0.90,
        efficiency_ceiling = 0.985,
    )
    storage_template = SIRENOpt.AgnosticStorageDynamics.StorageParams(
        energy_capacity = 1.0,
        charge_rate_max = 1.0,
        discharge_rate_max = 1.0,
        standing_loss_rate = 0.0,
    )
    battery_design = BatteryDesign{Float64}(
        capacity_kwh = 0.025,
        max_charge_kw = 0.25,
        max_discharge_kw = 0.25,
        charge_efficiency = sqrt(0.92),
        discharge_efficiency = sqrt(0.92),
        reserve_soc = 0.05,
        mass = 2.0,
        storage_model = storage_template,
    )

    return (
        n_steps = n_steps,
        dt_s = dt_s,
        horizon_s = n_steps * dt_s,
        times_s = times_s,
        weather = weather,
        solar_position = solar_position,
        rotor_model = rotor_model,
        generator_model = generator_model,
        pv_model = pv_model,
        wind_converter = wind_converter,
        pv_converter = pv_converter,
        battery_converter = battery_converter,
        battery_design = battery_design,
        solar_mass_per_area_kg_m2 = 14.0,
        wind_structural_mass_kg = 8.0,
        converter_mass_kg = 0.75,
        base_platform_mass_kg = 40.0,
        initial_soc = 0.55,
    )
end

function _simulate_prescribed_motion_dynamic_io(x;
        n_steps = PM_DEFAULT_STEPS, dt_s = PM_DEFAULT_DT_S, record = false)
    case = build_prescribed_motion_dynamic_io_case(n_steps = n_steps, dt_s = dt_s)
    dt_hours = dt_s / PM_SECONDS_PER_HOUR
    model = case.rotor_model
    zero_t = zero(sum(x))

    motion0 = _motion_state(zero_t, x)
    wind_speed0 = 7.6 + x[4]
    arm = (zero_t, zero_t, model.hub_height + zero_t)
    base_angles = (zero_t, zero_t, zero_t)
    base_omega = (zero_t, zero_t, zero_t)
    ops0, info0 = UnsteadyKineticRotorDynamics.windturbine_op_motion(
        wind_speed0,
        model.omega_rad_s,
        model.pitch_rad,
        model.radii,
        model.precone_rad,
        model.yaw_rad,
        model.tilt_rad,
        model.azimuth_rad,
        model.hub_height,
        model.shear_exp,
        1.225 + zero_t;
        base_pos = motion0.position,
        base_vel = motion0.velocity,
        base_angles = base_angles,
        base_omega = base_omega,
        arm = arm,
        mu = model.dynamic_viscosity + zero_t,
        asound = model.sound_speed + zero_t,
    )
    rotor_state = UnsteadyKineticRotorDynamics.UnsteadyState(
        model.sections,
        ops0;
        V_wake_old = info0.Vhub_eff,
        time = zero_t,
    )

    soc = case.initial_soc + zero_t
    rows = Dict{String,Any}[]
    objective = zero_t
    max_bus_residual_kw = zero_t
    min_soc = soc
    max_soc = soc
    sum_wind_bus_kw = zero_t
    sum_pv_bus_kw = zero_t
    sum_battery_bus_kw = zero_t
    sum_thrust_n = zero_t
    max_platform_force_x_n = zero_t
    max_platform_weight_n = zero_t

    for k in 1:case.n_steps
        t_s = (k - 1) * case.dt_s
        motion = _motion_state(t_s, x)
        wind_speed = 7.6 + 0.35 * sin(2pi * t_s / 9.0) + x[4]

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
            1.225 + zero_t;
            base_pos = motion.position,
            base_vel = motion.velocity,
            base_angles = base_angles,
            base_omega = base_omega,
            arm = arm,
            mu = model.dynamic_viscosity + zero_t,
            asound = model.sound_speed + zero_t,
        )
        rotor_loads = UnsteadyKineticRotorDynamics.unsteady_loads_step!(
            rotor_state,
            model.rotor,
            model.sections,
            ops,
            model.params;
            dt = case.dt_s + zero_t,
            azimuth = model.azimuth_rad + zero_t,
            omega = model.omega_rad_s + zero_t,
        )
        thrust_n = rotor_loads.thrust_n
        torque_nm = rotor_loads.torque_nm
        shaft_power_kw = SIRENOpt.smooth_max(
            rotor_loads.shaft_power_w / PM_W_PER_KW,
            zero(rotor_loads.shaft_power_w),
        )
        wind_generator_kw = generatorse_output_kw(case.generator_model, shaft_power_kw)
        wind_conv = _converter_snapshot(case.wind_converter, wind_generator_kw)

        solar_area = x[5]
        pv = _pvlib_snapshot(case.pv_model, solar_area, case.weather[k],
            case.solar_position[k])
        pv_converter = _converter_model_at_source(case.pv_converter,
            SIRENOpt.smooth_max(pv.dc_voltage_v, oftype(pv.dc_voltage_v, 1.0e-6)))
        pv_conv = _converter_snapshot(pv_converter, pv.dc_power_kw)

        deficit_bus_kw = PM_LOAD_KW + zero_t - wind_conv.bus_power_kw - pv_conv.bus_power_kw
        battery_cmd_kw = _battery_device_command(deficit_bus_kw, case.battery_converter, x[6])
        soc_next, battery_device_kw = generic_storage_step(case.battery_design,
            soc, battery_cmd_kw, dt_hours)
        battery_conv = _converter_snapshot(case.battery_converter, battery_device_kw)

        bus_residual_kw =
            wind_conv.bus_power_kw + pv_conv.bus_power_kw + battery_conv.bus_power_kw -
            (PM_LOAD_KW + zero_t)
        bus_residual_w = bus_residual_kw * PM_W_PER_KW
        bus_residual_current_a = bus_residual_w / PM_BUS_VOLTAGE

        solar_mass_kg = solar_area * case.solar_mass_per_area_kg_m2
        component_mass_kg =
            case.base_platform_mass_kg +
            solar_mass_kg +
            case.wind_structural_mass_kg +
            case.generator_model.mass_kg +
            case.battery_design.mass +
            3 * case.converter_mass_kg
        platform_force_x_n = thrust_n
        platform_force_y_n = zero(thrust_n)
        platform_force_z_n = -component_mass_kg * PM_GRAVITY
        platform_moment_x_nm = torque_nm
        platform_moment_y_nm = thrust_n * (model.hub_height + motion.position[3])
        required_inertial_force_x_n = component_mass_kg * motion.acceleration[1]
        required_inertial_force_y_n = component_mass_kg * motion.acceleration[2]
        required_inertial_force_z_n = component_mass_kg * motion.acceleration[3]

        objective += bus_residual_kw^2 +
            oftype(bus_residual_kw, 1.0e-6) * (thrust_n / oftype(thrust_n, 100.0))^2 +
            oftype(bus_residual_kw, 1.0e-4) * (soc_next - oftype(soc_next, 0.55))^2
        max_bus_residual_kw = max(max_bus_residual_kw, abs(bus_residual_kw))
        min_soc = min(min_soc, soc_next)
        max_soc = max(max_soc, soc_next)
        sum_wind_bus_kw += wind_conv.bus_power_kw
        sum_pv_bus_kw += pv_conv.bus_power_kw
        sum_battery_bus_kw += battery_conv.bus_power_kw
        sum_thrust_n += thrust_n
        max_platform_force_x_n = max(max_platform_force_x_n, abs(platform_force_x_n))
        max_platform_weight_n = max(max_platform_weight_n, abs(platform_force_z_n))

        if record
            push!(rows, Dict{String,Any}(
                "case" => PRESCRIBED_MOTION_CASE,
                "step" => k,
                "time_s" => t_s,
                "dt_s" => case.dt_s,
                "bus_voltage_v" => PM_BUS_VOLTAGE,
                "load_w" => PM_LOAD_W,
                "load_current_a" => PM_LOAD_CURRENT_A,
                "surge_m" => _real_value(motion.position[1]),
                "sway_m" => _real_value(motion.position[2]),
                "heave_m" => _real_value(motion.position[3]),
                "surge_velocity_m_s" => _real_value(motion.velocity[1]),
                "sway_velocity_m_s" => _real_value(motion.velocity[2]),
                "heave_velocity_m_s" => _real_value(motion.velocity[3]),
                "surge_acceleration_m_s2" => _real_value(motion.acceleration[1]),
                "sway_acceleration_m_s2" => _real_value(motion.acceleration[2]),
                "heave_acceleration_m_s2" => _real_value(motion.acceleration[3]),
                "wind_speed_m_s" => _real_value(wind_speed),
                "wind_effective_hub_speed_m_s" => _real_value(info.Vhub_eff),
                "wind_effective_yaw_rad" => _real_value(info.yaw_eff),
                "wind_effective_tilt_rad" => _real_value(info.tilt_eff),
                "wind_thrust_n" => _real_value(thrust_n),
                "wind_torque_nm" => _real_value(torque_nm),
                "wind_shaft_power_kw" => _real_value(shaft_power_kw),
                "wind_generator_power_kw" => _real_value(wind_generator_kw),
                "wind_converter_efficiency" => _real_value(wind_conv.eta),
                "wind_bus_power_kw" => _real_value(wind_conv.bus_power_kw),
                "wind_converter_loss_w" => _real_value(wind_conv.loss_w),
                "pv_poa_global_w_m2" => _real_value(pv.total_irradiance.poa_global),
                "pv_cell_temperature_c" => _real_value(pv.cell_temperature.cell_temperature),
                "pv_effective_irradiance_w_m2" =>
                    _real_value(pv.effective_irradiance.effective_irradiance),
                "pv_dc_voltage_v" => _real_value(pv.dc_voltage_v),
                "pv_dc_current_a" => _real_value(pv.dc_current_a),
                "pv_dc_power_kw" => _real_value(pv.dc_power_kw),
                "pv_converter_efficiency" => _real_value(pv_conv.eta),
                "pv_bus_power_kw" => _real_value(pv_conv.bus_power_kw),
                "pv_converter_loss_w" => _real_value(pv_conv.loss_w),
                "battery_command_kw" => _real_value(battery_cmd_kw),
                "battery_device_power_kw" => _real_value(battery_device_kw),
                "battery_bus_power_kw" => _real_value(battery_conv.bus_power_kw),
                "battery_converter_efficiency" => _real_value(battery_conv.eta),
                "battery_converter_loss_w" => _real_value(battery_conv.loss_w),
                "battery_soc" => _real_value(soc_next),
                "battery_energy_wh" =>
                    _real_value(soc_next * case.battery_design.capacity_kwh * 1000),
                "bus_residual_w" => _real_value(bus_residual_w),
                "bus_residual_current_a" => _real_value(bus_residual_current_a),
                "platform_total_logged_mass_kg" => _real_value(component_mass_kg),
                "platform_logged_force_x_n" => _real_value(platform_force_x_n),
                "platform_logged_force_y_n" => _real_value(platform_force_y_n),
                "platform_logged_force_z_n" => _real_value(platform_force_z_n),
                "platform_logged_moment_x_nm" => _real_value(platform_moment_x_nm),
                "platform_logged_moment_y_nm" => _real_value(platform_moment_y_nm),
                "platform_required_inertial_force_x_n" =>
                    _real_value(required_inertial_force_x_n),
                "platform_required_inertial_force_y_n" =>
                    _real_value(required_inertial_force_y_n),
                "platform_required_inertial_force_z_n" =>
                    _real_value(required_inertial_force_z_n),
            ))
        end

        soc = soc_next
    end

    summary = Dict{String,Any}(
        "case" => PRESCRIBED_MOTION_CASE,
        "scope" => "one_shot_prescribed_motion_wind_solar_battery_dynamic_io",
        "method" => "shooting replay with prescribed surge/sway/heave and logged placeholder platform loads",
        "steps" => case.n_steps,
        "dt_s" => case.dt_s,
        "horizon_s" => case.horizon_s,
        "bus_voltage_v" => PM_BUS_VOLTAGE,
        "load_w" => PM_LOAD_W,
        "load_current_a" => PM_LOAD_CURRENT_A,
        "surge_period_s" => PM_SURGE_PERIOD_S,
        "sway_period_s" => PM_SWAY_PERIOD_S,
        "heave_period_s" => PM_HEAVE_PERIOD_S,
        "surge_half_cycles_covered" => case.horizon_s / (PM_SURGE_PERIOD_S / 2),
        "sway_half_cycles_covered" => case.horizon_s / (PM_SWAY_PERIOD_S / 2),
        "heave_half_cycles_covered" => case.horizon_s / (PM_HEAVE_PERIOD_S / 2),
        "final_battery_soc" => _real_value(soc),
        "min_battery_soc" => _real_value(min_soc),
        "max_battery_soc" => _real_value(max_soc),
        "mean_wind_bus_power_w" => _real_value(sum_wind_bus_kw / case.n_steps * PM_W_PER_KW),
        "mean_pv_bus_power_w" => _real_value(sum_pv_bus_kw / case.n_steps * PM_W_PER_KW),
        "mean_battery_bus_power_w" =>
            _real_value(sum_battery_bus_kw / case.n_steps * PM_W_PER_KW),
        "mean_wind_thrust_n" => _real_value(sum_thrust_n / case.n_steps),
        "max_abs_bus_residual_w" => _real_value(max_bus_residual_kw * PM_W_PER_KW),
        "max_abs_platform_logged_force_x_n" => _real_value(max_platform_force_x_n),
        "max_abs_platform_logged_weight_n" => _real_value(max_platform_weight_n),
        "uses_prescribed_platform_motion" => true,
        "uses_ccblade_motion_wrapper" => true,
        "uses_generatorse" => true,
        "uses_pvlib" => true,
        "uses_powerconverterdynamics" => true,
        "uses_agnosticstoragedynamics" => true,
        "uses_wave_energy_converter" => false,
        "objective" => _real_value(objective),
    )
    return (
        case = case,
        x = x,
        summary = summary,
        rows = rows,
        objective = objective,
    )
end

function _gradient_summary(; n_steps = PM_DEFAULT_STEPS, dt_s = PM_DEFAULT_DT_S)
    x0 = [0.40, 0.25, 0.16, 0.0, 0.50, 0.0]
    f(x) = _real_value(_simulate_prescribed_motion_dynamic_io(x;
        n_steps = n_steps, dt_s = dt_s, record = false).objective)
    g_ad = ForwardDiff.gradient(x -> _simulate_prescribed_motion_dynamic_io(x;
        n_steps = n_steps, dt_s = dt_s, record = false).objective, x0)
    g_fd = _central_difference_gradient(f, x0)
    abs_diff = abs.(g_ad .- g_fd)
    rel_diff = abs_diff ./ max.(abs.(g_fd), 1.0e-9)
    pass = maximum(abs_diff) <= 5.0e-4 || maximum(rel_diff) <= 5.0e-2
    return (
        x0 = x0,
        ad = g_ad,
        fd = g_fd,
        abs_diff = abs_diff,
        rel_diff = rel_diff,
        max_abs_diff = maximum(abs_diff),
        max_rel_diff = maximum(rel_diff),
        pass = pass,
    )
end

function _plot_solution(rows, figure_dir)
    isempty(figure_dir) && return String[]
    mkpath(figure_dir)

    t = [row["time_s"] for row in rows]
    surge = [row["surge_m"] for row in rows]
    sway = [row["sway_m"] for row in rows]
    heave = [row["heave_m"] for row in rows]
    surge_v = [row["surge_velocity_m_s"] for row in rows]
    sway_v = [row["sway_velocity_m_s"] for row in rows]
    heave_v = [row["heave_velocity_m_s"] for row in rows]

    wind_bus = [PM_W_PER_KW * row["wind_bus_power_kw"] for row in rows]
    pv_bus = [PM_W_PER_KW * row["pv_bus_power_kw"] for row in rows]
    batt_bus = [PM_W_PER_KW * row["battery_bus_power_kw"] for row in rows]
    residual = [row["bus_residual_w"] for row in rows]
    soc = [row["battery_soc"] for row in rows]

    vhub = [row["wind_effective_hub_speed_m_s"] for row in rows]
    thrust = [row["wind_thrust_n"] for row in rows]
    torque = [row["wind_torque_nm"] for row in rows]
    poa = [row["pv_poa_global_w_m2"] for row in rows]
    pv_dc = [PM_W_PER_KW * row["pv_dc_power_kw"] for row in rows]
    total_mass = [row["platform_total_logged_mass_kg"] for row in rows]
    force_x = [row["platform_logged_force_x_n"] for row in rows]
    force_z = [row["platform_logged_force_z_n"] for row in rows]

    Plots.default(
        size = (780, 720),
        dpi = 160,
        linewidth = 1.8,
        foreground_color_legend = nothing,
        background_color = :white,
        fontfamily = "Computer Modern",
    )

    p_motion_1 = Plots.plot(t, [surge sway heave],
        label = ["Surge" "Sway" "Heave"],
        xlabel = "Time (s)",
        ylabel = "Position (m)",
        title = "Prescribed platform motion")
    p_motion_2 = Plots.plot(t, [surge_v sway_v heave_v],
        label = ["Surge velocity" "Sway velocity" "Heave velocity"],
        xlabel = "Time (s)",
        ylabel = "Velocity (m/s)")
    motion_path = joinpath(figure_dir, "prescribed_motion_positions.png")
    Plots.savefig(Plots.plot(p_motion_1, p_motion_2, layout = (2, 1)), motion_path)

    p_power_1 = Plots.plot(t, [wind_bus pv_bus batt_bus fill(PM_LOAD_W, length(t))],
        label = ["Wind bus" "PV bus" "Battery bus" "Load"],
        xlabel = "Time (s)",
        ylabel = "Power (W)",
        title = "40 V bus power accounting")
    p_power_2 = Plots.plot(t, residual,
        label = "Bus residual",
        xlabel = "Time (s)",
        ylabel = "Residual (W)")
    p_power_3 = Plots.plot(t, soc,
        label = "Battery SOC",
        xlabel = "Time (s)",
        ylabel = "SOC")
    power_path = joinpath(figure_dir, "prescribed_motion_power_bus.png")
    Plots.savefig(Plots.plot(p_power_1, p_power_2, p_power_3, layout = (3, 1)), power_path)

    p_io_1 = Plots.plot(t, [vhub thrust torque],
        label = ["Effective hub speed (m/s)" "Thrust (N)" "Torque (N m)"],
        xlabel = "Time (s)",
        ylabel = "Wind I/O",
        title = "Component dynamic I/O")
    p_io_2 = Plots.plot(t, [poa pv_dc],
        label = ["PV POA global (W/m2)" "PV DC power (W)"],
        xlabel = "Time (s)",
        ylabel = "PV I/O")
    p_io_3 = Plots.plot(t, [total_mass force_x force_z],
        label = ["Logged mass (kg)" "Force x (N)" "Force z (N)"],
        xlabel = "Time (s)",
        ylabel = "Platform log")
    io_path = joinpath(figure_dir, "prescribed_motion_component_io.png")
    Plots.savefig(Plots.plot(p_io_1, p_io_2, p_io_3, layout = (3, 1)), io_path)

    return [motion_path, power_path, io_path]
end

function run_prescribed_motion_dynamic_io(; output_dir = joinpath(@__DIR__, "results"),
        figure_dir = joinpath(@__DIR__, "results", "prescribed_motion_dynamic_io_figures"),
        n_steps = PM_DEFAULT_STEPS, dt_s = PM_DEFAULT_DT_S)
    x0 = [0.40, 0.25, 0.16, 0.0, 0.50, 0.0]
    result = _simulate_prescribed_motion_dynamic_io(x0;
        n_steps = n_steps, dt_s = dt_s, record = true)
    grad = _gradient_summary(n_steps = n_steps, dt_s = dt_s)

    summary = copy(result.summary)
    summary["gradient_variables"] =
        "surge_amp_m;sway_amp_m;heave_amp_m;wind_bias_m_s;solar_area_m2;battery_bias_kw"
    summary["gradient_ad_values"] = join(_csv_value.(grad.ad), ";")
    summary["gradient_fd_values"] = join(_csv_value.(grad.fd), ";")
    summary["gradient_max_abs_diff"] = grad.max_abs_diff
    summary["gradient_max_rel_diff"] = grad.max_rel_diff
    summary["gradient_check_pass"] = grad.pass

    summary_path = joinpath(output_dir, "prescribed_motion_dynamic_io_summary.csv")
    timeseries_path = joinpath(output_dir, "prescribed_motion_dynamic_io_timeseries.csv")
    figures = _plot_solution(result.rows, figure_dir)

    summary_columns = [
        "case", "scope", "method", "steps", "dt_s", "horizon_s",
        "bus_voltage_v", "load_w", "load_current_a",
        "surge_period_s", "sway_period_s", "heave_period_s",
        "surge_half_cycles_covered", "sway_half_cycles_covered",
        "heave_half_cycles_covered", "final_battery_soc",
        "min_battery_soc", "max_battery_soc", "mean_wind_bus_power_w",
        "mean_pv_bus_power_w", "mean_battery_bus_power_w",
        "mean_wind_thrust_n", "max_abs_bus_residual_w",
        "max_abs_platform_logged_force_x_n", "max_abs_platform_logged_weight_n",
        "uses_prescribed_platform_motion", "uses_ccblade_motion_wrapper",
        "uses_generatorse", "uses_pvlib", "uses_powerconverterdynamics",
        "uses_agnosticstoragedynamics", "uses_wave_energy_converter",
        "objective", "gradient_variables", "gradient_ad_values",
        "gradient_fd_values", "gradient_max_abs_diff",
        "gradient_max_rel_diff", "gradient_check_pass",
    ]
    timeseries_columns = [
        "case", "step", "time_s", "dt_s", "bus_voltage_v", "load_w",
        "load_current_a", "surge_m", "sway_m", "heave_m",
        "surge_velocity_m_s", "sway_velocity_m_s", "heave_velocity_m_s",
        "surge_acceleration_m_s2", "sway_acceleration_m_s2",
        "heave_acceleration_m_s2", "wind_speed_m_s",
        "wind_effective_hub_speed_m_s", "wind_effective_yaw_rad",
        "wind_effective_tilt_rad", "wind_thrust_n", "wind_torque_nm",
        "wind_shaft_power_kw", "wind_generator_power_kw",
        "wind_converter_efficiency", "wind_bus_power_kw",
        "wind_converter_loss_w", "pv_poa_global_w_m2",
        "pv_cell_temperature_c", "pv_effective_irradiance_w_m2",
        "pv_dc_voltage_v", "pv_dc_current_a", "pv_dc_power_kw",
        "pv_converter_efficiency", "pv_bus_power_kw", "pv_converter_loss_w",
        "battery_command_kw", "battery_device_power_kw", "battery_bus_power_kw",
        "battery_converter_efficiency", "battery_converter_loss_w",
        "battery_soc", "battery_energy_wh", "bus_residual_w",
        "bus_residual_current_a", "platform_total_logged_mass_kg",
        "platform_logged_force_x_n", "platform_logged_force_y_n",
        "platform_logged_force_z_n", "platform_logged_moment_x_nm",
        "platform_logged_moment_y_nm", "platform_required_inertial_force_x_n",
        "platform_required_inertial_force_y_n",
        "platform_required_inertial_force_z_n",
    ]
    _write_csv(summary_path, [summary], summary_columns)
    _write_csv(timeseries_path, result.rows, timeseries_columns)

    return (
        summary = summary,
        rows = result.rows,
        summary_path = summary_path,
        timeseries_path = timeseries_path,
        figure_paths = figures,
        gradient = grad,
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_prescribed_motion_dynamic_io()
    println("prescribed-motion dynamic I/O shooting exercise")
    println("  steps: ", result.summary["steps"], ", dt: ", result.summary["dt_s"], " s")
    println("  max bus residual: ",
        @sprintf("%.4g", result.summary["max_abs_bus_residual_w"]), " W")
    println("  gradient check pass: ", result.summary["gradient_check_pass"])
end
