"""
Three-minute package-backed SNOW optimization for a constant 100 W load.

The case sizes and dispatches solar, wind, wave, and battery components over a
180 s horizon. Source and storage calculations are routed through SIRENOpt's
package adapters:

  - PVlib for photovoltaic power,
  - UnsteadyKineticRotorDynamics for wind rotor power,
  - GeneratorSE for source conversion efficiency,
  - PowerConverterDynamics for source and battery converter losses,
  - AgnosticStorageDynamics for battery state updates.

The wave path uses the SIRENOpt wave capture-width component with package-backed
generator and converter losses. There is not yet a dedicated WEC dynamics
package adapter in SIRENOpt.

The case uses a high-hardness smooth split for low-power charge/discharge and
source conversion terms so the 100 W demonstration remains differentiable
without introducing order-10 W smoothing artifacts from the package-wide
default smoothing scale.
"""

using Dates
import ForwardDiff
using Printf
using Statistics
using SIRENOpt
using SNOW
using Ipopt
import PVlib
import Plots

ENV["GKSwstype"] = "100"

const THREE_MINUTE_CASE = "three_minute_package_snow"
const LOAD_KW = 0.100
const DEFAULT_HORIZON_S = 180.0
const DEFAULT_DT_S = 1.0
const FASTEST_WAVE_OMEGA_RAD_S = 1.1
const FASTEST_WAVE_PERIOD_S = 2pi / FASTEST_WAVE_OMEGA_RAD_S
const MIN_SOURCE_ENERGY_FRACTION = 0.05
const OBJECTIVE_SCALE = 1000.0
const CASE_STORAGE_SMOOTHING_HARDNESS = 1.0e6
const CASE_J_PER_KWH = 3.6e6
const CASE_W_PER_KW = 1000.0
const CASE_SECONDS_PER_HOUR = 3600.0

const COST = (
    solar_per_m2 = 334.0,
    wind_per_kw = 4000.0,
    wave_capture_per_m = 1500.0,
    wave_rated_per_kw = 2000.0,
    battery_per_kwh = 160.0,
    battery_power_per_kw = 40.0,
)

function _case_bool(value)
    return value ? "1" : "0"
end

function _csv_value(value)
    if value isa Bool
        return _case_bool(value)
    elseif value isa Integer
        return string(value)
    elseif value isa Real
        return @sprintf("%.12g", value)
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

_smooth_replay_scalar(x::Real) = ForwardDiff.Dual{Nothing}(Float64(x), 0.0)
_smooth_replay_vector(xs) = [_smooth_replay_scalar(x) for x in xs]
_real_value(x::ForwardDiff.Dual) = ForwardDiff.value(x)
_real_value(x::Real) = Float64(x)
_case_smooth_max(a, b) = smooth_max(a, b; hardness = CASE_STORAGE_SMOOTHING_HARDNESS)
_case_smooth_min(a, b) = smooth_min(a, b; hardness = CASE_STORAGE_SMOOTHING_HARDNESS)
_case_smooth_clamp(x, lo, hi) = smooth_clamp(x, lo, hi;
    hardness = CASE_STORAGE_SMOOTHING_HARDNESS)

function _initial_weather(::Type{T}, t_s) where {T<:Real}
    time = PVlib.ZonedDateTime(2020, 6, 1, 12, div(Int(round(t_s)), 60),
        mod(Int(round(t_s)), 60), PVlib.TimeZone("America/Denver"))
    return PVlib.WeatherSample{T}(
        time = time,
        ghi = T(780 + 18 * sin(2pi * t_s / 90)),
        dni = T(850 + 25 * sin(2pi * t_s / 95 + 0.2)),
        dhi = T(110 + 8 * cos(2pi * t_s / 75)),
        temp_air = T(20 + 0.4 * sin(2pi * t_s / 180)),
        temp_dew = T(10),
        relative_humidity = T(50),
        pressure = T(101325),
        wind_speed = T(1.5),
        wind_direction = T(180),
        albedo = T(0.10),
    )
end

function build_three_minute_package_operation(; T::Type{<:Real} = Float64,
        horizon_s::Real = DEFAULT_HORIZON_S, dt_s::Real = DEFAULT_DT_S)
    n = Int(round(horizon_s / dt_s))
    time_s = [T((k - 1) * dt_s) for k in 1:n]
    time_h = time_s ./ T(3600)

    weather = [_initial_weather(T, Float64(t)) for t in time_s]
    solar_position = [PVlib.get_solar_position(35.1, -106.6, 1500.0, w)
        for w in weather]

    wind = T.([
        8.0 + 0.55 * sin(2pi * Float64(t) / 18.0) +
        0.18 * sin(2pi * Float64(t) / 5.8 + 0.4)
        for t in time_s
    ])
    wave_hs = [
        0.42 + 0.035 * sin(2pi * Float64(t) / FASTEST_WAVE_PERIOD_S) +
        0.015 * sin(2pi * Float64(t) / 17.0)
        for t in time_s
    ]
    wave_te = [
        5.8 + 0.25 * sin(2pi * Float64(t) / 24.0 + 0.3)
        for t in time_s
    ]
    wave_flux = T.([
        wave_power_flux_kw_per_m(max(wave_hs[k], 0.05), max(wave_te[k], 1.0))
        for k in eachindex(time_s)
    ])

    operation = SystemOperation{T}(
        solar = SolarOp{T}(
            resource = TimeSeries(time_h, zeros(T, n)),
            pv_weather = weather,
            pv_solar_position = solar_position,
        ),
        wind = WindOp{T}(
            resource = TimeSeries(time_h, wind),
            air_density = T(1.225),
        ),
        wave = WaveOp{T}(
            resource = TimeSeries(time_h, wave_flux),
        ),
        load = LoadOp{T}(
            demand = TimeSeries(time_h, fill(T(LOAD_KW), n)),
        ),
        battery = BatteryOp{T}(soc_init = T(0.5)),
    )

    return (
        operation = operation,
        time_s = time_s,
        dt_hours = T(dt_s) / T(3600),
        n = n,
    )
