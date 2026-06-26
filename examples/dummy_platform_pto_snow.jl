"""
Simple dummy platform/PTO/solar SNOW example.

Run from the package root with:

    julia --project=examples examples/dummy_platform_pto_snow.jl

This is a coding-style example only. The equations and numbers are arbitrary.
"""

import SNOW

ENV["GKSwstype"] = get(ENV, "GKSwstype", "100")
import Plots

Plots.default(
    size = (700, 500),
    linewidth = 1.5,
    markersize = 3,
    legend = :topright,
    foreground_color_legend = nothing,
    background_color_legend = nothing,
    left_margin = 6Plots.mm,
    bottom_margin = 6Plots.mm,
)

path, _ = splitdir(@__FILE__)
plot_cycle = ["#348ABD", "#A60628", "#009E73", "#7A68A6", "#D55E00", "#CC79A7"]

const HORIZON_S = 10.0
const DT_S = 0.1
const NSTEPS = Int(round(HORIZON_S / DT_S))
const NNODES = NSTEPS + 1
const FORCE_BOUND_N = 500.0
const ENERGY_SCALE_J = 1000.0

const SWAY = 1
const HEAVE = 2
const PITCH = 3
const SWAY_VEL = 4
const HEAVE_VEL = 5
const PITCH_VEL = 6
const NSTATE = 6

const INITIAL_STATE = [0.15, -0.08, 0.04, 0.0, 0.0, 0.0]
const TIME_S = collect(0.0:DT_S:HORIZON_S)
const STEP_TIME_S = TIME_S[1:end-1]

const PLATFORM = (
    mass_kg = 1200.0,
    cm_x_m = 0.0,
    cm_z_m = -0.35,
    pitch_inertia_kg_m2 = 3500.0,
    k_sway = 450.0,
    k_heave = 700.0,
    k_pitch = 2600.0,
    c_sway = 85.0,
    c_heave = 120.0,
    c_pitch = 210.0,
)

const SOLAR = (
    mass_kg = 80.0,
    cm_x_m = 1.20,
    cm_z_m = 1.10,
    base_power_w = 180.0,
    sway_power_w_per_m = 3.0,
    heave_power_w_per_m = 12.0,
    pitch_power_w_per_rad = -20.0,
)

const PTO_X_M = -0.60

function run_dummy_platform_pto_snow()
    ipopt_options = Dict(
        "hessian_approximation" => "limited-memory",
        "limited_memory_update_type" => "bfgs",
        "print_level" => 0,
        "dual_inf_tol" => 1e-1,
        "constr_viol_tol" => 1e-6,
        "compl_inf_tol" => 1e-1,
        "tol" => 1e-4,
        "acceptable_tol" => 1e-4,
        "acceptable_iter" => 3,
        "max_iter" => 500,
    )
    snow_options = SNOW.Options(solver=SNOW.IPOPT(ipopt_options), derivatives=SNOW.ForwardAD())

    zero_pto = zeros(NSTEPS)

    x_shoot, f_shoot, status_shoot, _ = SNOW.minimize(
        shooting_objcon!,
        zero_pto,
        1,
        fill(-FORCE_BOUND_N, NSTEPS),
        fill(FORCE_BOUND_N, NSTEPS),
        zeros(1),
        zeros(1),
        snow_options,
    )
    shooting_result = replay_shooting(x_shoot)
    shooting_con = zeros(1)
    shooting_objcon!(shooting_con, x_shoot; runplot=true)
    summarize("Euler shooting SNOW result", f_shoot, status_shoot, shooting_result,
        maximum(abs.(shooting_con)))

    ng = NSTATE + NSTATE * NSTEPS
    collocation_x0 = collocation_initial_guess(zero_pto)
    bounds = collocation_bounds()
    x_colloc, f_colloc, status_colloc, _ = SNOW.minimize(
        collocation_objcon!,
        collocation_x0,
        ng,
        bounds.lx,
        bounds.ux,
        zeros(ng),
        zeros(ng),
        snow_options,
    )
    collocation_con = zeros(ng)
    collocation_objcon!(collocation_con, x_colloc; runplot=true)
    collocation_parts = unpack_collocation(x_colloc)
    collocation_result = merge(
        (states = collocation_parts.states,),
        power_history(collocation_parts.states, collocation_parts.pto_forces),
    )
    summarize("Direct collocation SNOW result", f_colloc, status_colloc,
        collocation_result, maximum(abs.(collocation_con)))

    println()
    println("Saved shooting plot: ", plot_path("shooting"))
    println("Saved collocation plot: ", plot_path("collocation"))
