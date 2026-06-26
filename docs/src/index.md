# SIRENOpt.jl

`SIRENOpt` is the ontology and glue layer for hybrid offshore energy systems. It
couples placeholder and package-backed subsystem models for floating platform
motion and mooring, wind, wave, solar, hydrokinetic conversion, generators,
power conversion, battery/storage, hydrogen, potable-water desalination, loads,
and controllers.

The package is designed for dynamic simulation and control co-design. Subsystems
exchange explicit physical quantities such as power, voltage, current, force,
mass, volume, stored energy, hydrogen, potable water, and platform state so higher
fidelity packages can replace placeholders without changing the system-level
contract.

The current stable solar integration path can use `PVlib` for explicit PV
resource-to-DC-power calculations while keeping generator and converter models
inside the SIRENOpt ontology. That keeps the subsystem boundary aligned with the
broader co-design objective: package-backed physics where they are stable, and
explicit system-level coupling for electrical and control interactions.

The V1 ontology path includes three public builders. `MinimalEnergyOntology`
provides the smallest solar, converter, battery, load, and bus graph.
`PackageBackedHybridOntology` adds package-backed wind rotor, generator, and
power-converter paths plus a reported wave/WEC surrogate and an opt-in
package-backed hydrokinetic rotor/generator/converter chain via
`include_hydrokinetic=true`; any builder can also add package-backed diesel
backup with fuel inventory via `include_diesel=true`, hydrogen production and
storage via `include_h2=true`, and desalination/storage via
`include_desal=true`.
`DynamicMultilevelHybridOntology` adds a reduced pendulum platform with
force/moment and motion-state ports. All three support `describe`, `audit`,
`simulate`, `optimize`, `replay`, and `report` from the same block metadata,
with component tables, port graphs, registry traces, model-path labels,
level-map reports, standard SVG plots, and replay residuals.