end

function base_three_minute_package_design(; T::Type{<:Real} = Float64,
        dt_s::Real = DEFAULT_DT_S)
    pv_model = pvlib_solar_model(
        surface_tilt_deg = 35.1,
        surface_azimuth_deg = 180.0,
        altitude_m = 1500.0,
    )
    wind_rotor_model = simple_ccblade_rotor_model(
        rotor_radius = T(1.0),
        blades = 2,
        n_sections = 3,
        omega_rad_s = T(20.0),
        fluid = :air,
        dt_s = T(dt_s),
    )
    generator_model = generatorse_pmsg_arms_model(rated_power_kw = 1000.0)
    converter_model = powerconverter_model(
        rated_power_kw = 1.0,
        efficiency_floor = 0.96,
        efficiency_ceiling = 0.985,
    )
    storage_template = SIRENOpt.AgnosticStorageDynamics.StorageParams(
        energy_capacity = 1.0,
        charge_rate_max = 1.0,
        discharge_rate_max = 1.0,
        standing_loss_rate = 0.0,
    )

    source_generator = GeneratorDesign{T}(
        rated_power = T(1.0),
        efficiency = T(1.0),
        generator_model = generator_model,
    )
    source_converter = ConverterDesign{T}(
        rated_power = T(1.0),
        efficiency = T(1.0),
        converter_model = converter_model,
    )

    return SystemDesign{T}(
        solar = SolarDesign{T}(
            area = T(1.0),
            efficiency = one(T),
            mass_per_area = T(14.0),
            cost_per_area = T(COST.solar_per_m2),
            pv_model = pv_model,
        ),
        wind = WindDesign{T}(
            rotor_diameter = T(2.0),
            rated_power = T(0.08),
            cut_in = T(3.0),
            cut_out = T(25.0),
            rotor_model = wind_rotor_model,
        ),
        wave = WaveDesign{T}(
            capture_width = T(0.08),
            rated_power = T(0.05),
        ),
        diesel = DieselDesign{T}(rated_power = zero(T), min_power = zero(T)),
        solar_gen = source_generator,
        wind_gen = source_generator,
        wave_gen = source_generator,
        solar_conv = source_converter,
        wind_conv = source_converter,
        wave_conv = source_converter,
        battery = BatteryDesign{T}(
            capacity_kwh = T(0.003),
            max_charge_kw = T(0.10),
            max_discharge_kw = T(0.10),
            charge_efficiency = T(sqrt(0.90)),
            discharge_efficiency = T(sqrt(0.90)),
            reserve_soc = T(0.0),
            storage_model = storage_template,
        ),
        battery_conv = ConverterDesign{T}(
            rated_power = T(0.10),
            efficiency = T(1.0),
            bi_directional = true,
            converter_model = converter_model,
        ),
        load = LoadDesign{T}(critical_fraction = one(T)),
        load_conv = ConverterDesign{T}(
            rated_power = T(0.20),
            efficiency = T(1.0),
            converter_model = converter_model,
        ),
        platform = PlatformDesign{T}(base_mass = T(0), cost = T(0)),
    )
end

function _design_from_case_x(base_design, x_design)
    solar_area, wind_rated_kw, wave_capture_m, wave_rated_kw,
        battery_kwh, battery_power_kw = x_design

    design = SIRENOpt.with(base_design;
        solar = SIRENOpt.with(base_design.solar; area = solar_area),
        wind = SIRENOpt.with(base_design.wind; rated_power = wind_rated_kw),
        wave = SIRENOpt.with(base_design.wave;
            capture_width = wave_capture_m,
            rated_power = wave_rated_kw),
        battery = SIRENOpt.with(base_design.battery;
            capacity_kwh = battery_kwh,
            max_charge_kw = battery_power_kw,
            max_discharge_kw = battery_power_kw),
        battery_conv = SIRENOpt.with(base_design.battery_conv;
            rated_power = battery_power_kw),
    )

    return design
end

function _capital_cost(design::SystemDesign)
    return COST.solar_per_m2 * design.solar.area +
        COST.wind_per_kw * design.wind.rated_power +
        COST.wave_capture_per_m * design.wave.capture_width +
        COST.wave_rated_per_kw * design.wave.rated_power +
        COST.battery_per_kwh * design.battery.capacity_kwh +
        COST.battery_power_per_kw * design.battery.max_discharge_kw
end

function _case_generator_output(design::GeneratorDesign, op::GeneratorOp, mechanical_power)
    p_in = _case_smooth_max(mechanical_power, zero(mechanical_power))
    eta = if design.generator_model === nothing
        design.efficiency + zero(p_in)
    else
        design.generator_model.efficiency + zero(p_in)
    end
    eta = _case_smooth_clamp(eta, zero(p_in), one(p_in))
    return _case_smooth_min(p_in * eta, design.rated_power + zero(p_in)) *
        op.availability
end