end

function solar_panel(motion)
    power_w = SOLAR.base_power_w +
        SOLAR.sway_power_w_per_m * motion[SWAY] +
        SOLAR.heave_power_w_per_m * motion[HEAVE] +
        SOLAR.pitch_power_w_per_rad * motion[PITCH]
    return (
        mass_kg = SOLAR.mass_kg,
        cm_x_m = SOLAR.cm_x_m,
        cm_z_m = SOLAR.cm_z_m,
        force_sway_n = zero(power_w),
        force_heave_n = zero(power_w),
        pitch_moment_nm = zero(power_w),
        power_w = power_w,
    )
end

function mass_properties(motion)
    panel = solar_panel(motion)
    mass_kg = PLATFORM.mass_kg + panel.mass_kg
    cm_x_m = (PLATFORM.mass_kg * PLATFORM.cm_x_m + panel.mass_kg * panel.cm_x_m) / mass_kg
    cm_z_m = (PLATFORM.mass_kg * PLATFORM.cm_z_m + panel.mass_kg * panel.cm_z_m) / mass_kg
    pitch_inertia = PLATFORM.pitch_inertia_kg_m2 +
        PLATFORM.mass_kg * (PLATFORM.cm_x_m - cm_x_m)^2 +
        panel.mass_kg * (panel.cm_x_m - cm_x_m)^2
    return (mass_kg = mass_kg, cm_x_m = cm_x_m, cm_z_m = cm_z_m,
        pitch_inertia_kg_m2 = pitch_inertia)
end

function wave_excitation(t_s)
    return (
        sway_n = 90.0 * sin(2pi * t_s / 4.0 + 0.4),
        heave_n = 650.0 * sin(2pi * t_s / 2.6),
        pitch_nm = 360.0 * sin(2pi * t_s / 3.2 + 0.8),
    )
end

function pto(motion, force_n, mass_props)
    return (
        heave_n = force_n,
        pitch_nm = force_n * (PTO_X_M - mass_props.cm_x_m),
        platform_power_w = force_n * motion[HEAVE_VEL],
    )
end

function platform_acceleration(motion, pto_force_n, t_s)
    panel = solar_panel(motion)
    mass = mass_properties(motion)
    wave = wave_excitation(t_s)
    pto_load = pto(motion, pto_force_n, mass)

    sway_force = wave.sway_n + panel.force_sway_n -
        PLATFORM.k_sway * motion[SWAY] - PLATFORM.c_sway * motion[SWAY_VEL]
    heave_force = wave.heave_n + panel.force_heave_n + pto_load.heave_n -
        PLATFORM.k_heave * motion[HEAVE] - PLATFORM.c_heave * motion[HEAVE_VEL]
    pitch_moment = wave.pitch_nm + panel.pitch_moment_nm + pto_load.pitch_nm -
        PLATFORM.k_pitch * motion[PITCH] - PLATFORM.c_pitch * motion[PITCH_VEL]

    return (
        sway = sway_force / mass.mass_kg,
        heave = heave_force / mass.mass_kg,
        pitch = pitch_moment / mass.pitch_inertia_kg_m2,
    )
end

