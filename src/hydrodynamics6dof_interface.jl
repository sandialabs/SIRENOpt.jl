const HYDRODYNAMICS6DOF_HEAVE_INDEX = 3
const HYDRODYNAMICS6DOF_LABEL = "[surge, sway, heave, roll, pitch, yaw]"

function hydrodynamics_wave_components(; omega = [0.0], phase = [0.0],
        spectrum = [0.0], dω = 1.0, start_time_s = 0.0, ramp_time_s = 0.0)
    return (omega, phase, spectrum, dω, start_time_s, ramp_time_s)
end

Base.@kwdef struct PlatformState6DOF{T<:Real}
    position::Vector{T} = zeros(T, 6)
    velocity::Vector{T} = zeros(T, 6)
    acceleration::Vector{T} = zeros(T, 6)
    velocity_history::Matrix{T} = reshape(zeros(T, 6), 6, 1)
end

Base.@kwdef struct Hydrodynamic6DOFPlatformModel{TI, TK, TB, TE, TF, TW, TP, TM}
    inverse_mass::TI = Matrix{Float64}(I, 6, 6)
    hydrostatic_stiffness::TK = zeros(6, 6)
    radiation_damping::TB = zeros(6, 6)
    excitation_coeff::TE = zeros(6, 1, 1, 2)
    constant_wrench::TF = zeros(6)
    wave::TW = hydrodynamics_wave_components()
    pto::TP = (zeros(6), zeros(6, 6), zeros(6, 6))
    mooring::TM = (zeros(6), zeros(6, 6), zeros(6, 6))
    method::Symbol = :point
end

function _hydro6_real_type(values...)
    types = Type[]
    for value in values
        value === nothing && continue
        if value isa Number
            push!(types, typeof(value))
        elseif value isa AbstractArray
            push!(types, eltype(value))
        elseif value isa Tuple
            push!(types, _hydro6_real_type(value...))
        else
            push!(types, typeof(value))
        end
    end
    return isempty(types) ? Float64 : promote_type(types...)
end

function _hydro6_vec(::Type{T}, value, name::AbstractString) where {T<:Real}
    vector = collect(value)
    length(vector) == 6 ||
        throw(ArgumentError("$name must contain 6 entries in $HYDRODYNAMICS6DOF_LABEL order"))
    return convert.(T, vector)
end

function _hydro6_mat6(::Type{T}, value, name::AbstractString) where {T<:Real}
    matrix = Matrix(value)
    size(matrix) == (6, 6) ||
        throw(ArgumentError("$name must be a 6x6 matrix in $HYDRODYNAMICS6DOF_LABEL order"))
    return convert.(T, matrix)
end

function _hydro6_excitation(::Type{T}, value, name::AbstractString) where {T<:Real}
    coeff = Array(value)
    ndims(coeff) == 4 ||
        throw(ArgumentError("$name must be a 4D array with dimensions dof x heading x frequency x real/imag"))
    size(coeff, 1) == 6 ||
        throw(ArgumentError("$name first dimension must contain 6 DOFs in $HYDRODYNAMICS6DOF_LABEL order"))
    size(coeff, 2) >= 1 ||
        throw(ArgumentError("$name must contain at least one wave heading"))
    size(coeff, 3) >= 1 ||
        throw(ArgumentError("$name must contain at least one wave frequency"))
    size(coeff, 4) == 2 ||
        throw(ArgumentError("$name fourth dimension must contain cosine and sine coefficients"))
    return convert.(T, coeff)
end

function _hydro6_wave_as(::Type{T}, wave) where {T<:Real}
    omega, phase, spectrum, dω, start_time_s, ramp_time_s = wave
    omega_v = convert.(T, collect(omega))
    phase_v = convert.(T, collect(phase))
    spectrum_v = convert.(T, collect(spectrum))
    length(omega_v) == length(phase_v) == length(spectrum_v) ||
        throw(ArgumentError("wave omega, phase, and spectrum must have the same length"))
    frequency_step = dω isa AbstractArray ? convert.(T, collect(dω)) : convert(T, dω)
    return (omega_v, phase_v, spectrum_v, frequency_step,
        convert(T, start_time_s), convert(T, ramp_time_s))
end

function _hydro6_linear_tuple(::Type{T}, reference_position, stiffness, damping,
        name::AbstractString) where {T<:Real}
    return (
        _hydro6_vec(T, reference_position, "$(name)_reference_position"),
        _hydro6_mat6(T, stiffness, "$(name)_stiffness"),
        _hydro6_mat6(T, damping, "$(name)_damping"),
    )
end