function _case_generator_output_hard(design::GeneratorDesign, op::GeneratorOp, mechanical_power)
    p_in = max(mechanical_power, zero(mechanical_power))
    eta = design.generator_model === nothing ? design.efficiency :
        design.generator_model.efficiency
    return min(p_in * clamp(eta, zero(eta), one(eta)), design.rated_power) *
        op.availability
end

function _case_converter_output(design::ConverterDesign, op::ConverterOp, device_power)
    p = _case_smooth_clamp(device_power, -design.rated_power, design.rated_power)
    p_bus = if design.converter_model === nothing
        p_supply = _case_smooth_max(p, zero(p))
        p_load = _case_smooth_min(p, zero(p))
        p_supply * design.efficiency + p_load / design.efficiency
    else
        eta = powerconverter_efficiency(design.converter_model, p)
        p_supply = _case_smooth_max(p, zero(p))
        p_load = _case_smooth_min(p, zero(p))
        p_supply * eta + p_load / eta
    end
    return p_bus * op.availability
end

function _case_converter_output_hard(design::ConverterDesign, op::ConverterOp, device_power)
    p = clamp(device_power, -design.rated_power, design.rated_power)
    p_bus = if design.converter_model === nothing
        p >= zero(p) ? p * design.efficiency : p / design.efficiency
    else
        eta = powerconverter_efficiency(design.converter_model, p)
        p >= zero(p) ? p * eta : p / eta
    end
    return p_bus * op.availability
end

function _case_power_available_wind(design::WindDesign, op::WindOp, k::Int)
    v = value_at(op.resource, k)
    availability = smooth_step(v - design.cut_in;
        hardness = CASE_STORAGE_SMOOTHING_HARDNESS) *
        smooth_step(design.cut_out - v; hardness = CASE_STORAGE_SMOOTHING_HARDNESS)
    p = design.rotor_model === nothing ?
        0.5 * op.air_density * pi * (design.rotor_diameter / 2)^2 *
            _case_smooth_max(v, zero(v))^3 * design.cp / CASE_W_PER_KW :
        ccblade_rotor_power_kw(design.rotor_model, v, op.air_density)
    return _case_smooth_min(p, design.rated_power) * availability *
        (one(v) - op.curtailment)
end

function _case_power_available_wind_hard(design::WindDesign, op::WindOp, k::Int)
    v = value_at(op.resource, k)
    availability = (v >= design.cut_in && v <= design.cut_out) ? one(v) : zero(v)
    p = design.rotor_model === nothing ?
        0.5 * op.air_density * pi * (design.rotor_diameter / 2)^2 *
            max(v, zero(v))^3 * design.cp / CASE_W_PER_KW :
        ccblade_rotor_power_kw(design.rotor_model, v, op.air_density)
    return min(p, design.rated_power) * availability * (one(v) - op.curtailment)
end

function _case_power_available_wave(design::WaveDesign, op::WaveOp, k::Int)
    resource = value_at(op.resource, k)
    p = resource * design.capture_width
    return _case_smooth_min(p, design.rated_power) * (one(resource) - op.curtailment)
end

function _case_power_available_wave_hard(design::WaveDesign, op::WaveOp, k::Int)
    resource = value_at(op.resource, k)
    p = resource * design.capture_width
    return min(p, design.rated_power) * (one(resource) - op.curtailment)
end

function _source_power_tuple(design, op, k)
    p_solar_raw = power_available_solar(design.solar, op.solar, k)
    p_wind_raw = _case_power_available_wind(design.wind, op.wind, k)
    p_wave_raw = _case_power_available_wave(design.wave, op.wave, k)

    p_solar = _case_converter_output(design.solar_conv, op.solar_conv,
        _case_generator_output(design.solar_gen, op.solar_gen, p_solar_raw))
    p_wind = _case_converter_output(design.wind_conv, op.wind_conv,
        _case_generator_output(design.wind_gen, op.wind_gen, p_wind_raw))
    p_wave = _case_converter_output(design.wave_conv, op.wave_conv,
        _case_generator_output(design.wave_gen, op.wave_gen, p_wave_raw))
    return p_solar, p_wind, p_wave
end

function _source_power_tuple_hard(design, op, k)
    p_solar_raw = power_available_solar(design.solar, op.solar, k)
    p_wind_raw = _case_power_available_wind_hard(design.wind, op.wind, k)
    p_wave_raw = _case_power_available_wave_hard(design.wave, op.wave, k)

    p_solar = _case_converter_output_hard(design.solar_conv, op.solar_conv,
        _case_generator_output_hard(design.solar_gen, op.solar_gen, p_solar_raw))
    p_wind = _case_converter_output_hard(design.wind_conv, op.wind_conv,
        _case_generator_output_hard(design.wind_gen, op.wind_gen, p_wind_raw))
    p_wave = _case_converter_output_hard(design.wave_conv, op.wave_conv,
        _case_generator_output_hard(design.wave_gen, op.wave_gen, p_wave_raw))
    return p_solar, p_wind, p_wave
end

function _case_battery_step(design::BatteryDesign, soc, power_command_kw, dt_hours)
    params = generic_storage_params(design)
    initial_energy = soc * design.capacity_kwh * CASE_J_PER_KWH
    charge_kw = smooth_max(-power_command_kw, zero(power_command_kw);
        hardness = CASE_STORAGE_SMOOTHING_HARDNESS)
    discharge_kw = smooth_max(power_command_kw, zero(power_command_kw);
        hardness = CASE_STORAGE_SMOOTHING_HARDNESS)

    result = SIRENOpt.AgnosticStorageDynamics.simulate_storage(
        [charge_kw * CASE_W_PER_KW],
        [discharge_kw * CASE_W_PER_KW],
        params;
        dt = dt_hours * CASE_SECONDS_PER_HOUR,
        initial_energy = initial_energy,
    )

    capacity_j = design.capacity_kwh * CASE_J_PER_KWH
    soc_new = result.energy[end] / capacity_j
    power_kw = (result.discharge_power[1] - result.charge_power[1]) / CASE_W_PER_KW
    return soc_new, power_kw
