using SIRENOpt

function build_balanced_electric_bus_demo(; T::Type{<:Real} = Float64)
    t = T[0, 1, 2, 3]
    load_kw = T[10, 12, 8, 9]
    dt_hours = one(T)

    design = SystemDesign{T}(
        solar = SolarDesign{T}(area = zero(T)),
        wind = WindDesign{T}(rated_power = zero(T)),
        wave = WaveDesign{T}(capture_width = zero(T), rated_power = zero(T)),
        hydrokinetic = HydrokineticDesign{T}(rated_power = zero(T)),
        diesel = DieselDesign{T}(
            rated_power = T(25),
            min_power = zero(T),
            efficiency = one(T),
            fuel_tank_capacity = T(20),
        ),
        diesel_gen = GeneratorDesign{T}(rated_power = T(25), efficiency = one(T)),
        diesel_conv = ConverterDesign{T}(rated_power = T(25), efficiency = one(T)),
        battery = BatteryDesign{T}(
            capacity_kwh = T(10),
            max_charge_kw = zero(T),
            max_discharge_kw = zero(T),
            charge_efficiency = one(T),
            discharge_efficiency = one(T),
        ),
        battery_conv = ConverterDesign{T}(rated_power = T(25), efficiency = one(T), bi_directional = true),
        h2 = H2Design{T}(electrolyzer_power_kw = zero(T)),
        h2_conv = ConverterDesign{T}(rated_power = T(25), efficiency = one(T)),
        desal = DesalDesign{T}(plant_power_kw = zero(T)),
        desal_conv = ConverterDesign{T}(rated_power = T(25), efficiency = one(T)),
        load = LoadDesign{T}(critical_fraction = one(T)),
        load_conv = ConverterDesign{T}(rated_power = T(25), efficiency = one(T)),
        bus = BusDesign{T}(
            voltage_nominal = one(T),
            voltage_min = T(0.9),
            voltage_max = T(1.1),
            droop_gain = T(0.01),
        ),
    )

    operation = SystemOperation{T}(
        solar = SolarOp{T}(resource = TimeSeries(t, zeros(T, length(t)))),
        wind = WindOp{T}(resource = TimeSeries(t, zeros(T, length(t)))),
        wave = WaveOp{T}(resource = TimeSeries(t, zeros(T, length(t)))),
        hydrokinetic = HydrokineticOp{T}(resource = TimeSeries(t, zeros(T, length(t)))),
        diesel = DieselOp{T}(fuel_level = T(20)),
        battery = BatteryOp{T}(soc_init = T(0.5)),
        h2 = H2Op{T}(tank_level_kg = zero(T), demand = TimeSeries(t, zeros(T, length(t)))),
        desal = DesalOp{T}(tank_level_m3 = zero(T), demand = TimeSeries(t, zeros(T, length(t)))),
        load = LoadOp{T}(demand = TimeSeries(t, load_kw)),
    )

    return (design = design, operation = operation, dt_hours = dt_hours,
        control = balanced_electric_bus_dispatch)
end

function _balanced_bus_setpoints(diesel_setpoint_kw)
    Tcmd = typeof(diesel_setpoint_kw)
    return ControlSetpoints{Tcmd}(
        solar_curtailment = one(Tcmd),
        wind_curtailment = one(Tcmd),
        wave_curtailment = one(Tcmd),
        hydrokinetic_curtailment = one(Tcmd),
        load_served_fraction = one(Tcmd),
        diesel_power_kw = diesel_setpoint_kw,
        battery_power_kw = zero(Tcmd),
        h2_power_kw = zero(Tcmd),
        desal_power_kw = zero(Tcmd),
    )
end

function _net_bus_residual_for_diesel(design, op, state, k::Int, dt_hours, diesel_power_kw)
    _, output = plant_step(design, op, state, _balanced_bus_setpoints(diesel_power_kw), k, dt_hours)
    return output.bus_balance_residual_kw
end

function balanced_electric_bus_dispatch(design, op, state, k::Int, dt_hours)
    lo = zero(load_demand(design.load, op.load, k))
    hi = design.diesel.rated_power + lo
    f_lo = _net_bus_residual_for_diesel(design, op, state, k, dt_hours, lo)
    f_hi = _net_bus_residual_for_diesel(design, op, state, k, dt_hours, hi)

    f_lo >= zero(f_lo) && return _balanced_bus_setpoints(lo)
    f_hi <= zero(f_hi) && return _balanced_bus_setpoints(hi)

    mid = (lo + hi) / 2
    for _ in 1:80
        mid = (lo + hi) / 2
        f_mid = _net_bus_residual_for_diesel(design, op, state, k, dt_hours, mid)
        if f_mid >= zero(f_mid)
            hi = mid
        else
            lo = mid
        end
    end
    return _balanced_bus_setpoints(mid)
end

function run_balanced_electric_bus_demo(; kwargs...)
    case = build_balanced_electric_bus_demo(; kwargs...)
    states, outputs = simulate(case.design, case.operation, case.dt_hours; control = case.control)
    return (case..., states = states, outputs = outputs)
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_balanced_electric_bus_demo()
    max_bus_residual = maximum(abs(output.bus_balance_residual_kw) for output in result.outputs)
    println("balanced_electric_bus_demo steps: ", length(result.outputs))
    println("max_abs_bus_balance_residual_kw: ", max_bus_residual)
end
