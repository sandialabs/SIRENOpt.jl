# Quick Start

## Installation

`SIRENOpt` is an unregistered workspace package. It currently relies on several
unregistered sibling packages through the `[sources]` table in `Project.toml`,
so clone the package set side by side before instantiating the environment:

```julia
using Pkg
Pkg.activate("/path/to/SIRENOpt.jl")
Pkg.instantiate()
```

For editable development from the checkout:

```julia
using Pkg
Pkg.develop(path = "/path/to/SIRENOpt.jl")
```

## Examples

The shortest ontology-driven workflow uses the V1 minimal energy graph:

```bash
julia --project=. examples/minimal_ontology_workflow.jl
```

For a step-by-step notebook that builds the reduced pendulum platform graph,
declares `OptimizationParameters.jl` design variables, runs collocation,
saves plots, and reuses the same parameter table across horizon/fidelity
variants, see [Pendulum Platform Ontology Tutorial](tutorials/pendulum_platform_tutorial.md).

That script runs the same block graph through:

```julia
using SIRENOpt

scenario = ShortHorizonScenario(
    horizon_s = 2 * 3600.0,
    dt_s = 3600.0,
    solar_irradiance_kw_per_m2 = [0.6, 0.2],
    load_kw = [1.0, 1.0],
)

system = MinimalEnergyOntology(scenario = scenario)
describe(system)
audit(system, scenario; formulation = Collocation())

sim = simulate(system, scenario; controller = RuleBasedController())
opt = optimize(system, scenario; formulation = Collocation())
replayed = replay(opt)
reported = report(opt, "examples/results/minimal_ontology_workflow")
```

The generated report directory contains component, port, connection, variable,
residual, output, model-path, level-map, formulation-boundary, plot-inventory,
control, state, time-series, and replay-residual CSV files plus standard SVG
plots generated from `OutputSpec.plot_group` metadata. The minimal graph labels
scenario data as prescribed, component equations as surrogate or hard residual
paths, and does not silently switch model fidelity.

Optional source blocks can be added to the same workflow. For example,
`MinimalEnergyOntology(include_diesel = true, ...)` adds a DieselGen-backed
engine with a fuel state and generator/converter bus path, while
`PackageBackedHybridOntology(include_hydrokinetic = true, ...)` adds the
hydrokinetic current-to-bus chain. `include_h2 = true` and
`include_desal = true` add process demand profiles, bus-consuming converter
paths, and tank inventory residuals.

For the fast motion-coupled acceptance fixture, run:

```bash
julia --project=. examples/multilevel_collocation_hybrid_demo.jl
```

That demo uses `DynamicMultilevelHybridOntology` with wind, wave/WEC,
hydrokinetic, solar, battery, load, bus, generator, converter, and a reduced
pendulum platform. It writes the standard reports, SVG plots, and
`derivative_checks.csv`; `level_maps.csv` and `map_metadata.csv` state each
contract's producing level, consuming level, units, dependencies, valid range,
interpolation method, verification case, active-bound report, and model path.
The example also writes `level1_map_summary.csv`, `level2_dynamic_event.csv`,
and `level3_reliability_bins.csv` so the fast run shows the flow from
motion-coupled characterization to reduced dispatch events and binned
reliability checks. The final acceptance formulation also registers terminal SOC
and WEC PTO limit residuals and writes `manuscript_summary_table.csv` plus
`manuscript_figure_manifest.csv` from saved result files. In the default run,
wind platform moment changes the platform state and that motion feeds back into
the wind source path. Set `SIRENOPT_ONTOLOGY_LONG_HORIZON=1` for the opt-in daily
resource sweep.

The examples use a separate project for solver and plotting dependencies.
Instantiate it once, then run examples from the package root:

```bash
julia --project=examples -e 'using Pkg; Pkg.instantiate()'
julia --project=. examples/minimal_ontology_workflow.jl
julia --project=. examples/multilevel_collocation_hybrid_demo.jl
julia --project=. examples/sirenolite_comparison_fixture.jl
julia --project=. examples/snow_examples_block_api.jl
julia --project=examples examples/short_horizon_sirenolite.jl
julia --project=examples examples/full_system_hydrodynamics6dof_demo.jl
```

`sirenolite_comparison_fixture.jl` writes `comparison_inputs.csv`,
`sirenolite_reference_timeseries.csv`, `sirenopt_timeseries.csv`,
`comparison_metrics.csv`, `model_differences.csv`, a side-by-side time series,
model-path table, and comparison SVG. The reference path is the legacy
SIRENO-lite-aligned simulator; the SIRENOpt path is `SIRENOLiteOntology` with
package-backed and surrogate paths labeled in the generated reports.

`snow_examples_block_api.jl` runs ontology/block-API equivalents of the legacy
SNOW examples and writes one summary row per migrated case with formulation,
time grid, package-backed blocks, model-path report, and replay residual report.

The SNOW example accepts environment variables for quick solver experiments:

```bash
SIRENO_SHORT_HORIZON_S=2 \
SIRENO_SHORT_DT_S=0.2 \
SIRENO_SHORT_MAX_ITER=80 \
SIRENO_SHORT_SOLVER=ipopt \
julia --project=examples examples/short_horizon_snow.jl
```

Solver logs are written under `examples/solver_logs/` and should be preserved for
optimization debugging. Generated logs and plots are ignored by git except for the
placeholder files that keep the directories present.

Long ontology examples and paper-regression inputs are opt-in:

```bash
SIRENOPT_RUN_LONG_TESTS=1 julia --project=. test/long_runtests.jl
SIRENOPT_RUN_LONG_TESTS=1 julia --project=. examples/run_long_regressions.jl
```

Hot kernels can be profiled without report or plotting work:

```bash
julia --project=. scripts/profile_hot_kernels.jl
```

## PVlib-backed solar

For a package-backed solar path, build a `PvlibSolarModel` and attach it to
`SolarDesign`. Provide the corresponding weather and solar-position samples
through `SolarOp`.

```julia
using SIRENOpt
using PVlib

weather = PVlib.WeatherSample(
    PVlib.ZonedDateTime(2020, 6, 1, 12, 0, 0, PVlib.TimeZone("America/Denver")),
    800.0, 900.0, 100.0, 20.0, 50.0, 101325.0, 1.5, 180.0,
)
solar_pos = PVlib.get_solar_position(35.1, -106.6, 1500.0, weather)
pv_model = pvlib_solar_model(surface_tilt_deg = 35.1, surface_azimuth_deg = 180.0, altitude_m = 1500.0)

design = SystemDesign(
    solar = SolarDesign(area = pv_model.pv_module.area, efficiency = 1.0, pv_model = pv_model),
)
op = SystemOperation(
    solar = SolarOp(resource = TimeSeries([0.0], [0.0]), pv_weather = [weather], pv_solar_position = [solar_pos]),
)

p_kw = power_available_solar(design.solar, op.solar, 1)
```

This path is explicit and currently differentiable with respect to the SIRENOpt
design variables that act on it, including array area.

## Full-System Hydrodynamics 6DOF Demonstration

`examples/full_system_hydrodynamics6dof_demo.jl` is the current executable integration
reference. It keeps all major subsystem paths active in one short simulation:
PVlib solar, wind, wave-resource conversion, hydrokinetic conversion, diesel
dispatch, generator and converter losses, battery charge, hydrogen production,
desalination, load service, and a six-degree-of-freedom Hydrodynamics platform
driven by external wrench and wave excitation.

From Julia, the same scenario can be used as a fixture:

```julia
include("examples/full_system_hydrodynamics6dof_demo.jl")
result = run_full_system_hydrodynamics6dof_demo()

result.states[end].platform.position
sum(output -> output.diesel_fuel_used, result.outputs)
```
