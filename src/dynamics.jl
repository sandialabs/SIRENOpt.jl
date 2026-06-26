"""External force at index k (N)."""
function platform_force(design::PlatformDesign, op::PlatformOp, k::Int)
    return value_at(op.external_force, k)
end

"""External platform load at index k.

For scalar platform models this returns the scalar heave force. For
Hydrodynamics 6DOF models it returns a 6-entry wrench in
`[Fx, Fy, Fz, Mx, My, Mz]` order. A legacy scalar `external_force` is mapped to
the heave wrench component.
"""
function platform_wrench(design::PlatformDesign, op::PlatformOp, k::Int)
    if _is_hydrodynamics6dof_model(design.hydrodynamic_model)
        if op.external_wrench !== nothing
            return _hydro6_wrench(_wrench_value_at(op.external_wrench, k))
        end
        return _heave_wrench(platform_force(design, op, k))
    elseif op.external_wrench !== nothing
        throw(ArgumentError("external_wrench requires a Hydrodynamics 6DOF hydrodynamic model"))
    end
    return platform_force(design, op, k)
end

"""Mass estimate for platform based on design payloads."""
platform_mass(design::PlatformDesign) = design.base_mass + design.payload_mass + design.mass_margin + mooring_mass_kg(design.mooring_model)

"""Residual of F = m * a (scalar placeholder)."""
function force_residual(design::PlatformDesign, state::PlatformState, force)
    m = platform_mass(design)
    mooring_force = mooring_restoring_force(design.mooring_model, state.position, state.velocity)
    return m * state.acceleration - force - mooring_force + design.damping * state.velocity
end

"""Advance platform dynamics one step. If method is :implicit, a solver can be injected.

Injected solvers receive the external force; use `force_residual` inside the
solver when mooring restoring and platform damping terms should be included.
"""
function dynamics_step(design::PlatformDesign, state::PlatformState, force, dt;
    method::Symbol = :explicit, solve_residual = nothing, time_s = zero(dt),
    wave = nothing, direction_mode::Symbol = :exact,
    validate_coefficients::Bool = false,
    max_relative_coefficient_change = Inf,
    coefficient_diagnostic_callback = nothing,
    throw_on_coefficient_diagnostic::Bool = validate_coefficients)

    if _is_hydrodynamics6dof_model(design.hydrodynamic_model)
        throw(ArgumentError("Hydrodynamics 6DOF models require PlatformState6DOF"))
    elseif design.hydrodynamic_model !== nothing
        mooring_force = mooring_restoring_force(design.mooring_model, state.position, state.velocity)
        total_force = force + mooring_force
        external_acceleration = total_force / platform_mass(design)
        return hydrodynamic_dynamics_step(
            design.hydrodynamic_model,
            state,
            dt;
            time_s = time_s,
            external_acceleration = external_acceleration,
        )
    elseif method == :implicit && solve_residual !== nothing
        accel = solve_residual(state, design, force, dt)
    else
        mooring_force = mooring_restoring_force(design.mooring_model, state.position, state.velocity)
        total_force = force + mooring_force
        m = platform_mass(design)
        accel = (total_force - design.damping * state.velocity) / m
    end
    velocity = state.velocity + accel * dt
    position = state.position + velocity * dt
    return PlatformState(position, velocity, accel)
end

"""Advance a Hydrodynamics 6DOF platform state one time step."""
function dynamics_step(design::PlatformDesign, state::PlatformState6DOF, wrench, dt;
    method::Symbol = :explicit, solve_residual = nothing, time_s = zero(dt),
    wave = nothing, direction_mode::Symbol = :exact,
    validate_coefficients::Bool = false,
    max_relative_coefficient_change = Inf,
    coefficient_diagnostic_callback = nothing,
    throw_on_coefficient_diagnostic::Bool = validate_coefficients)

    model = design.hydrodynamic_model
    _is_hydrodynamics6dof_model(model) ||
        throw(ArgumentError("PlatformState6DOF requires a Hydrodynamics 6DOF hydrodynamic model"))

    if validate_coefficients || coefficient_diagnostic_callback !== nothing ||
            throw_on_coefficient_diagnostic
        throw(ArgumentError("Hydrodynamics 6DOF adapter does not provide coefficient diagnostics"))
    end

    p = _hydro6_parameter_tuple(model, wrench, wave)
    solution = Hydrodynamics.hydrodynamic_solver(
        _hydro6_state_vector(state),
        [time_s, time_s + dt],
        p;
        method = model.method,
    )
    return _platform_state6dof_from_solution(model, state, solution, p, time_s, dt)
end
