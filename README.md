# SIRENOpt.jl (prototype)

This is a mid-fidelity prototype ontology for hybrid power, storage, and platform dynamics in Julia. It provides placeholder component models (solar, wind, wave, diesel, generators, converters, battery, H2, desalination) plus a controller and a step-by-step simulator that are designed to be AD-friendly and swappable with higher-fidelity packages later.

## Installation

`SIRENOpt` currently depends on several unregistered sibling packages. For the
workspace release, clone the package set side by side and instantiate from the
`SIRENOpt.jl` checkout:

```julia
using Pkg
Pkg.activate("/path/to/SIRENOpt.jl")
Pkg.instantiate()
```

For local development:

```julia
using Pkg
Pkg.develop(path = "/path/to/SIRENOpt.jl")
```

## Quick start

```julia
using SIRENOpt

const T = Float64

# Build time series profiles
t = collect(0.0:1.0:24.0)
solar_ts = TimeSeries(t, rand(length(t)))
wind_ts = TimeSeries(t, rand(length(t)))
wave_ts = TimeSeries(t, rand(length(t)))
load_ts = TimeSeries(t, 5 .+ rand(length(t)))

op = SystemOperation{T}(
    solar = SolarOp{T}(resource = solar_ts),
    wind = WindOp{T}(resource = wind_ts),
    wave = WaveOp{T}(resource = wave_ts),
    load = LoadOp{T}(demand = load_ts),
)

design = SystemDesign{T}()

states, outputs = simulate(design, op, 1.0)
```

## SNOW.jl-style objective/constraints

SNOW expects a single callback that returns the objective value and writes
constraints in-place. This package provides `snow_objective!` and helper
utilities to build a design vector and map it into a `SystemDesign`.

```julia
using SIRENOpt

const T = Float64

design = SystemDesign{T}()
op = SystemOperation{T}(load = LoadOp{T}(demand = TimeSeries([0.0, 1.0], [5.0, 5.0])))

varspec = default_design_varspec(design)
x0 = varspec_x0(varspec)

problem = SnowProblem{T}(
    base_design = design,
    operation = op,
    dt_hours = 1.0,
    constraint_spec = ConstraintSpec{T}(battery_only_hours = 2.0),
    objective_mode = :dynamic,
    varspec = varspec,
)

g = zeros(constraint_count(problem))
f = snow_objective!(g, x0, problem)
```

## Swappable models

Replace any of the placeholder component functions (e.g. `solar_power`, `wave_power`, `diesel_power`) with higher-fidelity implementations. The interfaces are organized around explicit `Design` and `Op` structs to keep model substitution clean.

Platform station-keeping can use `Mooring.jl` through `PlatformDesign.mooring_model`. The adapter builds Mooring parameter handlers, exposes line setup/quasi-static solve calls, and adds Mooring-derived line mass and restoring force to the platform dynamics path.

Six-degree-of-freedom platform motion can use the `Hydrodynamics.jl` 6-DOF
adapter through `PlatformDesign.hydrodynamic_model`. The SIRENOpt adapter
passes 6-DOF external wrenches, wave components, velocity history, and optional
nonlinear coefficient diagnostics into the Hydrodynamics Cummins-style solver
while keeping the energy, storage, water, and electrical bus simulation in
SIRENOpt.

## AD and implicit solves

- The model functions are written generically for AD types.
- For implicit or iterative solves, `dynamics_step` can accept a user-supplied solver (`solve_residual`) compatible with packages like `ImplicitAD.jl`.
- Sparse gradient methods can be applied at the optimization layer (e.g. with `SNOW.jl`) since the functions are side-effect free and structured around small, composable calls.

## Notes

- Power flow signs: sources are positive, loads are negative, and converters map device-side power to bus-side power.
- The controller implements the requested priority: keep bus voltage up, use non-diesel first, then diesel, and use the battery for buffering while shedding H2/desal when predicted battery depletion is likely.

## Tests as examples

The Julia tests under `test/runtests.jl` are written as executable examples.
Run them with:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

## Examples

The solver and plotting examples use their own environment so the package
runtime dependencies stay focused on the library:

```bash
julia --project=examples -e 'using Pkg; Pkg.instantiate()'
julia --project=examples examples/short_horizon_sirenolite.jl
julia --project=examples examples/full_system_hydrodynamics6dof_demo.jl
```

- `examples/snow_single_point.jl` shows single-point SNOW optimization.
- `examples/snow_dynamic.jl` shows dynamic optimization in two modes:
  `MODE = :adjoint` (implicit solve + adjoint) and `MODE = :simultaneous`
  (design/control/state variables optimized together).
- `examples/short_horizon_sirenolite.jl` builds 1-minute, 0.01 s profiles by
  interpolating the SIRENO-Lite CSV input and injecting band-limited noise,
  then runs a closed-loop simulation.
- `examples/short_horizon_snow.jl` runs a compact SNOW optimization with 1-second
  control blocks over the same 0.01 s profiles.
- `examples/full_system_hydrodynamics6dof_demo.jl` runs one coupled scenario with
  PVlib-backed solar, wind, wave, hydrokinetic, diesel/generator/converter,
  AgnosticStorageDynamics battery, H2Gen hydrogen, Desal water production, and an
  Hydrodynamics 6DOF floating platform.

SNOW-based examples require the same examples environment:

```bash
SIRENO_SHORT_SOLVER=ipopt julia --project=examples examples/short_horizon_snow.jl
```

## SIRENO-Lite defaults

`SystemDesign()` now initializes fields with values mapped from the
SIRENO-Lite `default_inputs()` configuration (cost, mass, efficiency,
and storage sizing). See `src/types.jl` for the explicit mapping.
Use `platform_from_supported_mass` if you want platform mass/cost to track
the current supported mass ratio.

The SIRENO-Lite resource CSV used by the short-horizon examples is included
at `data/sirenolite_load_resource_data.csv` for self-contained runs.