end

function _case_indices(n)
    n_design = 6
    idx_design = 1:n_design
    idx_battery = (last(idx_design) + 1):(last(idx_design) + n)
    idx_soc = (last(idx_battery) + 1):(last(idx_battery) + n + 1)
    return idx_design, idx_battery, idx_soc
end

function _inverse_converter_guess(converter_design, op, bus_power_kw)
    eta = powerconverter_efficiency(converter_design.converter_model, bus_power_kw)
    return bus_power_kw >= 0 ? bus_power_kw / eta : bus_power_kw * eta
end

function _initial_guess(base_design, op, n, dt_hours)
    x_design0 = [
        0.75,
        0.030,
        0.055,
        0.030,
        0.006,
        0.090,
    ]
    design0 = _design_from_case_x(base_design, x_design0)
    u_batt0 = zeros(Float64, n)
    soc0 = zeros(Float64, n + 1)
    soc0[1] = op.battery.soc_init
    for k in 1:n
        p_solar, p_wind, p_wave = _source_power_tuple(design0, op, k)
        p_load = _case_converter_output_hard(design0.load_conv, op.load_conv,
            -load_demand(design0.load, op.load, k))
        needed_bus = -(p_solar + p_wind + p_wave + p_load)
        u_batt0[k] = clamp(
            _inverse_converter_guess(design0.battery_conv, op.battery_conv, needed_bus),
            -x_design0[6],
            x_design0[6],
        )
        soc0[k + 1], _ = _case_battery_step(design0.battery, soc0[k],
            u_batt0[k], dt_hours)
    end
    soc0 .-= (soc0[end] - soc0[1]) .* collect(0:n) ./ n
    soc0 .= clamp.(soc0, 0.05, 0.95)
    soc0[1] = op.battery.soc_init
    return vcat(x_design0, u_batt0, soc0)
end

function _solve_three_minute_package_snow(; horizon_s = DEFAULT_HORIZON_S,
        dt_s = DEFAULT_DT_S, max_iter = 300, derivative_mode = "ad",
        print_level = 0)
    T = Float64
    case = build_three_minute_package_operation(T = T, horizon_s = horizon_s, dt_s = dt_s)
    base_design = base_three_minute_package_design(T = T, dt_s = dt_s)
    op = case.operation
    n = case.n
    dt_hours = case.dt_hours
    idx_design, idx_batt, idx_soc = _case_indices(n)

    n_init = 1
    n_dyn = n
    n_bus = n
    n_batt_power = 2n
    n_terminal = 1
    n_source_energy = 3
    ng = n_init + n_dyn + n_bus + n_batt_power + n_terminal + n_source_energy

    g_dyn_start = n_init + 1
    g_bus_start = g_dyn_start + n_dyn
    g_batt_start = g_bus_start + n_bus
    g_terminal = g_batt_start + n_batt_power
    g_source_start = g_terminal + n_terminal

    load_energy_kwh = LOAD_KW * horizon_s / 3600

    function unpack(x)
        return view(x, idx_design), view(x, idx_batt), view(x, idx_soc)
    end

    function obj!(g, x)
        x_design, u_batt, soc = unpack(x)
        design = _design_from_case_x(base_design, x_design)
        g[1] = soc[1] - op.battery.soc_init

        solar_energy = zero(eltype(x))
        wind_energy = zero(eltype(x))
        wave_energy = zero(eltype(x))

        for k in 1:n
            p_solar, p_wind, p_wave = _source_power_tuple(design, op, k)
            soc_next, p_batt_device = _case_battery_step(design.battery,
                soc[k], u_batt[k], dt_hours)
            p_batt = _case_converter_output(design.battery_conv, op.battery_conv, p_batt_device)
            p_load = _case_converter_output(design.load_conv, op.load_conv,
                -load_demand(design.load, op.load, k))

            g[g_dyn_start + k - 1] = soc[k + 1] - soc_next
            g[g_bus_start + k - 1] = p_solar + p_wind + p_wave + p_batt + p_load
            g[g_batt_start + 2k - 2] = design.battery.max_discharge_kw - u_batt[k]
            g[g_batt_start + 2k - 1] = design.battery.max_charge_kw + u_batt[k]

            solar_energy += p_solar * dt_hours
            wind_energy += p_wind * dt_hours
            wave_energy += p_wave * dt_hours
        end

        g[g_terminal] = soc[end] - op.battery.soc_init
        g[g_source_start] = solar_energy / load_energy_kwh - MIN_SOURCE_ENERGY_FRACTION
        g[g_source_start + 1] = wind_energy / load_energy_kwh - MIN_SOURCE_ENERGY_FRACTION
        g[g_source_start + 2] = wave_energy / load_energy_kwh - MIN_SOURCE_ENERGY_FRACTION

        return _capital_cost(design) / OBJECTIVE_SCALE
    end

    x0 = _initial_guess(base_design, op, n, dt_hours)
    lx_design = [0.05, 0.001, 0.001, 0.001, 0.0002, 0.005]
    ux_design = [5.00, 0.600, 1.000, 0.600, 0.0800, 0.500]
    lx = vcat(lx_design, fill(-ux_design[6], n), fill(0.0, n + 1))
    ux = vcat(ux_design, fill(ux_design[6], n), fill(1.0, n + 1))

    lg = vcat(
        zeros(n_init + n_dyn + n_bus),
        zeros(n_batt_power + n_terminal + n_source_energy),
    )
    ug = vcat(
        zeros(n_init + n_dyn + n_bus),
        fill(Inf, n_batt_power + n_terminal + n_source_energy),
    )

    derivatives = lowercase(derivative_mode) == "fd" ? ForwardFD() : ForwardAD()
    solver = IPOPT(Dict(
        "print_level" => print_level,
        "max_iter" => max_iter,
        "tol" => 1.0e-7,
        "constr_viol_tol" => 1.0e-7,
    ))
    options = Options(derivatives = derivatives, solver = solver)

    solve_start = time()
    x_opt, f_opt, status, _ = minimize(obj!, x0, ng, lx, ux, lg, ug, options)
    solve_seconds = time() - solve_start

    g_hard = zeros(T, ng)
    f_hard = obj!(g_hard, x_opt)
    x_smooth = _smooth_replay_vector(x_opt)
    g_smooth_dual = fill(zero(eltype(x_smooth)), ng)
    f_smooth_dual = obj!(g_smooth_dual, x_smooth)
    g_smooth = [_real_value(value) for value in g_smooth_dual]
    f_smooth = _real_value(f_smooth_dual)
    x_design, u_batt, soc = unpack(x_opt)
    design = _design_from_case_x(base_design, x_design)

    return (
        design = design,
        operation = op,
        time_s = case.time_s,
        dt_hours = dt_hours,
        x = x_opt,
        x_design = collect(x_design),
        battery_command_kw = collect(u_batt),
        soc = collect(soc),
        objective_scaled = f_opt,
        objective_scaled_check = f_smooth,
        objective_scaled_check_hard_branch = f_hard,
        status = string(status),
        solve_seconds = solve_seconds,
        g = g_smooth,
        g_hard_branch = g_hard,
        ng = ng,
        load_energy_kwh = load_energy_kwh,
        indices = (
            init = 1:n_init,
            dynamics = g_dyn_start:(g_dyn_start + n_dyn - 1),
            bus = g_bus_start:(g_bus_start + n_bus - 1),
            battery_power = g_batt_start:(g_batt_start + n_batt_power - 1),
            terminal = g_terminal:g_terminal,
            source_energy = g_source_start:(g_source_start + n_source_energy - 1),
        ),
        horizon_s = horizon_s,
        dt_s = dt_s,
        derivatives = lowercase(derivative_mode) == "fd" ? "ForwardFD" : "ForwardAD",
    )
