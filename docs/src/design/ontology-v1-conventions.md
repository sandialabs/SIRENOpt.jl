# Decision: Ontology V1 Units, Signs, Model Paths, And Formulation

Status: accepted
Date: 2026-06-24

## Context

`MinimalEnergyOntology`, `PackageBackedHybridOntology`, and
`DynamicMultilevelHybridOntology` share one registry and report contract. The
package-backed and dynamic builders need stable conventions for package adapter
boundaries, reduced motion feedback, and substitution reporting.

## Decision

- Bus power is in `kW`; positive values inject power into the bus balance and
  load is negative in the balance.
- Battery command is in `kW`; positive command discharges to the bus and
  negative command charges from the bus.
- Scenario grids use seconds through `TimeGrid.dt_s`; storage inventory converts
  to hours once inside the replay equation.
- The V1 model-path labels are `prescribed`, `surrogate`, `package_backed`,
  `placeholder`, `replay_only`, `hard_residual`, and `smooth_approximation`.
- Package-backed wind, generator, and converter outputs are normalized so zero
  upstream power contributes exactly zero downstream power at the ontology
  boundary.
- Hydrokinetic V1 is opt-in through `include_hydrokinetic=true`. It uses the
  same resource-to-shaft-to-generator-to-converter ontology chain as wind, with
  prescribed current speed in `m/s`, water density in `kg/m^3`, and positive bus
  power injection.
- Diesel V1 is opt-in through `include_diesel=true`. It uses DieselGen for
  primal fuel use, GeneratorSE and PowerConverterDynamics for the electrical
  chain, a node fuel state in liters, and a hard fuel inventory residual.
- Hydrogen and desalination V1 are opt-in through `include_h2=true` and
  `include_desal=true`. They use H2Gen and Desal process adapters for primal
  conversion, signed bus-consuming converter paths, demand profiles in `kg/h`
  and `m^3/h`, and hard tank inventory residuals.
- The current UnsteadyKineticRotorDynamics path is package-backed for primal
  replay. ForwardDiff sensitivity through dual-valued motion or hydrokinetic
  resource inputs uses a reported SIRENOpt smooth actuator-disk envelope until
  the upstream package exposes dual-valued rotor state.
- Replay feasibility is checked against the full registered collocation
  constraint set reconstructed from replay controls and states; individual
  bus/inventory/platform residual maxima remain in `replay_residuals.csv` as
  diagnostics.
- Dynamic V1 coupling uses a reduced single-DOF pendulum platform fallback:
  positive wind pitch moment increases platform pitch rate, and platform pitch
  feeds back into effective wind inflow with a `cos(theta)` factor.
- Standard ontology reports include `outputs.csv`, `plots.csv`, and dependency-free
  SVG figures. Plot series are selected from `OutputSpec.plot_group`, labels, and
  units, then written from replay result tables.
- `Collocation(method = :trapezoidal)` is the default optimization formulation
  name for the direct-transcription family, even when a tiny fixture has a
  closed-form deterministic solve.
- `Shooting(kind = :single)` and `Shooting(kind = :multiple)` expose design and
  control variables, replay states through the same block kernels, and record
  retained implicit solve boundaries in `formulation_boundaries.csv`.

## Alternatives Considered

- Preserve example-local vector indexing until every subsystem is migrated. This
  was rejected because it does not satisfy ontology traceability or block removal
  tests.
- Treat load as an input-only port and hide its bus contribution in prose. This
  was rejected because the bus residual needs a visible signed contribution in
  the port graph and residual audit.
- Alias `FullSIRENOptOntology` to the reduced dynamic graph. This was rejected
  because the full name would overstate package-backed WEC/PTO, hydrodynamic,
  and mooring coverage.

## Verification

- `test/runtests.jl` checks the minimal ontology block inventory, registry,
  connection graph, residual trace, simulation replay, optimization replay,
  metadata reports, package-backed wind/generator/converter paths, wave
  surrogate labeling, dynamic motion feedback, metadata-generated plots,
  derivative checks, shooting formulation boundaries, and battery-disable orphan
  removal.
- `examples/minimal_ontology_workflow.jl` runs the public
  `build -> audit -> simulate -> optimize -> replay -> report` workflow.
- `examples/multilevel_collocation_hybrid_demo.jl` runs the reduced dynamic
  acceptance fixture and writes standard reports, map contract metadata,
  Level 1/2/3 acceptance CSVs, terminal SOC and WEC PTO residual evidence,
  manuscript-facing tables, and derivative checks.
- `examples/sirenolite_comparison_fixture.jl` regenerates fixed-input
  reference-vs-ontology comparison inputs, separate reference and SIRENOpt time
  series, metrics, model-path differences, and a compact SVG plot without manual
  value copying.

## Revisit When

- Package-backed WEC/PTO, hydrodynamic, mooring, or annual reliability blocks
  replace the current reported V1 substitutions.
- The upstream rotor package exposes dual-valued motion state so the smooth AD
  envelope can be removed.
