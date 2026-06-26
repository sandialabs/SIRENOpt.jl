"""
    CCBladeRotorModel

Thin adapter model for using UnsteadyKineticRotorDynamics inside SIRENOpt source components.
SIRENOpt keeps its public power units in kW; the rotor backend uses SI internally.
"""
Base.@kwdef struct CCBladeRotorModel{TR,TS,TV<:AbstractVector,TP,T<:Real}
    rotor::TR
    sections::TS
    radii::TV
    params::TP
    omega_rad_s::T
    pitch_rad::T = zero(T)
    precone_rad::T = zero(T)
    yaw_rad::T = zero(T)
    tilt_rad::T = zero(T)
    azimuth_rad::T = zero(T)
    hub_height::T
    shear_exp::T = zero(T)
    arm_sign::T = one(T)
    dynamic_viscosity::T = T(1.81e-5)
    sound_speed::T = T(343.0)
    dt_s::T = T(0.1)
end

"""
    simple_ccblade_rotor_model(; kwargs...) -> CCBladeRotorModel

Create a compact blade-element rotor suitable for SIRENOpt integration tests and
placeholder replacement studies. Set `fluid=:water` to use marine hydrokinetic
orientation and default water properties.
"""
function simple_ccblade_rotor_model(;
    rotor_radius,
    hub_radius = 0.1 * rotor_radius,
    blades::Integer = 3,
    n_sections::Integer = 5,
    chord_fraction = 0.08,
    theta_rad = 0.0,
    lift_slope = 6.2,
    drag_coefficient = 0.01,
    omega_rad_s = 20.0,
    pitch_rad = 0.0,
    precone_rad = 0.0,
    yaw_rad = 0.0,
    tilt_rad = 0.0,
    azimuth_rad = 0.0,
    hub_height = rotor_radius,
    shear_exp = 0.0,
    tau_near = 0.3,
    tau_far = 3.0,
    dt_s = 0.1,
    fluid::Symbol = :air,
    turbine::Bool = true,
)
    components = UnsteadyKineticRotorDynamics.simple_blade_element_rotor(
        rotor_radius = rotor_radius,
        hub_radius = hub_radius,
        blades = blades,
        n_sections = n_sections,
        chord_fraction = chord_fraction,
        theta_rad = theta_rad,
        lift_slope = lift_slope,
        drag_coefficient = drag_coefficient,
        precone_rad = precone_rad,
        turbine = turbine,
    )
    params = UnsteadyKineticRotorDynamics.UnsteadyParams(tau_near, tau_far)

    dynamic_viscosity = fluid == :water ? 1.0e-3 : 1.81e-5
    sound_speed = fluid == :water ? 1480.0 : 343.0
    arm_sign = fluid == :water ? -1.0 : 1.0

    T = promote_type(typeof(rotor_radius), typeof(omega_rad_s), typeof(pitch_rad),
        typeof(hub_height), typeof(dynamic_viscosity), typeof(sound_speed), typeof(dt_s), Float64)

    return CCBladeRotorModel(
        rotor = components.rotor,
        sections = components.sections,
        radii = components.radii,
        params = params,
        omega_rad_s = T(omega_rad_s),
        pitch_rad = T(pitch_rad),
        precone_rad = T(precone_rad),
        yaw_rad = T(yaw_rad),
        tilt_rad = T(tilt_rad),
        azimuth_rad = T(azimuth_rad),
        hub_height = T(hub_height),
        shear_exp = T(shear_exp),
        arm_sign = T(arm_sign),
        dynamic_viscosity = T(dynamic_viscosity),
        sound_speed = T(sound_speed),
        dt_s = T(dt_s),
    )
end

function _ccblade_ops(model::CCBladeRotorModel, inflow_speed, fluid_density)
    v = smooth_max(inflow_speed, zero(inflow_speed))
    z = zero(v)
    arm = (z, z, model.arm_sign * model.hub_height + z)
    ops, _ = UnsteadyKineticRotorDynamics.windturbine_op_motion(
        v,
        model.omega_rad_s,
        model.pitch_rad,
        model.radii,
        model.precone_rad,
        model.yaw_rad,
        model.tilt_rad,
        model.azimuth_rad,
        model.hub_height,
        model.shear_exp,
        fluid_density;
        arm = arm,
        mu = model.dynamic_viscosity,
        asound = model.sound_speed,
    )
    return ops
end

"""
    ccblade_rotor_power_kw(model, inflow_speed, fluid_density; dt_s=model.dt_s)

Return positive mechanical rotor power in kW for a single operating point.
"""
function ccblade_rotor_power_kw(model::CCBladeRotorModel, inflow_speed, fluid_density; dt_s = model.dt_s)
    ops = _ccblade_ops(model, inflow_speed, fluid_density)
    state = UnsteadyKineticRotorDynamics.UnsteadyState(model.sections, ops; V_wake_old = smooth_max(inflow_speed, zero(inflow_speed)))
    snapshot = UnsteadyKineticRotorDynamics.unsteady_loads_step!(
        state, model.rotor, model.sections, ops, model.params;
        dt = dt_s,
        azimuth = model.azimuth_rad,
        omega = model.omega_rad_s,
    )
    return smooth_max(snapshot.shaft_power_w / 1000, zero(snapshot.shaft_power_w))
end