end

function _evaluate_solution(result)
    design = result.design
    op = result.operation
    n = length(result.time_s)
    dt_hours = result.dt_hours
    soc = result.soc
    u_batt = result.battery_command_kw
    smooth_base_design = base_three_minute_package_design(T = Float64, dt_s = result.dt_s)
    smooth_design = _design_from_case_x(smooth_base_design,
        _smooth_replay_vector(result.x_design))
    smooth_dt_hours = _smooth_replay_scalar(dt_hours)
    smooth_soc = _smooth_replay_vector(soc)
    smooth_u_batt = _smooth_replay_vector(u_batt)
    rows = Dict{String,Any}[]

    max_bus = 0.0
    max_dyn = 0.0
    max_batt_bound = 0.0
    max_hard_bus = 0.0
    max_hard_dyn = 0.0
    max_hard_batt_bound = 0.0
    solar_energy = 0.0
    wind_energy = 0.0
    wave_energy = 0.0
    hard_solar_energy = 0.0
    hard_wind_energy = 0.0
    hard_wave_energy = 0.0
    battery_throughput = 0.0

    for k in 1:n
        p_solar_s, p_wind_s, p_wave_s = _source_power_tuple(smooth_design, op, k)
        soc_next_s, p_batt_device_s = _case_battery_step(smooth_design.battery,
            smooth_soc[k], smooth_u_batt[k], smooth_dt_hours)
        p_batt_s = _case_converter_output(smooth_design.battery_conv, op.battery_conv,
            p_batt_device_s)
        p_load_s = _case_converter_output(smooth_design.load_conv, op.load_conv,
            -load_demand(design.load, op.load, k))

        bus = _real_value(p_solar_s + p_wind_s + p_wave_s + p_batt_s + p_load_s)
        dyn = _real_value(smooth_soc[k + 1] - soc_next_s)
        p_solar = _real_value(p_solar_s)
        p_wind = _real_value(p_wind_s)
        p_wave = _real_value(p_wave_s)
        p_batt_device = _real_value(p_batt_device_s)
        p_batt = _real_value(p_batt_s)
        p_load = _real_value(p_load_s)
        batt_bound = max(
            _real_value(smooth_u_batt[k] - smooth_design.battery.max_discharge_kw),
            0.0,
            _real_value(-smooth_u_batt[k] - smooth_design.battery.max_charge_kw),
        )

        hard_p_solar, hard_p_wind, hard_p_wave = _source_power_tuple_hard(design, op, k)
        hard_soc_next, hard_p_batt_device = battery_step(design.battery, op.battery,
            soc[k], u_batt[k], dt_hours)
        hard_p_batt = _case_converter_output_hard(design.battery_conv, op.battery_conv,
            hard_p_batt_device)
        hard_p_load = _case_converter_output_hard(design.load_conv, op.load_conv,
            -load_demand(design.load, op.load, k))
        hard_bus = hard_p_solar + hard_p_wind + hard_p_wave + hard_p_batt + hard_p_load
        hard_dyn = soc[k + 1] - hard_soc_next
        hard_batt_bound = max(
            u_batt[k] - design.battery.max_discharge_kw,
            0.0,
            -u_batt[k] - design.battery.max_charge_kw,
        )

        max_bus = max(max_bus, abs(bus))
        max_dyn = max(max_dyn, abs(dyn))
        max_batt_bound = max(max_batt_bound, batt_bound)
        max_hard_bus = max(max_hard_bus, abs(hard_bus))
        max_hard_dyn = max(max_hard_dyn, abs(hard_dyn))
        max_hard_batt_bound = max(max_hard_batt_bound, hard_batt_bound)
        solar_energy += p_solar * dt_hours
        wind_energy += p_wind * dt_hours
        wave_energy += p_wave * dt_hours
        hard_solar_energy += hard_p_solar * dt_hours
        hard_wind_energy += hard_p_wind * dt_hours
        hard_wave_energy += hard_p_wave * dt_hours
        battery_throughput += abs(p_batt_device) * dt_hours

        push!(rows, Dict{String,Any}(
            "case" => THREE_MINUTE_CASE,
            "time_s" => result.time_s[k],
            "dt_s" => result.dt_s,
            "load_kw" => LOAD_KW,
            "solar_power_kw" => p_solar,
            "wind_power_kw" => p_wind,
            "wave_power_kw" => p_wave,
            "battery_command_kw" => u_batt[k],
            "battery_device_power_kw" => p_batt_device,
            "battery_bus_power_kw" => p_batt,
            "load_bus_power_kw" => p_load,
            "battery_soc" => soc[k + 1],
            "bus_balance_residual_kw" => bus,
            "battery_dynamic_residual_soc" => dyn,
            "hard_branch_solar_power_kw" => hard_p_solar,
            "hard_branch_wind_power_kw" => hard_p_wind,
            "hard_branch_wave_power_kw" => hard_p_wave,
            "hard_branch_battery_device_power_kw" => hard_p_batt_device,
            "hard_branch_battery_bus_power_kw" => hard_p_batt,
            "hard_branch_load_bus_power_kw" => hard_p_load,
            "hard_branch_bus_balance_residual_kw" => hard_bus,
            "hard_branch_battery_dynamic_residual_soc" => hard_dyn,
            "wind_speed_m_per_s" => value_at(op.wind.resource, k),
            "wave_flux_kw_per_m" => value_at(op.wave.resource, k),
        ))
    end

    load_energy = result.load_energy_kwh
    source_fractions = (
        solar = solar_energy / load_energy,
        wind = wind_energy / load_energy,
        wave = wave_energy / load_energy,
    )
    hard_source_fractions = (
        solar = hard_solar_energy / load_energy,
        wind = hard_wind_energy / load_energy,
        wave = hard_wave_energy / load_energy,
    )
    cost = _capital_cost(design)
    max_constraint = maximum(abs.(result.g))
    max_hard_constraint = maximum(abs.(result.g_hard_branch))
    eq_values = vcat(
        result.g[result.indices.init],
        result.g[result.indices.dynamics],
        result.g[result.indices.bus],
    )
    ineq_values = vcat(
        result.g[result.indices.battery_power],
        result.g[result.indices.terminal],
        result.g[result.indices.source_energy],
    )
    hard_eq_values = vcat(
        result.g_hard_branch[result.indices.init],
        result.g_hard_branch[result.indices.dynamics],
        result.g_hard_branch[result.indices.bus],
    )
    hard_ineq_values = vcat(
        result.g_hard_branch[result.indices.battery_power],
        result.g_hard_branch[result.indices.terminal],
        result.g_hard_branch[result.indices.source_energy],
    )
    max_eq_residual = maximum(abs.(eq_values))
    min_ineq_margin = minimum(ineq_values)
    max_hard_eq_residual = maximum(abs.(hard_eq_values))
    min_hard_ineq_margin = minimum(hard_ineq_values)
    feasible = max_bus <= 1.0e-6 && max_dyn <= 1.0e-6 &&
        max_batt_bound <= 1.0e-8 &&
        minimum((source_fractions.solar, source_fractions.wind,
            source_fractions.wave)) >= MIN_SOURCE_ENERGY_FRACTION - 1.0e-6 &&
        soc[end] >= op.battery.soc_init - 1.0e-6

    summary = Dict{String,Any}(
        "case" => THREE_MINUTE_CASE,
        "scope" => "three_minute_constant_100w_package_backed_snow",
        "method" => "SNOW simultaneous nonlinear program with package-backed component adapters and case-local sub-watt smoothing",
        "model_evaluation" => "case_local_high_hardness_smooth_branch",
        "solver" => "SNOW_IPOPT",
        "solver_status" => result.status,
        "derivatives" => result.derivatives,
        "solve_seconds" => result.solve_seconds,
        "horizon_s" => result.horizon_s,
        "dt_s" => result.dt_s,
        "steps" => n,
        "fastest_wave_period_s" => FASTEST_WAVE_PERIOD_S,
        "samples_per_fastest_wave_period" => FASTEST_WAVE_PERIOD_S / result.dt_s,
        "load_w" => LOAD_KW * 1000,
        "load_energy_wh" => load_energy * 1000,
        "reported_total_cost_usd" => cost,
        "objective_cost_per_load_w_usd_per_w" => cost / (LOAD_KW * 1000),
        "solar_area_m2" => design.solar.area,
        "wind_capacity_w" => design.wind.rated_power * 1000,
        "wave_capture_width_m" => design.wave.capture_width,
        "wave_capacity_w" => design.wave.rated_power * 1000,
        "battery_capacity_wh" => design.battery.capacity_kwh * 1000,
        "battery_power_capacity_w" => design.battery.max_discharge_kw * 1000,
        "solar_energy_wh" => solar_energy * 1000,
        "wind_energy_wh" => wind_energy * 1000,
        "wave_energy_wh" => wave_energy * 1000,
        "solar_energy_fraction_of_load" => source_fractions.solar,
        "wind_energy_fraction_of_load" => source_fractions.wind,
        "wave_energy_fraction_of_load" => source_fractions.wave,
        "hard_branch_solar_energy_fraction_of_load" => hard_source_fractions.solar,
        "hard_branch_wind_energy_fraction_of_load" => hard_source_fractions.wind,
        "hard_branch_wave_energy_fraction_of_load" => hard_source_fractions.wave,
        "battery_throughput_wh" => battery_throughput * 1000,
        "terminal_battery_soc" => soc[end],
        "terminal_battery_reserve_shortfall_soc" =>
            max(op.battery.soc_init - soc[end], 0.0),
        "max_abs_bus_balance_residual_kw" => max_bus,
        "max_abs_bus_balance_residual_w" => max_bus * 1000,
        "max_battery_dynamic_residual_soc" => max_dyn,
        "max_battery_power_bound_violation_kw" => max_batt_bound,
        "max_abs_snow_constraint_value" => max_constraint,
        "max_abs_snow_equality_residual" => max_eq_residual,
        "min_snow_inequality_margin" => min_ineq_margin,
        "max_abs_hard_branch_bus_balance_residual_kw" => max_hard_bus,
        "max_abs_hard_branch_bus_balance_residual_w" => max_hard_bus * 1000,
        "max_hard_branch_battery_dynamic_residual_soc" => max_hard_dyn,
        "max_hard_branch_battery_power_bound_violation_kw" => max_hard_batt_bound,
        "max_abs_hard_branch_constraint_value" => max_hard_constraint,
        "max_abs_hard_branch_equality_residual" => max_hard_eq_residual,
        "min_hard_branch_inequality_margin" => min_hard_ineq_margin,
        "min_renewable_energy_fraction_per_source" => MIN_SOURCE_ENERGY_FRACTION,
        "uses_pvlib" => true,
        "uses_unsteadykinetic" => true,
        "uses_generatorse" => true,
        "uses_powerconverterdynamics" => true,
        "uses_agnosticstoragedynamics" => true,
        "uses_platform_motion" => false,
        "uses_mooring" => false,
        "feasible_for_declared_nlp" => feasible,
        "global_optimality_scope" =>
            "local SNOW/Ipopt NLP optimum for declared package-backed 180 s model",
        "hard_branch_diagnostic_note" =>
            "hard min/max replay is reported as a diagnostic; SNOW optimizes the high-hardness smooth component branch",
        "resource_note" =>
            "PVlib weather is deterministic midday data; wind and wave resources include sub-minute sinusoidal variation; each renewable path must supply at least 5 percent of load energy",
    )
    return summary, rows
