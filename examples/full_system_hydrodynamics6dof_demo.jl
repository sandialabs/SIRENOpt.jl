using LinearAlgebra
using SIRENOpt
import PVlib

function full_system_hydrodynamics6dof_wave(; T::Type{<:Real} = Float64)
    return hydrodynamics_wave_components(
        omega = T.([0.5, 0.8, 1.1]),
        phase = T.([0.0, pi / 3, 2pi / 3]),
        spectrum = T.([0.35, 0.20, 0.12]),
        dω = T(0.2),
        start_time_s = zero(T),
        ramp_time_s = zero(T),
    )
end

function full_system_hydrodynamics6dof_model(; T::Type{<:Real} = Float64)
    mass_matrix = Diagonal(T.([55_000, 55_000, 67_000, 1.9e6, 2.2e6, 2.5e6]))

    hydrostatic = zeros(T, 6, 6)
    hydrostatic[3, 3] = T(90_000)
    hydrostatic[4, 4] = T(2.0e6)
    hydrostatic[5, 5] = T(2.2e6)

    radiation_damping = Diagonal(T.([900, 1_000, 2_500, 1.0e4, 1.2e4, 1.4e4]))

    excitation = zeros(T, 6, 1, 3, 2)
    excitation[1, 1, :, 1] .= T.([800, 1_000, 900])
    excitation[3, 1, :, 1] .= T.([4_500, 5_500, 4_000])
    excitation[5, 1, :, 1] .= T.([1.0e5, 1.2e5, 9.0e4])

    return hydrodynamics6dof_platform_model(
        mass_matrix = mass_matrix,
        hydrostatic_stiffness = hydrostatic,
        radiation_damping = radiation_damping,
        excitation_coeff = excitation,
        wave = full_system_hydrodynamics6dof_wave(T = T),
        pto_damping = Diagonal(T.([400, 400, 1_200, 6.0e4, 6.0e4, 2.0e4])),
    )
end

function full_system_hydrodynamics6dof_dispatch(_design, _op, _state, _k, dt_hours)
    T = typeof(dt_hours)
    return ControlSetpoints{T}(
        solar_curtailment = zero(T),
        wind_curtailment = zero(T),
        wave_curtailment = zero(T),
        hydrokinetic_curtailment = zero(T),
        load_served_fraction = one(T),
        diesel_power_kw = T(6.0),
        battery_power_kw = -T(2.0),
        h2_power_kw = T(1.5),
        desal_power_kw = T(1.0),
    )
end

function _full_system_demo_profile(values, n_steps::Int, ::Type{T}) where {T<:Real}
    return [T(values[mod1(i, length(values))]) for i in 1:n_steps]
end

