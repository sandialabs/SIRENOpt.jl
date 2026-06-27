Base.@kwdef struct HydrodynamicPlatformModel{TK, TC, TM, TE, TF, TW}
    stiffness_n_per_m::TK = 0.0
    damping_n_s_per_m::TC = 0.0
    mass_kg::TM = 1.0
    excitation_coeff::TE = zeros(1, 1, 1, 2)
    constant_forces_n::TF = [0.0]
    wave::TW = ([0.0], [0.0], [0.0], 0.0, 0.0, 0.0)
end

function hydrodynamic_platform_model(; stiffness_n_per_m = 0.0,
        damping_n_s_per_m = 0.0,
        mass_kg = 1.0,
        excitation_coeff = zeros(1, 1, 1, 2),
        constant_forces_n = [0.0],
        wave = ([0.0], [0.0], [0.0], 0.0, 0.0, 0.0))
    return HydrodynamicPlatformModel(
        stiffness_n_per_m = stiffness_n_per_m,
        damping_n_s_per_m = damping_n_s_per_m,
        mass_kg = mass_kg,
        excitation_coeff = excitation_coeff,
        constant_forces_n = constant_forces_n,
        wave = wave,
    )
end

function _hydrodynamics_zero_force(_time, state, _input; p = nothing)
    n_dof = length(state) ÷ 2
    return zeros(eltype(state), n_dof)
end

function _hydrodynamics_linear_force(_time, state, _input; p)
    n_dof = length(state) ÷ 2
    position = @view state[1:n_dof]
    velocity = @view state[(n_dof + 1):end]
    force = zeros(eltype(state), n_dof)
    for coefficients in p
        coefficients === nothing && continue
        reference_position, stiffness, damping = coefficients
        force .+= -damping * velocity .- stiffness * (position .- reference_position)
    end
    return force
end

function _hydrodynamic_parameter_tuple(model::HydrodynamicPlatformModel, scalar_type::Type)
    k = reshape([convert(scalar_type, model.stiffness_n_per_m)], 1, 1)
    b = reshape([convert(scalar_type, model.damping_n_s_per_m)], 1, 1)
    inverse_mass = reshape([inv(convert(scalar_type, model.mass_kg))], 1, 1)
    excitation = convert.(scalar_type, model.excitation_coeff)
    force = convert.(scalar_type, model.constant_forces_n)
    wave = _hydro6_wave_as(scalar_type, model.wave)
    hydro = (k, b, excitation, force, wave)
    force_other = (_hydrodynamics_zero_force, nothing, nothing)
    return (inverse_mass, hydro, force_other, force_other)
end

function hydrodynamic_platform_acceleration(model::HydrodynamicPlatformModel,
        position, velocity, time_s)
    T = promote_type(typeof(position), typeof(velocity), typeof(time_s))
    p = _hydrodynamic_parameter_tuple(model, T)
    derivative = Hydrodynamics.hydrodynamic_oscillator([position, velocity], p, time_s)
    return derivative[2]
end

function hydrodynamic_dynamics_step(model::HydrodynamicPlatformModel,
        state::PlatformState, dt_s; time_s = zero(dt_s), external_acceleration = zero(dt_s))
    accel = hydrodynamic_platform_acceleration(model, state.position, state.velocity, time_s) + external_acceleration
    velocity = state.velocity + accel * dt_s
    position = state.position + velocity * dt_s
    return PlatformState(position, velocity, accel)
end