end

function _plot_solution(rows, summary, figure_path)
    isempty(figure_path) && return nothing
    mkpath(dirname(figure_path))

    t = [row["time_s"] for row in rows]
    solar = [1000 * row["solar_power_kw"] for row in rows]
    wind = [1000 * row["wind_power_kw"] for row in rows]
    wave = [1000 * row["wave_power_kw"] for row in rows]
    batt = [1000 * row["battery_bus_power_kw"] for row in rows]
    soc = [row["battery_soc"] for row in rows]
    bus = [1000 * row["bus_balance_residual_kw"] for row in rows]
    hard_bus = [1000 * row["hard_branch_bus_balance_residual_kw"] for row in rows]

    Plots.default(
        size = (760, 640),
        dpi = 160,
        linewidth = 1.8,
        framestyle = :axes,
        grid = false,
        legend = :topright,
        guidefontsize = 10,
        tickfontsize = 9,
        legendfontsize = 9,
        titlefontsize = 10,
    )

    p1 = Plots.plot(t, [solar wind wave fill(100.0, length(t))],
        label = ["solar" "wind" "wave" "load"],
        xlabel = "time [s]",
        ylabel = "power [W]",
        title = "Package-backed source dispatch")
    p2 = Plots.plot(t, batt,
        label = "battery bus power",
        xlabel = "time [s]",
        ylabel = "power [W]",
        title = "Battery control")
    p3 = Plots.plot(t, soc,
        label = "SOC",
        xlabel = "time [s]",
        ylabel = "fraction",
        title = "AgnosticStorageDynamics SOC")
    p4 = Plots.plot(t, [bus hard_bus],
        label = ["smooth NLP" "hard diagnostic"],
        xlabel = "time [s]",
        ylabel = "W",
        title = "Bus balance residual")
    plt = Plots.plot(p1, p2, p3, p4; layout = (4, 1), size = (760, 860))
    Plots.savefig(plt, figure_path)
    return figure_path
