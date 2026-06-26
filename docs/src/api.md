# API

## Ontology Workflow

The verified public V1 workflow is:

- `MinimalEnergyOntology` constructs the first validated block graph.
- `PackageBackedHybridOntology` adds package-backed wind rotor, generator, and
  converter blocks plus reported wave/WEC surrogate blocks without changing the
  workflow. Set `include_hydrokinetic=true` to add the package-backed
  hydrokinetic rotor, generator, and converter chain.
- Set `include_diesel=true` on a builder to add a package-backed DieselGen
  engine map, fuel inventory state, GeneratorSE generator, and
  PowerConverterDynamics converter.
- Set `include_h2=true` or `include_desal=true` to add package-backed process
  loads with tank inventories, process demand profiles, and signed bus
  consumption through PowerConverterDynamics.
- `DynamicMultilevelHybridOntology` adds a reduced platform motion block,
  force/moment and motion-state ports, dynamic defects, and level-map reports.
- `FullSIRENOptOntology` remains reserved so the full name does not overstate
  package-backed WEC/PTO, hydrodynamic, or mooring coverage.
- `ShortHorizonScenario` supplies time grids, resources, demands, initial states,
  and provenance.
- `describe(system)` returns component, design-default, scenario, formulation,
  and validation summaries.
- `audit(system, scenario; formulation = Collocation())` returns connection,
  variable, residual, output, port, model-path, and validation tables.
- `assemble(system, scenario, formulation)` creates registry-backed vectors,
  bounds, constraint bounds, and callback traces without manual indexing.
- `Shooting(kind = :single)` and `Shooting(kind = :multiple)` expose design and
  control variables while replaying states through the block kernels; retained
  implicit solve boundaries are reported in `formulation_boundaries.csv`.
- `simulate`, `optimize`, `replay`, and `report` run and document the same block
  equations. `report` writes component, port, connection, variable, residual,
  output, model-path, level-map, formulation-boundary, plot-inventory,
  time-series, control, state, replay-residual, standard SVG plot, and
  provenance artifacts.

```@autodocs
Modules = [SIRENOpt]
```