function hydrodynamics6dof_platform_model(; inverse_mass = nothing, mass_matrix = nothing,
        hydrostatic_stiffness = zeros(6, 6), radiation_damping = zeros(6, 6),
        excitation_coeff = zeros(6, 1, 1, 2), constant_wrench = zeros(6),
        wave = hydrodynamics_wave_components(),
        pto_reference_position = zeros(6), pto_stiffness = zeros(6, 6),
        pto_damping = zeros(6, 6), mooring_reference_position = zeros(6),
        mooring_stiffness = zeros(6, 6), mooring_damping = zeros(6, 6),
        method::Symbol = :point)

    T = _hydro6_real_type(inverse_mass, mass_matrix, hydrostatic_stiffness,
        radiation_damping, excitation_coeff, constant_wrench, wave,
        pto_reference_position, pto_stiffness, pto_damping,
        mooring_reference_position, mooring_stiffness, mooring_damping)
    inv_mass = inverse_mass === nothing ?
        (mass_matrix === nothing ? Matrix{T}(I, 6, 6) : inv(_hydro6_mat6(T, mass_matrix, "mass_matrix"))) :
        _hydro6_mat6(T, inverse_mass, "inverse_mass")
    excitation = _hydro6_excitation(T, excitation_coeff, "excitation_coeff")
    wave_tuple = _hydro6_wave_as(T, wave)
    length(wave_tuple[1]) == size(excitation, 3) ||
        throw(ArgumentError("wave frequency count must match excitation_coeff frequency dimension"))

    return Hydrodynamic6DOFPlatformModel(
        inverse_mass = inv_mass,
        hydrostatic_stiffness = _hydro6_mat6(T, hydrostatic_stiffness, "hydrostatic_stiffness"),
        radiation_damping = _hydro6_mat6(T, radiation_damping, "radiation_damping"),
        excitation_coeff = excitation,
        constant_wrench = _hydro6_vec(T, constant_wrench, "constant_wrench"),
        wave = wave_tuple,
        pto = _hydro6_linear_tuple(T, pto_reference_position, pto_stiffness, pto_damping, "pto"),
        mooring = _hydro6_linear_tuple(T, mooring_reference_position, mooring_stiffness, mooring_damping, "mooring"),
        method = method,
    )
end

_is_hydrodynamics6dof_model(model) = model isa Hydrodynamic6DOFPlatformModel

function _initial_platform_state(design::PlatformDesign, ::Type{T}) where {T<:Real}
    return _is_hydrodynamics6dof_model(design.hydrodynamic_model) ? PlatformState6DOF{T}() :
        PlatformState{T}()
end

function _platform_state_as(::Type{T}, state::PlatformState6DOF) where {T<:Real}
    return PlatformState6DOF{T}(
        _hydro6_vec(T, state.position, "position"),
        _hydro6_vec(T, state.velocity, "velocity"),
        _hydro6_vec(T, state.acceleration, "acceleration"),
        _hydro6_mat6n(T, state.velocity_history, "velocity_history"),
    )
end

_platform_state_real_type(state::PlatformState) = typeof(state.position)
_platform_state_real_type(state::PlatformState6DOF) = eltype(state.position)

function _hydro6_mat6n(::Type{T}, value, name::AbstractString) where {T<:Real}
    matrix = Matrix(value)
    size(matrix, 1) == 6 ||
        throw(ArgumentError("$name must have 6 rows in $HYDRODYNAMICS6DOF_LABEL order"))
    size(matrix, 2) >= 1 || throw(ArgumentError("$name must contain at least one history column"))
    return convert.(T, matrix)
end

function platform_state6dof(; position = zeros(6), velocity = zeros(6),
        acceleration = zeros(6), velocity_history = nothing)
    T = _hydro6_real_type(position, velocity, acceleration, velocity_history)
    pos = _hydro6_vec(T, position, "position")
    vel = _hydro6_vec(T, velocity, "velocity")
    acc = _hydro6_vec(T, acceleration, "acceleration")
    history = velocity_history === nothing ? reshape(copy(vel), 6, 1) :
        _hydro6_mat6n(T, velocity_history, "velocity_history")
    return PlatformState6DOF{T}(pos, vel, acc, history)
end

function _heave_wrench(force)
    T = typeof(force)
    wrench = zeros(T, 6)
    wrench[HYDRODYNAMICS6DOF_HEAVE_INDEX] = force
    return wrench
end

function _hydro6_wrench(value, name::AbstractString = "external_wrench")
    value isa Number && return _heave_wrench(value)
    T = _hydro6_real_type(value)
    return _hydro6_vec(T, value, name)
end

function _wrench_value_at(wrench, k::Int)
    wrench isa TimeSeries && return value_at(wrench, k)
    return wrench
end

function _hydro6_parameter_tuple(model::Hydrodynamic6DOFPlatformModel, external_wrench, wave)
    method = model.method
    method == :point ||
        throw(ArgumentError("SIRENOpt stepwise Hydrodynamics 6DOF integration currently supports method = :point"))
    wrench = _hydro6_wrench(external_wrench)
    T = promote_type(eltype(model.inverse_mass), eltype(wrench))
    wave_tuple = wave === nothing ? model.wave : _hydro6_wave_as(T, wave)
    total_constant_wrench = convert.(T, model.constant_wrench) + convert.(T, wrench)
    hydro = (
        convert.(T, model.hydrostatic_stiffness),
        convert.(T, model.radiation_damping),
        convert.(T, model.excitation_coeff),
        total_constant_wrench,
        wave_tuple,
    )
    pto = (
        convert.(T, model.pto[1]),
        convert.(T, model.pto[2]),
        convert.(T, model.pto[3]),
    )
    mooring = (
        convert.(T, model.mooring[1]),
        convert.(T, model.mooring[2]),
        convert.(T, model.mooring[3]),
    )
    force_other = (_hydrodynamics_linear_force, nothing, (pto, mooring))
    return (convert.(T, model.inverse_mass), hydro, force_other, force_other)
end

function _hydro6_state_vector(state::PlatformState6DOF)
    return [state.position; state.velocity]
end

function _platform_state6dof_from_solution(model::Hydrodynamic6DOFPlatformModel,
        state::PlatformState6DOF, solution, p, time_s, dt)
    u = solution.u[end]
    position = collect(u[1:6])
    velocity = collect(u[7:12])
    du = Hydrodynamics.hydrodynamic_oscillator(u, p, time_s + dt)
    acceleration = collect(du[7:12])
    velocity_history = hcat(state.velocity_history, velocity)
    return platform_state6dof(
        position = position,
        velocity = velocity,
        acceleration = acceleration,
        velocity_history = velocity_history,
    )
end
