const _W_PER_KW = 1000.0

Base.@kwdef struct GeneratorSEModel{T<:Real}
    rated_power_kw::T
    efficiency::T
    mass_kg::T
    phase_resistance_ohm::T
    synchronous_inductance_h::T
    pole_pairs::T
    phase_voltage_rms::T
    frequency_hz::T
    outputs::Any = nothing
    dynamics_params::Any = nothing
end

"""Build a GeneratorSE-backed PMSG model while keeping SIRENOpt boundary units in kW."""
function generatorse_pmsg_arms_model(;
    rated_power_kw::Real = 5000.0,
    shaft_rpm::Real = 12.1,
    rad_ag::Real = 3.26,
    len_s::Real = 1.60,
    h_s::Real = 0.070,
    tau_p::Real = 0.080,
    h_m::Real = 0.009,
    h_ys::Real = 0.075,
    h_yr::Real = 0.075,
    b_st::Real = 0.480,
    d_s::Real = 0.350,
    t_ws::Real = 0.06,
    n_r::Real = 5.0,
    n_s::Real = 5.0,
    b_r::Real = 0.530,
    d_r::Real = 0.700,
    t_wr::Real = 0.06,
    D_shaft::Real = 0.86,
    rho_Fe::Real = 7700.0,
    rho_Copper::Real = 8900.0,
    rho_Fes::Real = 7850.0,
    rho_PM::Real = 7450.0,
    continuous::Bool = true,
)
    machine_rating_w = rated_power_kw * _W_PER_KW
    omega = 2 * pi * shaft_rpm / 60
    torque = machine_rating_w / smooth_max(omega, oftype(omega, 1.0e-9))

    outputs = GeneratorSE.PMSG_arms(
        rad_ag,
        len_s,
        h_s,
        tau_p,
        h_m,
        h_ys,
        h_yr,
        machine_rating_w,
        shaft_rpm,
        torque,
        b_st,
        d_s,
        t_ws,
        n_r,
        n_s,
        b_r,
        d_r,
        t_wr,
        D_shaft,
        rho_Fe,
        rho_Copper,
        rho_Fes,
        rho_PM;
        continuous,
    )
    dyn = GeneratorSE.PMSG_dynamics_params(outputs)

    T = promote_type(typeof(rated_power_kw), typeof(outputs[22]), typeof(outputs[45]))
    return GeneratorSEModel{T}(
        rated_power_kw = convert(T, rated_power_kw),
        efficiency = convert(T, outputs[22]),
        mass_kg = convert(T, outputs[45]),
        phase_resistance_ohm = convert(T, outputs[16]),
        synchronous_inductance_h = convert(T, outputs[17]),
        pole_pairs = convert(T, outputs[12]),
        phase_voltage_rms = convert(T, outputs[13]),
        frequency_hz = convert(T, outputs[14]),
        outputs = outputs,
        dynamics_params = dyn,
    )
end

function generatorse_output_kw(model::GeneratorSEModel, mechanical_power_kw)
    p_in = smooth_max(mechanical_power_kw, zero(mechanical_power_kw))
    eta = smooth_clamp(model.efficiency + zero(p_in), zero(p_in), one(p_in))
    return smooth_min(p_in * eta, model.rated_power_kw + zero(p_in))
end

struct PowerConverterModel{P,S,T<:Real}
    params::P
    state::S
    source_voltage::T
end

"""Build a PowerConverterDynamics-backed converter model with SI internals."""
function powerconverter_model(;
    rated_power_kw::Real = 50.0,
    reference_bus_voltage::Real = 800.0,
    source_voltage::Real = reference_bus_voltage,
    efficiency_floor::Real = 0.70,
    efficiency_ceiling::Real = 0.99,
)
    rated_power_w = rated_power_kw * _W_PER_KW
    current_limit = rated_power_w / smooth_max(source_voltage, oftype(source_voltage, 1.0e-9))
    params = PowerConverterDynamics.ConverterParams(
        reference_bus_voltage = reference_bus_voltage,
        source_current_limit = current_limit,
        source_power_limit = rated_power_w,
        converter_min_efficiency = efficiency_floor,
        converter_max_efficiency = efficiency_ceiling,
    )
    state = PowerConverterDynamics.SystemState(
        bus_voltage = reference_bus_voltage,
        soc = 0.5,
        controller_integrator = 0.0,
    )
    T = promote_type(typeof(rated_power_kw), typeof(reference_bus_voltage), typeof(source_voltage))
    return PowerConverterModel(params, state, convert(T, source_voltage))
end

function powerconverter_efficiency(model::PowerConverterModel, device_power_kw)
    v_src = model.source_voltage + zero(device_power_kw)
    v_bus = model.state.bus_voltage + zero(device_power_kw)
    p_abs_w = smooth_abs(device_power_kw; delta = oftype(device_power_kw, 1.0e-9)) * _W_PER_KW
    i_abs = p_abs_w / smooth_max(v_src, oftype(v_src, 1.0e-9))
    return PowerConverterDynamics.converter_efficiency(v_src, i_abs, v_bus, model.params)
end

function powerconverter_output_kw(model::PowerConverterModel, device_power_kw)
    eta = powerconverter_efficiency(model, device_power_kw)
    p_supply = smooth_max(device_power_kw, zero(device_power_kw))
    p_load = smooth_min(device_power_kw, zero(device_power_kw))
    return p_supply * eta + p_load / eta
end