end

function run_three_minute_package_snow(; output_dir = joinpath(@__DIR__, "results"),
        figure_path = joinpath(@__DIR__, "three_minute_package_snow_controls.png"),
        horizon_s = DEFAULT_HORIZON_S,
        dt_s = parse(Float64, get(ENV, "SIRENOPT_THREE_MINUTE_DT_S", string(DEFAULT_DT_S))),
        max_iter = parse(Int, get(ENV, "SIRENOPT_THREE_MINUTE_MAX_ITER", "1000")),
        derivative_mode = get(ENV, "SIRENOPT_THREE_MINUTE_DERIVATIVES", "ad"),
        print_level = parse(Int, get(ENV, "SIRENOPT_THREE_MINUTE_PRINT_LEVEL", "0")))
    result = _solve_three_minute_package_snow(
        horizon_s = horizon_s,
        dt_s = dt_s,
        max_iter = max_iter,
        derivative_mode = derivative_mode,
        print_level = print_level,
    )
    summary, rows = _evaluate_solution(result)

    summary_path = joinpath(output_dir, "three_minute_package_snow_summary.csv")
    timeseries_path = joinpath(output_dir, "three_minute_package_snow_timeseries.csv")
    _write_csv(summary_path, [summary], [
        "case", "scope", "method", "model_evaluation", "solver",
        "solver_status", "derivatives", "solve_seconds", "horizon_s", "dt_s", "steps",
        "fastest_wave_period_s", "samples_per_fastest_wave_period",
        "load_w", "load_energy_wh", "reported_total_cost_usd",
        "objective_cost_per_load_w_usd_per_w", "solar_area_m2",
        "wind_capacity_w", "wave_capture_width_m", "wave_capacity_w",
        "battery_capacity_wh", "battery_power_capacity_w",
        "solar_energy_wh", "wind_energy_wh", "wave_energy_wh",
        "solar_energy_fraction_of_load", "wind_energy_fraction_of_load",
        "wave_energy_fraction_of_load",
        "hard_branch_solar_energy_fraction_of_load",
        "hard_branch_wind_energy_fraction_of_load",
        "hard_branch_wave_energy_fraction_of_load", "battery_throughput_wh",
        "terminal_battery_soc", "terminal_battery_reserve_shortfall_soc",
        "max_abs_bus_balance_residual_kw", "max_abs_bus_balance_residual_w",
        "max_battery_dynamic_residual_soc",
        "max_battery_power_bound_violation_kw",
        "max_abs_snow_constraint_value",
        "max_abs_snow_equality_residual", "min_snow_inequality_margin",
        "max_abs_hard_branch_bus_balance_residual_kw",
        "max_abs_hard_branch_bus_balance_residual_w",
        "max_hard_branch_battery_dynamic_residual_soc",
        "max_hard_branch_battery_power_bound_violation_kw",
        "max_abs_hard_branch_constraint_value",
        "max_abs_hard_branch_equality_residual",
        "min_hard_branch_inequality_margin",
        "min_renewable_energy_fraction_per_source",
        "uses_pvlib", "uses_unsteadykinetic", "uses_generatorse",
        "uses_powerconverterdynamics", "uses_agnosticstoragedynamics",
        "uses_platform_motion", "uses_mooring", "feasible_for_declared_nlp",
        "global_optimality_scope", "hard_branch_diagnostic_note", "resource_note",
    ])
    _write_csv(timeseries_path, rows, [
        "case", "time_s", "dt_s", "load_kw", "solar_power_kw",
        "wind_power_kw", "wave_power_kw", "battery_command_kw",
        "battery_device_power_kw", "battery_bus_power_kw", "load_bus_power_kw",
        "battery_soc", "bus_balance_residual_kw",
        "battery_dynamic_residual_soc", "hard_branch_solar_power_kw",
        "hard_branch_wind_power_kw", "hard_branch_wave_power_kw",
        "hard_branch_battery_device_power_kw", "hard_branch_battery_bus_power_kw",
        "hard_branch_load_bus_power_kw", "hard_branch_bus_balance_residual_kw",
        "hard_branch_battery_dynamic_residual_soc", "wind_speed_m_per_s",
        "wave_flux_kw_per_m",
    ])
    _plot_solution(rows, summary, figure_path)

    return (
        summary = summary,
        rows = rows,
        summary_path = summary_path,
        timeseries_path = timeseries_path,
        figure_path = figure_path,
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_three_minute_package_snow()
    summary = result.summary
    println("three-minute package-backed SNOW case")
    println("  status: ", summary["solver_status"])
    println("  derivatives: ", summary["derivatives"])
    println("  cost per load watt [USD/W]: ",
        round(summary["objective_cost_per_load_w_usd_per_w"], digits = 4))
    println("  solar area [m2]: ", round(summary["solar_area_m2"], digits = 4))
    println("  wind / wave capacity [W]: ",
        round(summary["wind_capacity_w"], digits = 3), " / ",
        round(summary["wave_capacity_w"], digits = 3))
    println("  battery energy / power: ",
        round(summary["battery_capacity_wh"], digits = 4), " Wh / ",
        round(summary["battery_power_capacity_w"], digits = 3), " W")
    println("  max bus residual [W]: ",
        @sprintf("%.3e", summary["max_abs_bus_balance_residual_w"]))
    println("  max hard-branch bus diagnostic [W]: ",
        @sprintf("%.3e", summary["max_abs_hard_branch_bus_balance_residual_w"]))
    println("  summary: ", result.summary_path)
    println("  timeseries: ", result.timeseries_path)
    println("  figure: ", result.figure_path)
end