function power_terms(motion, pto_force_n)
    panel = solar_panel(motion)
    pto_load = pto(motion, pto_force_n, mass_properties(motion))
    pto_extracted_w = -pto_load.platform_power_w # negative platform power means extraction
    return (
        solar_w = panel.power_w,
        pto_platform_w = pto_load.platform_power_w,
        pto_extracted_w = pto_extracted_w,
        useful_w = panel.power_w + pto_extracted_w,
    )
end

function euler_step(motion, pto_force_n, t_s)
    acc = platform_acceleration(motion, pto_force_n, t_s)
    next = similar(motion)
    next[SWAY_VEL] = motion[SWAY_VEL] + DT_S * acc.sway
    next[HEAVE_VEL] = motion[HEAVE_VEL] + DT_S * acc.heave
    next[PITCH_VEL] = motion[PITCH_VEL] + DT_S * acc.pitch
    next[SWAY] = motion[SWAY] + DT_S * next[SWAY_VEL]
    next[HEAVE] = motion[HEAVE] + DT_S * next[HEAVE_VEL]
    next[PITCH] = motion[PITCH] + DT_S * next[PITCH_VEL]
    return next
end

function power_history(states, pto_forces)
    T = eltype(pto_forces)
    solar_w = zeros(T, NSTEPS)
    pto_platform_w = zeros(T, NSTEPS)
    pto_extracted_w = zeros(T, NSTEPS)
    useful_w = zeros(T, NSTEPS)

    for k in 1:NSTEPS
        p = power_terms(view(states, :, k), pto_forces[k])
        solar_w[k] = p.solar_w
        pto_platform_w[k] = p.pto_platform_w
        pto_extracted_w[k] = p.pto_extracted_w
        useful_w[k] = p.useful_w
    end

    return (
        solar_w = solar_w,
        pto_platform_w = pto_platform_w,
        pto_extracted_w = pto_extracted_w,
        useful_w = useful_w,
        solar_energy_j = sum(solar_w) * DT_S,
        pto_extracted_energy_j = sum(pto_extracted_w) * DT_S,
        useful_energy_j = sum(useful_w) * DT_S,
    )
end

function replay_shooting(pto_forces)
    T = eltype(pto_forces)
    states = zeros(T, NSTATE, NNODES)
    states[:, 1] .= INITIAL_STATE .+ zero(T)
    for k in 1:NSTEPS
        states[:, k + 1] .= euler_step(view(states, :, k), pto_forces[k], STEP_TIME_S[k])
    end
    return merge((states = states,), power_history(states, pto_forces))
end

function shooting_objcon!(con, pto_forces; runplot=false, label="shooting")
    result = replay_shooting(pto_forces)
    con[1] = zero(eltype(pto_forces))
    runplot && plot_result(result, pto_forces; label=label)
    return -result.useful_energy_j / ENERGY_SCALE_J
end

state_range(k) = ((k - 1) * NSTATE + 1):(k * NSTATE)
control_range() = (NSTATE * NNODES + 1):(NSTATE * NNODES + NSTEPS)
unpack_collocation(x) = (
    states = reshape(view(x, 1:(NSTATE * NNODES)), NSTATE, NNODES),
    pto_forces = view(x, control_range()),
)

function collocation_initial_guess(pto_forces)
    return vcat(vec(replay_shooting(pto_forces).states), pto_forces)
end

function collocation_bounds()
    lx_state = fill(-Inf, NSTATE * NNODES)
    ux_state = fill(Inf, NSTATE * NNODES)
    for k in 1:NNODES
        lx_state[state_range(k)] .= [-5.0, -5.0, -0.8, -4.0, -4.0, -1.5]
        ux_state[state_range(k)] .= [5.0, 5.0, 0.8, 4.0, 4.0, 1.5]
    end
    return (
        lx = vcat(lx_state, fill(-FORCE_BOUND_N, NSTEPS)),
        ux = vcat(ux_state, fill(FORCE_BOUND_N, NSTEPS)),
    )
end