function build_full_system_hydrodynamics6dof_demo(; T::Type{<:Real} = Float64,
        n_steps::Int = 8, dt_s::Real = 0.1)
    times_s = [T(i * dt_s) for i in 0:(n_steps - 1)]
    times_h = times_s ./ T(3600)

    platform_model = full_system_hydrodynamics6dof_model(T = T)

    generator_model = generatorse_pmsg_arms_model(rated_power_kw = 5_000.0)
    converter_model = powerconverter_model(rated_power_kw = 100.0)
    storage_template = SIRENOpt.AgnosticStorageDynamics.StorageParams(
        energy_capacity = 1.0,
        charge_rate_max = 1.0,
        discharge_rate_max = 1.0,
        standing_loss_rate = 0.0,
    )
    h2_template = SIRENOpt.H2Gen.DesignStruct(
        capacity_mw = 0.01,
        efficiency = 0.65,
        min_load = 0.0,
        max_load = 1.0,
    )
    desal_template = SIRENOpt.Desal.DesignStruct(
        capacity_m3_per_h = 1.0,
        specific_energy_nominal_kwh_per_m3 = 4.0,
        min_load = 0.0,
        response_time_hours = 0.0,
        part_load_penalty = 0.0,
        recovery_part_load_sensitivity = 0.0,
    )

    weather = PVlib.WeatherSample{T}(
        time = PVlib.ZonedDateTime(2020, 6, 1, 12, 0, 0, PVlib.TimeZone("America/Denver")),
        ghi = T(800),
        dni = T(900),
        dhi = T(100),
        temp_air = T(20),
        temp_dew = T(10),
        relative_humidity = T(50),
        pressure = T(101_325),
        wind_speed = T(1.5),
        wind_direction = T(180),
        albedo = T(0.10),
    )
    solar_position = PVlib.get_solar_position(35.1, -106.6, 1500.0, weather)
    pv_model = pvlib_solar_model(
        surface_tilt_deg = 35.1,
        surface_azimuth_deg = 180.0,
        altitude_m = 1500.0,
    )

    source_generator = GeneratorDesign{T}(
        rated_power = T(50),
        efficiency = T(0.96),
        generator_model = generator_model,
    )
    source_converter = ConverterDesign{T}(
        rated_power = T(50),
        efficiency = T(0.97),
        converter_model = converter_model,
    )

    design = SystemDesign{T}(
        solar = SolarDesign{T}(area = T(120), efficiency = one(T), pv_model = pv_model),
        wind = WindDesign{T}(rotor_diameter = T(12), rated_power = T(35), cp = T(0.42)),
        wave = WaveDesign{T}(capture_width = T(12), rated_power = T(25)),
        hydrokinetic = HydrokineticDesign{T}(rotor_diameter = T(2.4), rated_power = T(12), cp = T(0.38)),
        diesel = DieselDesign{T}(rated_power = T(30), min_power = zero(T)),
        solar_gen = source_generator,
        wind_gen = source_generator,
        wave_gen = source_generator,
        hydrokinetic_gen = source_generator,
        diesel_gen = source_generator,
        solar_conv = source_converter,
        wind_conv = source_converter,
        wave_conv = source_converter,
        hydrokinetic_conv = source_converter,
        diesel_conv = source_converter,
        battery = BatteryDesign{T}(
            capacity_kwh = T(20),
            max_charge_kw = T(8),
            max_discharge_kw = T(8),
            storage_model = storage_template,
        ),
        battery_conv = ConverterDesign{T}(
            rated_power = T(10),
            efficiency = T(0.96),
            bi_directional = true,
            converter_model = converter_model,
        ),
        h2 = H2Design{T}(
            electrolyzer_power_kw = T(5),
            tank_capacity_kg = T(8),
            specific_energy_kwh_per_kg = T(55),
            h2_model = h2_template,
        ),
        h2_conv = ConverterDesign{T}(rated_power = T(5), efficiency = T(0.95), converter_model = converter_model),
        desal = DesalDesign{T}(
            plant_power_kw = T(4),
            tank_capacity_m3 = T(6),
            specific_energy_kwh_per_m3 = T(4),
            desal_model = desal_template,
        ),
        desal_conv = ConverterDesign{T}(rated_power = T(4), efficiency = T(0.95), converter_model = converter_model),
        load = LoadDesign{T}(critical_fraction = T(0.8)),
        load_conv = ConverterDesign{T}(rated_power = T(60), efficiency = T(0.98), converter_model = converter_model),
        bus = BusDesign{T}(voltage_nominal = one(T), voltage_min = T(0.92), voltage_max = T(1.08), droop_gain = T(0.001)),
        platform = PlatformDesign{T}(base_mass = T(55_000), hydrodynamic_model = platform_model),
    )

    platform_wrenches = [
        T[150 + 10i, 0, 300 + 20i, 0, 2_000 + 100i, 0] for i in 0:(n_steps - 1)
    ]
    op = SystemOperation{T}(
        solar = SolarOp{T}(
            resource = TimeSeries(times_h, zeros(T, n_steps)),
            pv_weather = fill(weather, n_steps),
            pv_solar_position = fill(solar_position, n_steps),
        ),
        wind = WindOp{T}(resource = TimeSeries(times_h,
            _full_system_demo_profile([9.0, 9.5, 10.0, 9.0, 8.5, 9.2, 9.8, 9.4], n_steps, T)),
            air_density = T(1.225)),
        wave = WaveOp{T}(resource = TimeSeries(times_h,
            _full_system_demo_profile([1.4, 1.6, 1.5, 1.7, 1.6, 1.5, 1.4, 1.6], n_steps, T))),
        hydrokinetic = HydrokineticOp{T}(resource = TimeSeries(times_h,
            _full_system_demo_profile([1.5, 1.6, 1.55, 1.5, 1.45, 1.55, 1.6, 1.5], n_steps, T)),
            fluid_density = T(1025)),
        load = LoadOp{T}(demand = TimeSeries(times_h,
            _full_system_demo_profile([28, 30, 29, 31, 30, 29, 28, 30], n_steps, T))),
        h2 = H2Op{T}(tank_level_kg = T(0.5), demand = TimeSeries(times_h, fill(T(0.02), n_steps))),
        desal = DesalOp{T}(tank_level_m3 = T(0.5), demand = TimeSeries(times_h, fill(T(0.05), n_steps))),
        battery = BatteryOp{T}(soc_init = T(0.5)),
        platform = PlatformOp{T}(
            external_wrench = TimeSeries(times_h, platform_wrenches),
            wave_components = full_system_hydrodynamics6dof_wave(T = T),
        ),
    )

    return (
        design = design,
        operation = op,
        dt_hours = T(dt_s) / T(3600),
        control = full_system_hydrodynamics6dof_dispatch,
    )
end

function run_full_system_hydrodynamics6dof_demo(; kwargs...)
    case = build_full_system_hydrodynamics6dof_demo(; kwargs...)
    states, outputs = simulate(case.design, case.operation, case.dt_hours; control = case.control)
    return (
        design = case.design,
        operation = case.operation,
        dt_hours = case.dt_hours,
        states = states,
        outputs = outputs,
        aggregate = aggregate_mass_cost_volume(case.design),
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_full_system_hydrodynamics6dof_demo()
    final = result.states[end]
    total_fuel = sum(output -> output.diesel_fuel_used, result.outputs)
    println("full-system Hydrodynamics 6DOF demo")
    println("  steps: $(length(result.outputs)), dt: $(result.dt_hours * 3600) s")
    println("  final heave: $(round(final.platform.position[3], digits = 5)) m")
    println("  final battery SOC: $(round(final.battery_soc, digits = 4))")
    println("  diesel fuel used: $(round(total_fuel, digits = 5)) L")
end
