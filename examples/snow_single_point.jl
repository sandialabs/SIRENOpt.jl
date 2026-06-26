"""
Single-point design optimization example using SNOW.

This script minimizes a single-point cost objective while enforcing
sizing constraints. It demonstrates the SNOW-style callback expected by
`minimize(func!, x0, ng, ...)`.

Requires:
  - SNOW.jl
  - A nonlinear solver supported by SNOW (e.g. Ipopt)
"""

using SIRENOpt
using SNOW

const T = Float64

# -------------------------
# Problem setup
# -------------------------

# Simple deterministic profiles (single-point uses k=2 below).
t = [0.0, 1.0, 2.0]
solar_ts = TimeSeries(t, [0.3, 0.6, 0.1])
wind_ts = TimeSeries(t, [5.0, 6.0, 4.0])
wave_ts = TimeSeries(t, [2.0, 2.0, 2.0])
load_ts = TimeSeries(t, [6.0, 6.0, 6.0])

op = SystemOperation{T}(
    solar = SolarOp{T}(resource = solar_ts),
    wind = WindOp{T}(resource = wind_ts),
    wave = WaveOp{T}(resource = wave_ts),
    load = LoadOp{T}(demand = load_ts),
)

design = SystemDesign{T}()

varspec = default_design_varspec(design)
x0 = varspec_x0(varspec)
(lx, ux) = varspec_bounds(varspec)

problem = SnowProblem{T}(
    base_design = design,
    operation = op,
    dt_hours = 1.0,
    constraint_spec = ConstraintSpec{T}(
        battery_only_hours = 1.0,
        battery_plus_renewables_hours = 1.0,
        full_system_hours = 1.0,
    ),
    objective_mode = :single_point,
    single_point_index = 2,
    varspec = varspec,
)

ng = constraint_count(problem)
lg = zeros(ng)
ug = fill(Inf, ng)

# -------------------------
# SNOW callback
# -------------------------

function obj!(g, x)
    return snow_objective!(g, x, problem)
end

# -------------------------
# Solve
# -------------------------

options = Options(derivatives = ForwardAD())
x_opt, f_opt, status, _ = minimize(obj!, x0, ng, lx, ux, lg, ug, options)

println("status: ", status)
println("f*: ", f_opt)
println("x*: ", x_opt)