function fill_collocation_constraints!(con, x)
    parts = unpack_collocation(x)
    states = parts.states
    forces = parts.pto_forces
    row = 0

    for i in 1:NSTATE
        row += 1
        con[row] = states[i, 1] - INITIAL_STATE[i]
    end

    for k in 1:NSTEPS
        now = view(states, :, k)
        nxt = view(states, :, k + 1)
        acc_now = platform_acceleration(now, forces[k], STEP_TIME_S[k])
        acc_nxt = platform_acceleration(nxt, forces[k], TIME_S[k + 1])

        row += 1
        con[row] = nxt[SWAY] - now[SWAY] - 0.5 * DT_S * (now[SWAY_VEL] + nxt[SWAY_VEL])
        row += 1
        con[row] = nxt[HEAVE] - now[HEAVE] - 0.5 * DT_S * (now[HEAVE_VEL] + nxt[HEAVE_VEL])
        row += 1
        con[row] = nxt[PITCH] - now[PITCH] - 0.5 * DT_S * (now[PITCH_VEL] + nxt[PITCH_VEL])
        row += 1
        con[row] = nxt[SWAY_VEL] - now[SWAY_VEL] - 0.5 * DT_S * (acc_now.sway + acc_nxt.sway)
        row += 1
        con[row] = nxt[HEAVE_VEL] - now[HEAVE_VEL] - 0.5 * DT_S * (acc_now.heave + acc_nxt.heave)
        row += 1
        con[row] = nxt[PITCH_VEL] - now[PITCH_VEL] - 0.5 * DT_S * (acc_now.pitch + acc_nxt.pitch)
    end
end

function collocation_objcon!(con, x; runplot=false, label="collocation")
    fill_collocation_constraints!(con, x)
    parts = unpack_collocation(x)
    result = merge((states = parts.states,), power_history(parts.states, parts.pto_forces))
    runplot && plot_result(result, parts.pto_forces; label=label)
    return -result.useful_energy_j / ENERGY_SCALE_J
end

function plot_path(label)
    clean_label = replace(lowercase(String(label)), r"[^a-z0-9]+" => "_")
    return joinpath(path, "dummy_platform_pto_snow_$(clean_label)_profile.png")
end

function plot_result(result, pto_forces; label)
    p1 = Plots.plot(TIME_S, result.states[HEAVE, :]; label="$label heave",
        color=plot_cycle[1], xlabel="time (s)", ylabel="motion")
    Plots.plot!(p1, TIME_S, result.states[HEAVE_VEL, :]; label="$label heave velocity",
        color=plot_cycle[2])
    Plots.plot!(p1, TIME_S, result.states[PITCH, :]; label="$label pitch",
        color=plot_cycle[3])

    p2 = Plots.plot(STEP_TIME_S, pto_forces; label="$label PTO force",
        color=plot_cycle[4], xlabel="time (s)", ylabel="force (N)")

    p3 = Plots.plot(STEP_TIME_S, result.solar_w; label="$label solar",
        color=plot_cycle[5], xlabel="time (s)", ylabel="power (W)")
    Plots.plot!(p3, STEP_TIME_S, result.pto_platform_w;
        label="$label PTO platform power", color=plot_cycle[6])
    Plots.plot!(p3, STEP_TIME_S, result.useful_w;
        label="$label useful power", color=plot_cycle[1])

    fig = Plots.plot(p1, p2, p3; layout=(3, 1), size=(760, 820))
    Plots.savefig(fig, plot_path(label))
    return fig
end

function summarize(label, fopt, status, result, max_constraint)
    println()
    println(label)
    println("  status: ", status)
    println("  objective: ", fopt)
    println("  useful energy (J): ", result.useful_energy_j)
    println("  solar energy (J): ", result.solar_energy_j)
    println("  PTO extracted energy (J): ", result.pto_extracted_energy_j)
    println("  mean useful power (W): ", result.useful_energy_j / HORIZON_S)
    println("  max abs constraint: ", max_constraint)
end

run_dummy_platform_pto_snow()
