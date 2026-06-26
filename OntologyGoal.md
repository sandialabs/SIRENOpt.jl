# SIRENOpt Ontology Goal

## Purpose

SIRENOpt.jl should make hybrid-system simulation and optimization straightforward.
The package should let a user assemble a system from readable building blocks,
swap fidelity levels, run ordinary forward simulations, and promote the same
system definition into an optimization problem without rewriting the model.

The intended role of SIRENOpt is the ontology and assembly layer. Subpackages
provide subsystem physics. SIRENOpt defines the common language between them:
power, voltage, current, force, moment, mass, cost, volume, resource state,
storage inventory, platform state, controls, limits, and residuals.

The user-facing model should answer questions like:

- What components are in this system?
- What resource and demand profiles drive it?
- Which quantities are states, controls, design variables, and outputs?
- Which constraints are hard physical equations?
- Which objective is being minimized?
- What changed when a component was added, removed, or upgraded in fidelity?

## How To Use This File

This file is both the design goal and the implementation guide for future
agents. The sections are not all equally normative. Use it in this order:

For a shorter BLUF summary, read `human_readable_goal.md` first, then return
here for implementation details.

1. Read **Purpose**, **Ontology Specification Boundary**, **Competency Questions
   And Required Artifacts**, and **Core Ontology Object Model** to understand the
   required ontology.
2. Read **Canonical Minimal Ontology Slice**, **Common Ontologies**, **Port Type
   Glossary**, and **Port Validation Semantics** before adding or changing
   blocks, ports, or ontology builders.
3. Read **Current Code Migration Bridge** before changing existing
   `SystemDesign`, `SystemOperation`, `SystemState`, `SystemOutputs`, examples,
   or simulator paths.
4. Read **Engineering Standards For Agents** before making broad changes. That
   section defines how to handle ambiguity, validation, performance, package
   boundaries, and result provenance.
5. Read **Recommended Internal Model Contract** and **Target Source
   Organization** before adding new block or registry code.
6. Read **Supporting Optimization Packages** and **Optimization Formulations**
   before changing solver assembly.
7. Read **Ontology Test Strategy** before calling a feature complete.
8. Use **Implementation Roadmap** and **Definition of Done** as the staged
   delivery checklist.

If two sections appear to conflict, prefer the more specific section for the
task at hand, then update this file to remove the conflict.

## Current Starting Point

SIRENOpt already has useful foundations:

- Typed design, operation, state, and output structs for common components.
- Package adapters for PVlib, GeneratorSE, PowerConverterDynamics,
  AgnosticStorageDynamics, Hydrodynamics, Mooring, and rotor dynamics.
- A stepwise simulator through `plant_step`, `simulate_step`, and `simulate`.
- SNOW/IPOPT-facing examples and helper types for design-vector mapping.
- Short-horizon and package-backed examples that show the intended ontology
  direction.

The main gap is that optimization examples still hand-pack variable vectors,
constraints, bounds, scaling, outputs, and plots. That makes each example useful
as a proof of concept but too expensive to extend into a mid-fidelity system.

## Lean Scope For The First Usable Package

The implementation should not try to build every possible SIREN subsystem before
it becomes useful. The first usable package should make one complete workflow
straightforward:

`build -> audit -> simulate -> optimize -> replay -> report`

That workflow is the product spine. Additional physics should plug into it after
the spine is proven, not define separate one-off workflows.

| Area | V1 blocking scope | Expansion lane |
| --- | --- | --- |
| Public workflow | `describe`, `audit`, `simulate`, `optimize`, `replay`, and `report` from the same block graph | custom solver callbacks, manuscript-only scripts, and one-off plotting paths |
| Formulations | `Simulation`, `Collocation`, and `Shooting` with a small number of documented variants | general nested optimizers, arbitrary solver iteration differentiation, and unsupported formulation names |
| Components | load, bus, converter, battery/storage, solar/PV, and one package-backed wind or wave/WEC source | diesel, hydrogen, desalination, hydrokinetic, multiple buses, and multiple storage inventories |
| Dynamics | static electrical replay plus one reduced motion block or pendulum/platform fallback with force/motion ports | full 6DOF hydrodynamics, mooring, ballast, WEC PTO, and component mass/inertia coupling |
| Ontologies | three public builders: minimal electrical, package-backed hybrid, and dynamic/multilevel hybrid | `FullSIRENOptOntology` as a future alias once the smaller builders pass |
| Reports | component table, port graph, variable/residual table, model-path summary, replay CSV, and residual audit | paper-grade comparison figures and long-horizon provenance packages |
| Final proof | one fast multi-level collocation demo with explicit fallbacks for missing physics | full annual and full hydrodynamic paper-scale regressions |

The rule of thumb is: implement the shared contracts first, then add physics by
adapter. A new subsystem is in scope only when it exposes ports, variables,
residuals, outputs, model-path labels, tests, and reports through the same
interfaces as the existing blocks.

## Ontology Specification Boundary

This file uses "ontology" in a strict engineering sense: the ontology is the
typed vocabulary and validated graph that describe a hybrid system. It is not
the optimizer, not the plotting package, not a manuscript workflow, and not a
large refactor plan.

The normative ontology specification consists of:

- the core object model: blocks, variables, ports, residuals, outputs,
  scenarios, formulations, registries, and results,
- the allowed relationships between those objects,
- unit, sign, frame, time-grid, ownership, and model-path invariants,
- validation errors for invalid systems,
- standard inspection artifacts from `describe(system)` and `audit(system)`,
- at least one canonical minimal system that demonstrates the ontology end to
  end.

The architecture, roadmap, test, reporting, and agent sections support that
specification. They should not introduce new ontology terms or public objects
unless the term is also defined in the core object model below.

## Competency Questions And Required Artifacts

The ontology is useful only if it can answer concrete questions without reading
example-specific code. Every implemented ontology builder must support these
queries through `describe(system)`, `audit(system)`, generated tables, or tests.

| Question | Required artifact | Minimum acceptance |
| --- | --- | --- |
| What blocks are in the system? | component table | block name, type, model path, required/optional status |
| How are blocks connected? | port graph | source block/port, sink block/port, units, sign convention, frame where relevant |
| What are the design variables? | variable table | name, owner, role, unit, initial value, bounds, scale, vector index |
| What states and controls exist over time? | time-indexed variable table | state/control role, time grid, hold/interpolation rule, initial and terminal conditions |
| Which equations are enforced? | residual table | residual name, owner, equation label, unit, scale, lower and upper bounds, index range |
| What quantities are reported? | output table | output name, owner, unit, source equation or package adapter, report label |
| Which physics are package-backed? | model-path summary | package-backed, surrogate, placeholder, prescribed, replay-only, or smooth labels per block |
| Can the system run without an optimizer? | replay result | time-series outputs and residual audit for fixed controls |
| Can the same system become an NLP? | assembled model audit | `x0`, bounds, constraints, objective, and callback trace generated from the same block graph |
| What changed after a block was added or removed? | graph diff or audit comparison | added/removed blocks, ports, variables, residuals, outputs, and reports |

The first implementation should not be considered successful until the canonical
minimal ontology slice below can answer every question in this table.

## Core Ontology Object Model

The object model below is the source of truth for ontology implementation. Public
constructors can be more ergonomic, but the assembled system must be reducible to
these objects.

### `OntologyTemplate`

An `OntologyTemplate` names a reusable system pattern such as
`PackageBackedHybridOntology`.

Required fields:

| Field | Meaning |
| --- | --- |
| `name::Symbol` | stable Julia-facing ontology name |
| `version::VersionNumber` | ontology contract version, not package version |
| `required_blocks::Vector{BlockRole}` | block roles that must appear |
| `optional_blocks::Vector{BlockRole}` | block roles that may appear |
| `default_connections::Vector{ConnectionSpec}` | intended port graph |
| `default_scenario::ScenarioSpec` | minimal runnable scenario |
| `default_formulations::Vector{FormulationSpec}` | simulation and optimization defaults |
| `reports::Vector{ReportSpec}` | standard generated reports |

Invariants:

- every required block role has exactly one default provider or an actionable
  missing-block error,
- optional blocks can be disabled without orphaned ports, variables, residuals,
  or reports,
- repeated blocks must have stable unique names, for example `:battery_1` and
  `:battery_2`,
- every default connection must reference a declared port role.

### Supporting Spec Objects

The core objects above reference several smaller specs. These are part of the
ontology contract and should be implemented before the first public ontology
builder is treated as stable.

| Spec | Required content | Invariant |
| --- | --- | --- |
| `BlockRole` | role name, component family, required port roles, required residual roles, default provider | every required role resolves to one block or one actionable missing-provider error |
| `InterfaceSpec` | archetype name, active ports, omitted ports, zero-contribution adapters, reason, replacement target | optional capabilities are explicit and visible in audits instead of hidden in component kernels |
| `ModelPathSpec` | path label, package name where relevant, adapter name, assumptions, valid range, fallback policy | a block cannot silently fall back from package-backed to surrogate or placeholder behavior |
| `ReportSpec` | report name, required output groups, file/table target, units, aggregation rule | reports are generated from metadata and replay results, not hand-coded example columns |
| `ObjectiveSpec` | objective name, units, scale, dependencies, time/design scope, sense | objectives cannot hide hard feasibility requirements that belong in residuals |
| `ValidationReport` | errors, warnings, checked invariants, invalid object paths, suggested fixes | invalid systems fail before simulation, optimization, or expensive package construction |

### `BlockSpec`

A `BlockSpec` is the ontology-level description of one component or subsystem.
It does not own global vector indices and should not contain solver-specific
state.

Required fields:

| Field | Meaning |
| --- | --- |
| `name::Symbol` | unique block instance name within a system |
| `role::Symbol` | reusable role such as `:battery`, `:bus`, `:wind_rotor` |
| `component_type::Symbol` | broad family such as `:source`, `:storage`, `:load`, `:platform` |
| `model_path::ModelPathSpec` | package-backed, surrogate, placeholder, prescribed, replay-only, or smooth |
| `designs::Vector{VariableSpec}` | design-scope variables owned by the block |
| `states::Vector{VariableSpec}` | time-indexed state variables owned by the block |
| `controls::Vector{VariableSpec}` | time-indexed control variables owned by the block |
| `interfaces::Vector{InterfaceSpec}` | declared interface archetypes and optional capabilities |
| `ports::Vector{PortSpec}` | physical interfaces consumed or produced by the block |
| `outputs::Vector{OutputSpec}` | reportable quantities produced by the block |
| `residuals::Vector{ResidualSpec}` | hard equations or inequalities owned by the block |
| `parameters::NamedTuple` | fixed metadata and package-adapter configuration |

Invariants:

- `name` is unique in the `SystemGraph`,
- variable, output, residual, and port names are unique within the block,
- all units are explicit in field names or metadata,
- each public port belongs to a declared interface archetype or a named adapter,
- residual ownership never spans multiple blocks unless the residual is a
  designated aggregator block such as a bus balance or platform force balance,
- package-backed blocks record whether the package path was actually used.

### `PortSpec`

A `PortSpec` is a physical interface, not an implementation detail.

Required fields:

| Field | Meaning |
| --- | --- |
| `name::Symbol` | block-local port name |
| `port_type::Symbol` | one of the port types in the glossary |
| `direction::Symbol` | `:in`, `:out`, or `:inout` |
| `quantity::Symbol` | physical quantity, for example `:power`, `:force`, `:motion_state` |
| `unit::String` | canonical unit at the port boundary |
| `sign_convention::String` | concise sign statement |
| `frame::Union{Nothing,Symbol}` | frame for motion, force, moment, and inertia ports |
| `reference_point::Union{Nothing,Symbol}` | moment or wrench reference point where relevant |
| `time_grid::Symbol` | scenario time grid or `:design` for static quantities |
| `cardinality::Symbol` | `:one`, `:many_to_one`, `:one_to_many`, or `:optional` |
| `owner::Symbol` | owning block name |

Invariants:

- every connection links an `:out` or `:inout` port to an `:in` or `:inout` port,
- units must match exactly or name one conversion owner,
- force and moment ports must define frame and reference point,
- a many-to-one connection must name the aggregation residual owner.

### `ConnectionSpec`

A `ConnectionSpec` is a validated edge between two ports. It owns conversion,
aggregation, and resampling metadata for the edge so that component equations do
not hide system-level wiring assumptions.

Required fields:

| Field | Meaning |
| --- | --- |
| `source_block::Symbol` | block that produces the upstream quantity |
| `source_port::Symbol` | source block-local port name |
| `sink_block::Symbol` | block that consumes the quantity |
| `sink_port::Symbol` | sink block-local port name |
| `quantity::Symbol` | physical quantity crossing the edge |
| `unit::String` | canonical edge unit after any declared conversion |
| `conversion_owner::Union{Nothing,Symbol}` | block or adapter that owns unit/frame conversion |
| `aggregation_owner::Union{Nothing,Symbol}` | residual owner for many-to-one connections |
| `resampling_owner::Union{Nothing,Symbol}` | owner of hold/interpolation between time grids |
| `active::Bool` | whether the edge is active in the current graph |
| `disabled_reason::Union{Nothing,String}` | reason an optional edge is disabled |

Invariants:

- inactive optional edges are reported, not silently retained as zero-valued
  hidden connections,
- unit, frame, and time-grid conversion can occur only at a named owner,
- many-to-one connections name exactly one aggregation owner,
- every audit table can print an owner-qualified edge such as
  `solar_converter.bus_power_kw -> bus.source_power_kw`.

### `VariableSpec`

`VariableSpec` covers designs, states, controls, algebraic helper variables,
slacks, and diagnostics.

Required fields:

| Field | Meaning |
| --- | --- |
| `name::Symbol` | block-local variable name |
| `owner::Symbol` | block name |
| `role::Symbol` | `:design`, `:state`, `:control`, `:algebraic`, `:slack`, or `:diagnostic` |
| `unit::String` | canonical unit |
| `initial` | initial value or initialization rule |
| `lower` | lower bound or `-Inf` |
| `upper` | upper bound or `Inf` |
| `scale` | positive finite solver/report scale |
| `time_scope::Symbol` | `:design`, `:node`, `:interval`, or `:scenario` |
| `exposure::Symbol` | `:parameter`, `:decision`, `:computed`, or `:reported` |
| `label::String` | human-readable report label |

Invariants:

- `lower <= initial <= upper` when the value is finite,
- `scale` is positive and finite,
- `:decision` variables appear in the registry exactly once per declared scope,
- `:computed` variables cannot be directly controlled by the optimizer.

### `ResidualSpec`

`ResidualSpec` describes equations and inequalities that can be audited and, when
appropriate, assembled into an NLP.

Required fields:

| Field | Meaning |
| --- | --- |
| `name::Symbol` | block-local residual name |
| `owner::Symbol` | block that writes the residual |
| `equation::Symbol` | stable equation label |
| `sense::Symbol` | `:eq`, `:leq`, `:geq`, or `:interval` |
| `unit::String` | residual unit |
| `scale` | positive finite scaling value |
| `lower` | lower residual bound |
| `upper` | upper residual bound |
| `time_scope::Symbol` | `:node`, `:interval`, `:terminal`, or `:design` |
| `depends_on::Vector{Symbol}` | owner-qualified variable or port names |
| `hardness::Symbol` | `:hard`, `:smooth`, or `:replay_only` |
| `label::String` | human-readable audit label |

Invariants:

- hard physical balances use residual constraints, not objective penalties,
- smooth residuals name the smoothing parameter and hard replay check,
- every assembled constraint index is written exactly once,
- every residual maps back to one equation owner and one time/design scope.

### `OutputSpec`

`OutputSpec` describes a reportable value. Outputs may be computed during
simulation, replay, or optimization callback evaluation, but reports must say
which path produced them.

Required fields:

| Field | Meaning |
| --- | --- |
| `name::Symbol` | block-local output name |
| `owner::Symbol` | producing block |
| `unit::String` | report unit |
| `source::Symbol` | kernel, adapter, residual, or replay source |
| `model_path::ModelPathSpec` | path that produced the value |
| `time_scope::Symbol` | `:design`, `:node`, `:interval`, or `:summary` |
| `label::String` | report/plot label |
| `plot_group::Union{Nothing,Symbol}` | standard plot group |

Invariants:

- report columns are generated from `OutputSpec`, not hand-coded labels,
- replay-only outputs cannot be described as NLP constraints,
- package-backed outputs name the adapter and package.

### `SystemGraph`

A `SystemGraph` is the assembled ontology instance.

Required fields:

| Field | Meaning |
| --- | --- |
| `ontology::OntologyTemplate` | template that built the graph |
| `blocks::Vector{BlockSpec}` | block instances |
| `connections::Vector{ConnectionSpec}` | validated port connections |
| `scenario::ScenarioSpec` | resources, demands, time grids, initial conditions |
| `validation::ValidationReport` | warnings and errors from graph construction |

Invariants:

- graph validation passes before simulation or optimization assembly,
- disabled optional blocks remove their connections and dependent residuals,
- graph diffing can identify added, removed, and changed blocks, ports,
  variables, residuals, and outputs.

### `ScenarioSpec`

A `ScenarioSpec` owns data that varies between cases without changing the system
topology.

Required fields:

| Field | Meaning |
| --- | --- |
| `name::Symbol` | scenario identifier |
| `time_grids::NamedTuple` | named grids with unit, start, stop, and step |
| `resources::NamedTuple` | wind, solar, wave, weather, current, or other data |
| `demands::NamedTuple` | electrical, water, hydrogen, and other demands |
| `initial_states::NamedTuple` | physically valid initial state values |
| `prescribed_controls::NamedTuple` | optional prescribed controls |
| `provenance::NamedTuple` | file paths, hashes, generator names, and notes |

Invariants:

- every time-varying port names a scenario time grid,
- interpolation and hold rules are explicit,
- units are converted at scenario or adapter boundaries, not inside unrelated
  block equations.

### `FormulationSpec`

A `FormulationSpec` says how the block graph becomes a simulation or
optimization problem.

Required fields:

| Field | Meaning |
| --- | --- |
| `name::Symbol` | formulation name |
| `mode::Symbol` | public mode: `:simulation`, `:collocation`, or `:shooting` |
| `variant::Union{Nothing,Symbol}` | optional implementation variant such as `:single`, `:multiple`, `:trapezoidal`, or `:hermite_simpson` |
| `time_grid::Symbol` | scenario grid used for assembly |
| `exposed_roles::Vector{Symbol}` | variable roles exposed as decisions |
| `defect_method::Union{Nothing,Symbol}` | explicit Euler, backward Euler, trapezoidal, implicit midpoint, Hermite-Simpson, shooting continuity, etc. |
| `objective::ObjectiveSpec` | objective definition and units |
| `replay_rules::NamedTuple` | how optimized controls are replayed |

Invariants:

- formulation changes variable exposure and defect construction, not physics
  equations,
- `:collocation` is the public direct-transcription mode; direct transcription
  is the implementation family, while collocation is the user-facing choice,
- `:shooting` may use `variant = :single` or `variant = :multiple` internally,
- every decision variable and constraint is registry-backed,
- retained implicit solves are block-level implementation details, not a fourth
  public formulation mode,
- replay rules are defined before accepting a solver result.

### `AssemblyRegistry`

The registry is the bridge between ontology objects and solver vectors.

Required fields:

| Field | Meaning |
| --- | --- |
| `variables` | ordered registry entries for `x` |
| `residuals` | ordered registry entries for `con` |
| `outputs` | reportable output entries |
| `ports` | connected port entries |
| `trace` | lookup from vector index to owner, quantity, unit, and time/design index |

Invariants:

- variable and residual ordering is deterministic for identical inputs,
- every entry has owner, role, unit, scale, label, and index range,
- packing and unpacking one representative vector is lossless.

### `ResultSpec`

A result is accepted only after replay and reporting metadata exist.

Required fields:

| Field | Meaning |
| --- | --- |
| `system_hash` | hash or digest of the validated system graph |
| `scenario_hash` | hash or digest of input data/provenance |
| `formulation` | formulation name and options |
| `solver` | solver name, options, and status |
| `registry` | variable and residual trace tables |
| `replay_summary` | residual and feasibility checks from replay |
| `reports` | generated CSV, table, and figure paths |
| `model_paths` | block-level model-path summary |

Invariants:

- a solver status alone is not a valid result,
- replay residuals must be reported for optimization results,
- manuscript-facing results must point to generated files.

## Current Code Migration Bridge

The current package already contains useful typed structs and simulator
functions. The ontology layer should wrap and reuse them rather than replacing
them in one large step.

| Current object | Ontology role | Migration rule |
| --- | --- | --- |
| `SystemDesign` | compatibility configuration for default block designs | convert each field into one or more `BlockSpec.designs` and block parameters |
| `SystemOperation` | compatibility configuration for resources, demands, controls, and package options | convert time-series data into `ScenarioSpec` and operation options into block parameters |
| `SystemState` | replay state container | map fields into state `VariableSpec`s and replay snapshots |
| `SystemOutputs` | legacy output snapshot | map fields into `OutputSpec`s and standard time-series report columns |
| `ControlSetpoints` | prescribed controls or controller outputs | map fields into control `VariableSpec`s or prescribed scenario controls |
| `SnowProblem` and `DesignVarSpec` | expert optimization compatibility layer | implement as an adapter around `AssemblyRegistry`, not a separate ontology |
| `plant_step` and `simulate` | current replay kernels | keep as compatibility paths until block-level replay produces equivalent outputs |

Migration constraints:

- Do not remove the current structs until at least one ontology builder can
  produce equivalent replay outputs.
- New block code should expose the same physical quantities already visible in
  `SystemOutputs` before adding new report names.
- Compatibility examples may keep using current structs, but migrated examples
  must report the generated block graph, registry, residual audit, and model
  paths.
- Any field with type `Any` in a public or AD-sensitive path needs an explicit
  model-path or adapter boundary before it is used inside optimization assembly.

## Canonical Minimal Ontology Slice

The first complete ontology slice is a small electrical system:

```text
solar_resource -> solar_array -> solar_converter -> bus <- load
                                             bus <-> battery_converter <-> battery
```

This slice intentionally excludes platform dynamics, wind, wave, hydrogen,
desalination, diesel, and package-backed weather details. Its purpose is to
prove the ontology machinery.

### Required Blocks

| Block | Role | Required ports | Required residuals | Required outputs |
| --- | --- | --- | --- | --- |
| `solar_resource` | resource provider | `resource_state:out` | none | irradiance/resource value |
| `solar_array` | source | `resource_state:in`, `device_electrical:out` | available power cap | device power |
| `solar_converter` | converter | `device_electrical:in`, `bus_electrical:out` | converter loss relation, rating limit | bus power, loss |
| `battery` | storage | `storage_state:out`, `device_electrical:inout`, `control_signal:in` | SOC inventory, SOC bounds, charge/discharge limits | SOC, device power |
| `battery_converter` | bidirectional converter | `device_electrical:inout`, `bus_electrical:inout` | converter loss relation, rating limit | bus power, loss |
| `load` | demand | `demand_profile:in`, `bus_electrical:in` | served-load fraction bounds | load power |
| `bus` | electrical aggregator | `bus_electrical:inout` many-to-one | bus power balance | residual, voltage basis |

### Required Variables

| Role | Variables |
| --- | --- |
| designs | `solar_area_m2`, `solar_converter_rating_kw`, `battery_capacity_kwh`, `battery_power_kw`, `load_converter_rating_kw` |
| states | `battery_soc` at each state node |
| controls | `solar_curtailment`, `battery_command_kw`, `load_served_fraction` on each control interval |
| computed outputs | `solar_device_power_kw`, `solar_bus_power_kw`, `battery_bus_power_kw`, `load_bus_power_kw`, `bus_balance_residual_kw` |

### Required Residuals

| Residual | Sense | Unit | Owner | Notes |
| --- | --- | --- | --- | --- |
| `bus_power_balance` | equality | `kW` | `bus` | sum of bus injections, storage power, load, and losses |
| `battery_inventory` | equality | `kWh` or fraction | `battery` | next SOC minus integrated command with efficiency |
| `solar_available_limit` | inequality | `kW` | `solar_array` | realized solar power below available resource and rating |
| `converter_rating_limits` | inequality | `kW` | converter blocks | device and bus power within ratings |
| `load_served_bounds` | interval | fraction | `load` | between critical minimum and one |

### Required `describe(system)` Content

`describe(system)` for this slice must print or return:

- ontology name and version,
- block table with the seven blocks above,
- each block's model path,
- design defaults and bounds,
- scenario time grid and resource/demand units,
- default formulation names.

### Required `audit(system)` Content

`audit(system)` for this slice must print or return:

- connection table for every port edge,
- variable table with deterministic indices for one collocation
  assembly,
- residual table with deterministic indices, units, scales, and bounds,
- output table with report labels,
- validation status and any warnings.

### Acceptance Tests For The Slice

The minimal slice is accepted only when:

1. it can be built without manual vector indexing,
2. disabling the battery removes battery ports, states, controls, residuals, and
   reports without orphaned entries,
3. a one-step fixed-control replay closes bus and battery residuals within a
   declared tolerance,
4. a tiny collocation optimization assembles `x0`, bounds, constraints,
   and callback trace from the registry,
5. optimized controls replay through the same block equations.

## Target Architecture

The target architecture is a block-based system assembly layer.

Each component block should declare:

- `designs`: size, rating, geometry, cost, mass, volume, and model choices.
- `states`: SOC, fuel, tank levels, platform pose, rotor wake state, etc.
- `controls`: dispatch, curtailment, converter command, pitch, load shedding.
- `inputs`: resources, bus voltage, platform motion, load demand, upstream ports.
- `outputs`: bus power, device power, voltage, current, forces, moments, mass,
  cost, resource use, residual diagnostics.
- `ports`: named connection points with direction, unit, frame, and owner block.
- `residuals`: balance equations, dynamics defects, inventory updates, component
  limits, path constraints, terminal constraints.
- `metadata`: units, default scaling, human label, plotting group, solver role,
  and whether the block is differentiable, algebraic, dynamic, or black-box.

Blocks compose through their ports. A block should not need to know which
ontology it is in; it should declare the quantities it can consume and produce,
and the ontology should wire those ports into force, motion, energy, storage,
and control pathways. The ontology builder is therefore a graph assembly tool,
not a second implementation of the component physics.

For example, a wind turbine block may declare:

- inputs: wind resource, platform pose and velocity, rotor speed or generator
  torque command, pitch/yaw commands,
- states: rotor wake state, rotor speed when dynamic, pitch or yaw actuator
  states where modeled,
- outputs: aerodynamic thrust force, hub moment, shaft torque, shaft mechanical
  power, rotor loads, mass, cost, and operating limits,
- residuals: rotor/wake defects, actuator defects, torque-speed consistency,
  rating limits, and load constraints.

Those ports then connect to other blocks:

- wind thrust and hub moment connect to the platform motion block,
- platform pose and velocity connect back to wind, WEC, PV, and mooring blocks,
- shaft mechanical power connects to a generator block,
- generator electrical output connects to converter and bus blocks,
- bus power connects to battery, load, hydrogen, desalination, or dump-load
  blocks,
- component mass and inertia connect to platform mass and motion blocks,
- mooring, hydrodynamic, WEC, and wind loads all contribute to the platform
  force/moment residual.

The same block should be reusable in different ontologies. A low-fidelity energy
ontology may use only `wind_speed_m_s -> bus_power_kw`; a dynamic floating
ontology may additionally connect platform motion, thrust, moments, mass, and
rotor wake state. The port contract must make both uses explicit without
changing the block equations.

Simulation and optimization should use the same block equations. The difference
should be only how variables are exposed:

- In simulation, controls come from a controller or prescribed time series.
- In optimization, selected designs, controls, and states become decision
  variables, and block residuals become constraints.

### Composable Interface Strategy

SIRENOpt owns the composable interface layer between subsystem packages. A
subpackage can expose whatever native API makes sense for its physics; SIRENOpt
wraps that package in blocks, ports, outputs, residuals, and metadata that can be
assembled into an ontology.

Do not force every component to implement one giant universal interface. Use a
small number of interface archetypes and compose blocks by capability. A block
should declare the ports it physically supports, and the ontology should connect
only compatible ports. When an ontology needs a common aggregation shape, such as
a dense platform wrench sum or a dense bus-power table, it may insert an explicit
zero-contribution adapter. That adapter must be visible in `describe(system)`,
`audit(system)`, reports, and model-path/provenance metadata.

Example: a solar/PV block normally exposes irradiance/resource input,
device-side electrical power, converter or bus power, area, mass, and cost. It
may consume platform attitude if PV orientation or motion derates are active. It
usually does not produce aerodynamic or hydrodynamic force. In a dynamic
floating ontology, the graph should either omit solar from the
`platform_wrench` aggregation or insert an explicit `zero_platform_wrench`
adapter for the solar block. The zero adapter returns exactly zero force and
moment, names the frame and reference point, and reports that the contribution is
not applicable rather than package-backed physics.

Interface archetypes:

| Archetype | Required ports | Optional ports | Typical blocks |
| --- | --- | --- | --- |
| `resource_provider` | `resource_state:out` or `demand_profile:out` | provenance outputs | weather, solar resource, wave state, load profile |
| `electrical_source` | `resource_state:in`, `device_electrical:out` or `bus_electrical:out` | `control_signal`, `motion_state`, `mass_inertia`, `platform_wrench` | PV, hydrokinetic source, simplified wind/wave source |
| `mechanical_prime_mover` | `resource_state:in`, `shaft_mechanical:out` | `motion_state`, `platform_wrench`, `control_signal`, `mass_inertia` | wind rotor, WEC/PTO, hydrokinetic rotor |
| `converter_or_generator` | one upstream electrical or shaft port, one downstream electrical port | loss outputs, rating controls | generator, rectifier, inverter, DC/DC converter |
| `storage` | `storage_state`, `device_electrical:inout` or `bus_electrical:inout` | `control_signal`, thermal/process ports, `mass_inertia` | battery, fuel tank, hydrogen tank, water tank |
| `load_or_process` | `demand_profile:in`, `bus_electrical:in` | `thermal_or_process`, inventory outputs, shed controls | electrical load, desalination, hydrogen production |
| `motion_dynamic` | `motion_state:out`, one or more `platform_wrench:in` | `mass_inertia`, mooring/hydrodynamic states | pendulum platform, 3DOF/6DOF platform |
| `force_or_mass_contributor` | `platform_wrench:out` or `mass_inertia:out` | `motion_state`, controls | wind loads, WEC loads, mooring, ballast, mounted equipment |
| `aggregator` | many compatible inputs | residual outputs, audit outputs | bus balance, platform wrench balance, mass/cost balance |
| `zero_contribution_adapter` | one typed zero output port | source block reference, reason, replacement target | solar no-force adapter, disabled source/load placeholders |

Rules:

- Absence is valid. If a block does not physically produce a port, it should not
  fake one inside the component kernel.
- Zero contribution is explicit. If a zero force, zero mass, zero loss, or zero
  power contribution is needed for table shape or aggregation, create a named
  adapter or disabled edge that reports why the contribution is zero.
- Aggregators own sums. Bus, platform, mass, and cost aggregators combine
  contributions; source blocks expose their local quantities.
- Wrappers own translation. SIRENOpt adapters translate package-native outputs
  into ontology ports, units, signs, frames, and residuals.
- Optional capability is inspected. `audit(system)` should show which optional
  interfaces are active, omitted, disabled, or supplied by a zero-contribution
  adapter.

## Common Ontologies

SIRENOpt should provide a small number of named prebuilt ontologies. These are
templates, not separate model implementations. Keep the public set small enough
that a user can choose by workflow rather than by memorizing a catalog of
subsystem combinations.

| Ontology | Public role | V1 required blocks | Expansion hooks | Minimum acceptance fixture |
| --- | --- | --- | --- | --- |
| `MinimalEnergyOntology` | smallest end-to-end block graph and smoke test | source or prescribed generation, load, bus, converter where needed, battery/storage | additional simple sources, diesel fallback, inventory variants | forward replay and tiny optimization generate component, port, variable, residual, model-path, and replay reports |
| `PackageBackedHybridOntology` | package-backed energy studies with replaceable physics | PV/solar, one wind or wave/WEC source, generator/converter stages, battery/storage, load, bus | wind plus wave together, hydrokinetic, diesel, hydrogen, desalination, site resource variants | package-backed and surrogate variants run through the same graph, solve a tiny collocation case, replay, and report model paths |
| `DynamicMultilevelHybridOntology` | motion-coupled and multi-level optimization proof | package-backed hybrid blocks plus reduced platform or pendulum motion, force/moment ports, and dynamic defects | hydrodynamics, mooring, WEC PTO, full platform states, component mass/inertia, Level 2/Level 3 maps | force changes motion, motion changes at least one source/load path, and the fast multi-level demo reports all substitutions |

Keep these names as the first public API target. More specific names can exist as
thin aliases or configured variants when they reduce user friction, but they
should compile to one of the three builders above. For example,
`WindWaveSolarBatteryOntology` can be a convenience alias for
`PackageBackedHybridOntology(kind = :wind_wave_solar_battery)` rather than a
separate implementation.

Comparison and future lanes should be explicit:

- `SIRENOLiteOntology` is a comparison fixture for fixed SIRENO-lite-equivalent
  inputs, not the main SIRENOpt workflow. Use "SIRENO-lite" in paper text and
  comparison prose when referring to the external/reference model.
- `FullSIRENOptOntology` is a future expansion alias once the smaller builders
  pass. It should not be a V1 blocker.

Each ontology must define:

- required blocks and their roles,
- optional blocks and the disabling behavior for each optional block,
- default block names and repeated-block naming rules,
- the port connection graph and required force, motion, energy, storage, and
  control pathways,
- default units, signs, frames, reference points, and time grids,
- default residual scaling and constraint bounds,
- default reports and plots generated from metadata,
- default simulation and optimization formulations,
- a minimal scenario that can run quickly in tests,
- model-path defaults and fallback rules.

### Named Ontology Acceptance Tables

Before an ontology template is treated as public API, it needs a small acceptance
table checked into documentation or tests. The table must include:

| Required item | What it must say |
| --- | --- |
| component inventory | required, optional, disabled, and repeated blocks |
| graph inventory | every default port connection and aggregation owner |
| variable inventory | design, state, control, algebraic, slack, and diagnostic variables |
| residual inventory | equality, inequality, path, terminal, and replay-only checks |
| model-path inventory | package-backed, surrogate, placeholder, prescribed, smooth, and replay-only paths |
| default scenario | time grids, resources, demands, initial states, and prescribed controls |
| default reports | component table, port graph, variable/residual table, time series, residual audit, plots |
| acceptance commands | smallest simulation, optimization, replay, and report commands |

An ontology row in the summary table above is not sufficient by itself. The
template is incomplete until this acceptance table exists and passes.

### Port Type Glossary

Port names should describe physical interfaces, not implementation details. When
a new block is added, choose the closest existing port type before inventing a
new one. If a new port type is needed, add it to this table and give it units,
sign convention, frame, and a minimal compatibility test.

| Port type | Typical direction | Required metadata | Connects |
| --- | --- | --- | --- |
| `resource_state` | resource block to source block | resource name, units, time index, interpolation rule | wind, solar, wave, current, weather data |
| `demand_profile` | demand data block to load/process block | demand name, units, time index, hold/interpolation rule, critical-load policy | electrical load, water demand, hydrogen demand, process demand |
| `motion_state` | platform block to motion-sensitive blocks | DOF order, position/velocity units, frame, reference point | wind, PV, WEC, mooring, hydro, load paths affected by motion |
| `platform_wrench` | load-producing block to platform block | force units, moment units, frame, reference point, sign convention | wind thrust, WEC/PTO load, mooring, hydrodynamics, payload loads |
| `shaft_mechanical` | prime mover to generator/PTO block | torque, speed, power, rotational sign, rating limit | rotor to generator, WEC PTO to generator |
| `device_electrical` | device or generator to converter | voltage/current or power units, AC/DC flag, efficiency owner | PV DC output, generator output, storage device side |
| `bus_electrical` | converter/source/storage/load to bus | bus name, power sign, voltage basis, loss accounting | electrical balance, storage dispatch, load serving, curtailment |
| `storage_state` | storage block to controller/reporting | inventory units, bounds, update time base, efficiency convention | battery SOC, fuel tank, hydrogen tank, water tank |
| `control_signal` | controller/optimizer to controlled block | control units, bounds, rate limits, hold/interpolation rule | pitch, torque, dispatch, curtailment, PTO damping, load shed |
| `mass_inertia` | component to platform or cost block | mass, center of mass, inertia tensor/frame, design dependency | platform dynamics, structural sizing, cost/mass reports |
| `thermal_or_process` | process block to sink/source block | flow, temperature or production units, conversion efficiency | desalination, hydrogen, waste heat, auxiliary loads |

Port compatibility is a validation problem, not an example-level convention. A
connection should fail before simulation or optimization if direction, units,
frame, reference point, time grid, or sign convention are missing or incompatible.

### Port Validation Semantics

Port validation should be deterministic and should run before any package-backed
model construction that is expensive or irreversible.

Required validation rules:

- Direction: an output may connect to an input; an input may not drive another
  input; `:inout` is allowed only for explicitly bidirectional ports such as
  battery device power or bus power.
- Cardinality: one-to-one connections are the default. Many-to-one connections
  require an aggregation residual owner, for example `bus_power_balance` or
  `platform_wrench_balance`.
- Units: connected ports must share canonical units or name exactly one
  conversion owner. Hidden unit conversion inside unrelated component equations
  is invalid.
- Signs: every connected power, current, force, moment, and command port must
  declare the sign convention from the perspective of the receiving residual.
- Frames and reference points: motion, force, moment, wrench, and inertia ports
  must name frame and reference point. A frame transform must be a named block or
  adapter, not an implicit convention.
- Time grids: connected time-varying ports must share a grid or name a
  resampling owner with hold/interpolation rules.
- Repeated blocks: repeated roles must use unique block names and owner-qualified
  port names in audits, for example `battery_1.bus_power_kw`.
- Optional blocks: disabling a block removes its ports and dependent residuals;
  it must not leave a zero-valued hidden connection unless the ontology
  explicitly reports a disabled placeholder.
- Aggregators: bus, platform, mass, and cost aggregators own the residuals that
  combine many contributors. Source blocks should expose contributions, not write
  global balances.

Validation errors should include:

- ontology name,
- block name,
- port name,
- expected direction/unit/frame/time grid,
- received direction/unit/frame/time grid,
- suggested owner for conversion or aggregation when obvious.

Minimal invalid fixtures:

- connect a `kW` bus port to a `W` bus port without a converter,
- connect an inertial-frame force to a body-frame platform residual without a
  transform,
- remove a battery while leaving its SOC residual registered,
- connect two outputs directly,
- use two blocks with the same name,
- connect two different time grids without a resampling rule.

## Recommended Internal Model Contract

The core contract should be small and explicit.

```julia
abstract type AbstractSIRENBlock end

block_name(block)::Symbol
design_variables(block, ctx)::Vector{VariableSpec}
state_variables(block, ctx)::Vector{VariableSpec}
control_variables(block, ctx)::Vector{VariableSpec}
ports(block, ctx)::Vector{PortSpec}
outputs(block, ctx)::Vector{OutputSpec}
residuals(block, ctx)::Vector{ResidualSpec}

evaluate!(cache, block, ctx, vars)
residual!(r, block, ctx, vars, cache)
record!(table, block, ctx, vars, cache)
```

This keeps the performance-sensitive path close to ordinary Julia functions.
The block graph and human-readable wrappers can be richer, but the numerical
kernel should remain simple and inspectable.

## Target Source Organization

The code should be organized so users see simple ontology builders while
developers can find the corresponding specs, blocks, adapters, and formulations
without guessing.

Suggested organization:

```text
src/
  SIRENOpt.jl
  specs/
    variables.jl
    residuals.jl
    outputs.jl
    ports.jl
    metadata.jl
  blocks/
    solar.jl
    wind.jl
    wave.jl
    battery.jl
    bus.jl
    platform.jl
    mooring.jl
    production.jl
  adapters/
    pvlib.jl
    unsteady_kinetic.jl
    generatorse.jl
    power_converter.jl
    storage.jl
    hydrodynamics.jl
  ontologies/
    sireno_lite.jl
    package_backed_energy.jl
    wind_wave_solar_battery.jl
    dynamic_floating_hybrid.jl
    full_sirenopt.jl
  formulations/
    direct_transcription.jl
    shooting.jl
    implicit_blocks.jl
    snow_callback.jl
  reporting/
    tables.jl
    plots.jl
    provenance.jl
  validation/
    system_validation.jl
    unit_checks.jl
    diagnostics.jl
```

The existing flat source layout can evolve toward this gradually. Do not move
files just to match the tree. Move code when there is a tested block, adapter,
ontology, or formulation boundary that benefits from the separation.

## Preferred Coding Principles

Use a human-readable style first, but avoid patterns that make AD and solver
assembly fragile.

- Prefer explicit structs and named fields over opaque positional vectors.
- Prefer `NamedTuple` outputs for small component snapshots.
- Keep units in field names or metadata, not only in comments.
- Keep residual equations close to the physics.
- Use typed specs for variables, bounds, scaling, and units.
- Keep package-specific calls behind SIRENOpt adapters or component blocks.
- Avoid large macros in the first implementation pass.
- Avoid `Dict{String,Any}` in numerical kernels; use it only for reports.
- Use smooth functions only where differentiability requires them; keep hard
  physical feasibility as explicit constraints.
- Provide a low-level API that can be tested without a solver.
- Build optimization problems from the same blocks used by simulation.

## Engineering Standards For Agents

This file should let future agents make consistent implementation decisions
without relying on unstated assumptions. When a choice affects physics, public
API, solver behavior, data products, or paper claims, the choice should be made
explicit in code metadata, tests, or a short design note.

### Ambiguity Handling

Agents should not silently guess when a modeling choice changes the meaning of a
result. The expected workflow is:

1. Read the local code and examples that define the current convention.
2. Prefer existing SIRENOpt conventions when they are clear.
3. If no convention exists, choose the simplest physically defensible option and
   document it near the block, ontology, or design record.
4. Ask for input only when competing choices would materially change results,
   comparisons, or paper claims.
5. Add a test that would fail if the convention is accidentally reversed later.

Choices that must be explicit:

- sign convention for power, load, force, moment, current, and storage command,
- units and time base for every state update,
- coordinate frame for platform positions, velocities, forces, and moments,
- whether a model path is package-backed, surrogate, prescribed, or replay-only,
- whether a constraint is a hard residual or a smooth approximation,
- whether a dynamic example is one-way prescribed motion or two-way coupled
  motion,
- whether a solver result has been replayed after optimization.

### Model Path Vocabulary

Use the same words consistently in code, reports, examples, and paper text.

| Term | Meaning | Required metadata |
| --- | --- | --- |
| package-backed | calls a subsystem package for the relevant physics | package name, adapter name, key assumptions |
| surrogate | simplified SIRENOpt-level approximation of a higher-fidelity model | surrogate name, replaced model, valid range |
| placeholder | temporary implementation used only while an interface is being built | explicit warning, replacement target |
| prescribed | externally imposed time history, not solved by SIRENOpt dynamics | source file or generator, affected variables |
| replay-only | evaluated after optimization for diagnostics, not part of NLP feasibility | replay command, residual summary |
| hard residual | equality or inequality constraint enforced by the optimizer | residual owner, units, scale, bounds |
| smooth approximation | differentiable approximation used for optimization | smoothing parameter, hard replay check |

Do not describe a surrogate or prescribed path as package-backed physics. Do not
describe replay-only diagnostics as constraints. Do not describe one-way
prescribed motion as two-way coupling.

#### Model Provenance Rule

Every public example, report, plot caption, and paper-facing result must declare
what produced each major model quantity. The declaration should be attached to
result metadata first and prose second.

Use this rule when writing or reviewing examples:

- If a quantity comes from a subsystem package, name the package and adapter.
  Example: "wind loads: package-backed
  UnsteadyKineticRotorDynamics via SIRENOpt wind adapter".
- If a quantity is computed by SIRENOpt with simplified equations, label it as a
  SIRENOpt surrogate and name the higher-fidelity model it is replacing.
- If a quantity is imposed from a file or analytic time history, label it
  prescribed and name the affected states or ports.
- If a quantity is computed only after the optimizer finishes, label it
  replay-only and keep it out of NLP feasibility claims.
- If a smooth approximation replaces a hard physical switch, state the smoothing
  parameter and include a hard replay or limit check.

Done means: a reader can inspect a result table or log and know, block by block,
whether PV, wind, WEC, storage, generator, converter, platform, mooring,
hydrodynamic, load, hydrogen, and desalination quantities were package-backed,
surrogate, prescribed, replay-only, or smooth approximations.

### Decision Records

For decisions that affect more than one file, add a short design record. A full
architecture-decision process is not required, but the record should be easy to
find and review. Suitable locations are `docs/design/` for persistent decisions
or a section in this file for early-stage choices.

Recommended design-record template:

```markdown
Decision: <short name>

Status: proposed | accepted | superseded
Date: YYYY-MM-DD

Context:
- What problem forced this decision?
- Which files, examples, or paper claims are affected?

Decision:
- What convention or implementation path is selected?

Alternatives considered:
- What was rejected and why?

Verification:
- Which tests, examples, or paper outputs prove this works?

Revisit when:
- What evidence would justify changing this decision?
```

Design records are required for:

- global sign or unit conventions,
- changing the registry, block, or public ontology API,
- selecting a default optimization formulation,
- replacing a package-backed model with a surrogate,
- adding a new dependency to core `Project.toml`,
- changing generated paper results or comparison baselines.

### Units, Signs, And Frames

SIRENOpt should be readable without forcing every user to inspect package
internals. Units and signs therefore need to be visible at the SIRENOpt level.

Default conventions:

- electrical source injection is positive on the bus,
- demand/load is negative on the bus,
- curtailment is a nonnegative reduction of available generation,
- battery discharge to the bus is positive and charging from the bus is
  negative,
- energy inventories are stored in physical units such as `kWh`, `kg`, or
  `m^3`,
- motion dynamics use seconds and SI force/moment units,
- energy and storage accounting may use hours only where field names or metadata
  explicitly say `dt_hours`,
- moments must declare the point and frame used for the lever arm,
- platform states must declare DOF ordering and frame.

Implementation rules:

- Put units in field names for user-facing structs when practical, for example
  `power_kw`, `force_n`, `moment_nm`, `dt_s`, and `capacity_kwh`.
- Put units in `VariableSpec`, `ResidualSpec`, `OutputSpec`, and report
  metadata.
- Convert units once at subsystem boundaries, not repeatedly inside equations.
- Never mix `dt_s` and `dt_hours` in a kernel without an explicit conversion.
- Every sign convention should have at least one small test with a value whose
  expected sign is obvious.

### Proposed Public API Contract

The public API should stay small, stable, and readable. The names in this
section are proposed contracts, not finalized exported names, until an
implementation and tests exist.

```julia
system = PackageBackedHybridOntology(kind = :wind_wave_solar_battery, ...)
scenario = ShortHorizonScenario(...)

sim = simulate(system, scenario; controller = RuleBasedController())
opt = optimize(system, scenario; formulation = Collocation(method = :trapezoidal))
report(opt)
```

Public user code should not require:

- manual global index arithmetic,
- direct construction of package-internal models for common cases,
- direct mutation of solver caches,
- knowledge of SNOW callback internals unless using the expert API,
- editing plots or CSVs by hand after a run.

The expert API is allowed to expose vectors, callbacks, and solver options, but
it must still use the same registry and block equations as the public API.

Proposed public names used in examples must have these contracts before they
appear in user-facing documentation:

| Public name | Contract |
| --- | --- |
| `Design(lower, upper; initial, unit, scale)` | declares a design variable and maps to one `VariableSpec` with role `:design` |
| `TimeGrid(; horizon_s, dt_s)` | declares a named scenario grid in seconds; hourly grids must use a distinct constructor or explicit unit |
| `ShortHorizonScenario` | builds a `ScenarioSpec` with resource data, demand data, initial states, and provenance |
| `Simulation` | builds a replay-only `FormulationSpec` for fixed controls and residual audits |
| `Collocation` | builds a `FormulationSpec` with exposed states/controls and dynamic defects |
| `Shooting` | builds a `FormulationSpec` that obtains states from a simulator or package integrator inside the callback |
| `RuleBasedController` | provides simulation controls without exposing those controls as NLP decisions |
| `SNOWIpopt` | solver wrapper that consumes an assembled registry-backed callback |
| `MinimizeTotalCost`, `MinimizeCostPerWatt`, other objectives | produce `ObjectiveSpec` with units, scale, and dependencies |
| `describe(system)` | returns component, default, scenario, and formulation summaries without assembling an NLP |
| `audit(system)` | returns block graph, port, variable, residual, output, validation, and model-path tables |
| `assemble(system, scenario, formulation, objective)` | returns a registry-backed model with `x0`, bounds, constraints, callback trace, and replay rules |
| `solve(model, optimizer)` | runs the optimizer and returns a result that is not accepted until replay metadata exists |
| `report(result, path)` | writes standard reports from metadata and replay outputs |

If a public example uses one of these proposed names before the corresponding
contract is implemented, the example must be marked as pseudocode or moved to an
architecture note instead of user-facing documentation.

### Package Adapter Policy

SIRENOpt is the ontology and integration layer; subsystem packages own detailed
physics. Adapters should make this boundary explicit.

Adapter rules:

- Package-specific calls should live behind SIRENOpt adapter functions or block
  implementations.
- Examples should prefer SIRENOpt-facing constructors unless the example is
  specifically teaching adapter development.
- Fallback surrogate models are allowed only when they are named and reported as
  surrogates.
- A package-backed block should expose whether the package path was actually
  used.
- Version or API assumptions should be covered by adapter tests.
- Package adapters should be type-generic unless the upstream package truly
  requires `Float64`.

Do not let high-level examples accumulate direct dependencies on low-level
physics packages. If an example needs thrust, torque, power, force, or residuals
from a package-backed model, the relevant subsystem package or SIRENOpt adapter
should expose that quantity.

### Performance Policy

Readable code is the default, but performance-sensitive paths should be designed
so they can become fast without becoming obscure.

Performance rules:

- Keep ergonomic constructors separate from numerical kernels.
- Keep hot kernels type-stable and allocation-light.
- Avoid `Any`, `Dict`, global mutation, and abstract container fields in
  differentiable kernels.
- Preallocate caches for repeated callback evaluation.
- Use concrete small structs or `NamedTuple` snapshots for block outputs.
- Profile before introducing complex optimizations.
- Add allocation or timing checks only for stable kernels where performance is a
  real requirement.
- Preserve AD compatibility while optimizing; speedups that break
  `ForwardDiff.Dual` paths are not acceptable for optimization kernels.

A good implementation shape is:

```julia
config -> validate -> build_block -> allocate_cache -> evaluate! -> residual!
```

The user-facing configuration can be rich and readable. The inner `evaluate!`
and `residual!` methods should be compact, typed, and easy to benchmark.

### Validation And Errors

Invalid systems should fail early with actionable errors. Silent fallback is
only acceptable when it is explicitly requested by the user and recorded in the
result metadata.

Validation should check:

- required blocks are present,
- port units and directions are compatible,
- time grids match resource and demand data,
- design bounds include initial values,
- state initial conditions are physically valid,
- package-backed model construction succeeded when requested,
- solver scales are finite and positive,
- every residual has a declared owner and index range.

Error messages should name the ontology, block, field, expected unit or role,
and the value that failed validation.

### Reproducibility And Result Provenance

Every optimization and manuscript-facing simulation should be reproducible from
its saved artifacts.

Result metadata should include:

- ontology name and version,
- scenario name and input file paths or hashes,
- time grid,
- formulation and defect method,
- solver name and options,
- package-backed versus surrogate block choices,
- SIRENOpt git commit when available,
- generated CSV and figure paths,
- replay residual summary,
- date generated.

Paper figures and tables should be regenerated from result files, not manually
edited. If a figure uses a filtered or aggregated quantity, the transformation
should be scripted and named.

### Documentation Contract

Documentation should explain the software through working examples rather than
abstract claims.

Each major ontology should have:

- a short runnable example,
- a component table,
- a variable and residual table,
- a simulation replay plot,
- an optimization example when applicable,
- a note identifying package-backed, surrogate, prescribed, and replay-only
  paths,
- a troubleshooting section for the most likely unit, sign, AD, and solver
  issues.

Examples should be small by default. Expensive paper cases should be clearly
marked and gated by an environment variable or separate script.

#### Documentation Update Instructions

Documentation must move with the code, model, and paper-facing examples. A change
is incomplete if the docs still describe the old block graph, old model path, old
solver formulation, or old result files.

When changing a block, adapter, ontology, formulation, example, or paper case,
update the relevant documentation in the same change:

- `docs/src/index.md`: update the high-level capability statement when the role of
  SIRENOpt, an ontology, or a package-backed path changes.
- `docs/src/quickstart.md`: keep the shortest runnable example aligned with the
  current public API and default ontology builder.
- `docs/src/theory.md`: update equations, units, signs, time bases, dynamic
  coupling statements, and model-fidelity descriptions.
- `docs/src/api.md`: add or remove exported public names and make sure docstrings
  explain units, signs, and model-path assumptions.
- `docs/src/assets/`: update diagrams whenever ports, package boundaries,
  force/motion coupling, or energy pathways change.
- `examples/`: keep runnable examples and their docstrings consistent with the
  documented ontology, and avoid describing replay-only or prescribed examples as
  two-way coupled optimizations.
- paper draft files and generated result tables/figures: update claims only after
  rerunning or replaying the corresponding case.

Each documentation update should answer these questions explicitly where
relevant:

- Which ontology or example is being documented?
- Which blocks are present, optional, or intentionally absent?
- Which ports connect force, moment, motion, shaft power, electrical power, bus
  power, storage, load, and controls?
- Which model paths are package-backed, surrogate, prescribed, replay-only, or
  smooth approximations?
- Which variables are designs, states, controls, algebraic outputs, and residuals?
- Which formulation is used: simulation, collocation, shooting, retained
  implicit block solve, or multi-timescale reduced map?
- Which time base is used for each state update (`dt_s`, `dt_hours`, hourly
  annual data), and where unit conversions occur?
- Which verification command produced the documented result?

Diagrams should show real interfaces, not aspirational ones. A package boundary
diagram should identify package-backed calls and SIRENOpt-owned quantities. A
system graph should show at least the main force/motion pathway and the main
energy pathway. For motion-coupled systems, the diagram should make the feedback
loop visible: component loads affect platform motion, and platform motion affects
source/resource conversion.

Generated documentation should be built with:

```sh
julia --project=docs docs/make.jl
```

If the docs build cannot run, record the exact blocker in the final response or
design note. The blocker should include the command, the failing package or
missing artifact, and whether source-level Markdown checks were still completed.

### Quality Gates

Before a change is considered complete, agents should run the smallest relevant
verification set that proves the changed behavior. For broad architecture or
paper-result changes, the gate should expand accordingly.

Default gates:

- `git diff --check`,
- focused unit or adapter tests for touched code,
- `Pkg.test()` when core APIs or shared behavior changed,
- relevant example script when an example or generated result changed,
- documentation build when docs changed,
- figure/table regeneration when manuscript-facing outputs changed.

If a gate cannot run, record the exact blocker and the next command that should
be run after the blocker is resolved.

### Change Consistency Checklist

When modifying this architecture, update all affected surfaces together:

- public API examples,
- internal block contract,
- source organization expectations,
- optimization formulation rules,
- test strategy,
- reporting/provenance requirements,
- implementation roadmap,
- definition of done.

Avoid introducing a new term unless it is added to the vocabulary or is local to
one section. Avoid adding a new method, ontology, or package role without also
declaring how it is validated and reported.

## Selected Public Coding Style: Ontology Builder With Overrides

This style gives users a prebuilt ontology and lets them override only what they
care about. This is the selected public-facing style for common SIRENOpt
workflows, paper cases, and reproducible comparison studies.

```julia
system = PackageBackedHybridOntology(
    kind = :wind_wave_solar_battery,
    load = ConstantLoad(power_w = 100.0),
    time = TimeGrid(horizon_s = 180.0, dt_s = 1.0),
    solar = (; area_m2 = Design(0.05, 3.0; initial = 1.0)),
    wind = (; rating_kw = Design(0.005, 0.50; initial = 0.02)),
    battery = (;
        capacity_kwh = Design(0.001, 0.080; initial = 0.01),
        power_kw = Design(0.020, 0.400; initial = 0.05),
    ),
)

result = solve(system, MinimizeCostPerWatt(); optimizer = SNOWIpopt())
report(result, "results/wind_wave_solar_battery")
```

Requirements:

- Every default must be discoverable through `describe(system)`.
- Every implied connection must be visible through `audit(system)`.
- The builder must return ordinary Julia objects, not macro-expanded hidden code.
- The same `system` object must support `simulate`, `assemble`, `solve`, replay,
  and reporting.

## Recommended Style Direction

The selected near-term direction is the ontology builder API backed by a plain
Julia block layer underneath.

1. Use ontology builders with clear overrides for paper, reproduction, and common
   engineering workflows.
2. Use ordinary Julia structs and functions for the internal block contract.
3. Keep explicit graph and do-block assembly available for debugging and
   advanced model construction.

In practice:

- Paper, reproduction, and common-user examples should use ontology builders.
- Core equations should be ordinary functions with explicit inputs and outputs.
- Developers should be able to inspect the generated blocks, variables,
  residuals, and connections.
- Macro syntax should wait until the ordinary API proves itself.

This gives readability without sacrificing too much performance. Users can work
at a high level, while the solver sees structured variable and residual arrays
assembled from simple typed functions.

## Selected Internal Coding Style: CCBlade-Like Structs And Methods

The selected internal implementation style is **concrete structs plus ordinary
methods with small numerical kernels and typed output snapshots**.

This is the closest SIRENOpt analogue to CCBlade.jl's current GitHub style.
CCBlade.jl centers the API on concrete objects such as `Rotor`, `Section`,
`OperatingPoint`, and `Outputs`, provides convenience constructors, exposes
ordinary methods such as `solve` and `thrusttorque`, and keeps differentiable
math in compact kernels. Its README also explicitly advertises ForwardDiff
compatibility. SIRENOpt should follow that pattern for ontology blocks instead
of adopting a macro DSL, a mostly data-driven interpreter, or separate module
namespaces for every block.

Reference checked for this style choice:
`https://github.com/byuflowlab/CCBlade.jl` and
`https://raw.githubusercontent.com/byuflowlab/CCBlade.jl/master/src/CCBlade.jl`.

Chosen pattern:

- Each component is a small concrete subtype of `AbstractSIRENBlock`.
- Behavior is ordinary multiple-dispatch methods: `ports`, `design_variables`,
  `state_variables`, `control_variables`, `outputs`, `residuals`, `evaluate!`,
  `residual!`, and `record!`.
- Physics and package-adapter calls live in small kernel functions called by
  `evaluate!`.
- Stable kernels return concrete snapshot structs. A `NamedTuple` is acceptable
  for prototypes, but public block kernels should move to typed snapshots once
  the fields stabilize.
- Specs remain metadata declarations for validation, registry assembly, reports,
  and docs. They should not become a second interpreter for component physics.
- Component files can be grouped by subsystem under `src/blocks/`, but they
  should not create unnecessary inner modules unless name collisions require it.

Example shape:

```julia
Base.@kwdef struct BatteryBlock{P,C,T} <: AbstractSIRENBlock
    name::Symbol = :battery
    storage_params::P
    converter::C
    capacity_kwh::DesignRef
    power_limit_kw::DesignRef
    initial_soc::T = 0.55
end

struct BatterySnapshot{T}
    soc_next::T
    device_power_kw::T
    bus_power_kw::T
    loss_kw::T
end

function battery_step_kernel(params, converter, soc, command_kw, capacity_kwh, dt_s)
    energy_j = soc * capacity_kwh * 3.6e6
    charge_kw = smooth_max(-command_kw, zero(command_kw))
    discharge_kw = smooth_max(command_kw, zero(command_kw))

    storage = AgnosticStorageDynamics.simulate_storage(
        [charge_kw * 1000.0],
        [discharge_kw * 1000.0],
        params;
        dt = dt_s,
        initial_energy = energy_j,
    )

    device_power_kw = (storage.discharge_power[1] - storage.charge_power[1]) / 1000.0
    converter_out = converter_step_kernel(converter, device_power_kw)

    return BatterySnapshot(
        storage.energy[end] / (capacity_kwh * 3.6e6),
        device_power_kw,
        converter_out.bus_power_kw,
        converter_out.loss_kw,
    )
end

function evaluate!(cache, block::BatteryBlock, ctx, vars)
    snap = battery_step_kernel(
        block.storage_params,
        block.converter,
        state(vars, :battery_soc, ctx.k),
        control(vars, :battery_command_kw, ctx.k),
        design(vars, block.capacity_kwh),
        ctx.dt_s,
    )
    cache[block.name] = snap
    return snap
end

function residual!(res, block::BatteryBlock, ctx, vars, cache)
    snap = cache[block.name]
    actual = state(vars, :battery_soc, ctx.k + 1)
    res[:battery_inventory] = actual - snap.soc_next
    return res
end
```

Rules for this style:

- Keep the public ontology API high level, but make the generated blocks
  inspectable as ordinary Julia objects.
- Keep kernels type-generic and AD-compatible unless a path is explicitly
  replay-only.
- Keep units and sign conventions visible at the block/spec boundary.
- Do not put plotting, report writing, solver mutation, or global registry
  indexing inside kernels.
- Do not call low-level package APIs directly from high-level examples when a
  SIRENOpt block or adapter should own the call.
- Add specs beside the block methods so `describe(system)`, `audit(system)`, and
  registry construction can be generated without reading kernel internals.

The resulting implementation pattern is:

```julia
system = PackageBackedHybridOntology(kind = :wind_wave_solar_battery, ...)
model = assemble(system, Collocation(method = :trapezoidal))
result = solve(model, SNOWIpopt())
replay = simulate(system, controls(result))
report(result)
```

Underneath that public flow, each block should follow:

```julia
config -> build_block -> specs -> evaluate! -> residual! -> record!
```

## Supporting Optimization Packages

The ontology builder and block system should define clear roles for
`OptimizationParameters.jl`, `FLOWMath.jl`, and `ImplicitAD.jl`. These packages
serve different layers of the stack and should not be mixed into every component
indiscriminately.

The snippets below describe proposed SIRENOpt-facing interfaces and wrappers.
They are not meant to freeze the exact public APIs of the supporting packages.

| Package | SIRENOpt role | Should appear in |
| --- | --- | --- |
| `OptimizationParameters.jl` | human-readable optimization parameter declaration and vector packing | optimization assembly layer, examples, possibly core registry if adopted |
| `FLOWMath.jl` | differentiable smooth math utilities and interpolation support | core smooth wrappers and numerical kernels |
| `ImplicitAD.jl` | derivatives through implicit solves when nested solves are retained | implicit block adapters and solver-backed dynamics |

### OptimizationParameters.jl

`OptimizationParameters.jl` should be used to make design/control parameter
declarations readable and auditable. It should not own SIRENOpt physics. Its
job is to help convert named engineering parameters into solver vectors,
initial guesses, bounds, and scaling metadata.

Current dependency status:

- It is currently in the examples environment.
- If it becomes the standard registry backend, it should move into the main
  `SIRENOpt.jl/Project.toml`.
- Until then, SIRENOpt should expose its own small `DesignSpec`, `ControlSpec`,
  and registry interfaces, with an adapter to `OptimizationParameters.jl`.

Intended use:

```julia
system = PackageBackedHybridOntology(
    kind = :wind_wave_solar_battery,
    solar = (; area_m2 = Design(0.05, 3.0; initial = 1.0, unit = "m^2")),
    wind = (; rating_kw = Design(0.005, 0.50; initial = 0.02, unit = "kW")),
    battery = (;
        capacity_kwh = Design(0.001, 0.080; initial = 0.01, unit = "kWh"),
        power_kw = Design(0.020, 0.400; initial = 0.05, unit = "kW"),
    ),
)

model = assemble(system, Collocation(method = :trapezoidal))

x0 = initial_vector(model.registry)
lx = lower_bounds(model.registry)
ux = upper_bounds(model.registry)
scales = variable_scales(model.registry)
```

The SIRENOpt registry should retain:

- stable variable names,
- component ownership,
- role: design, state, control, slack, diagnostic,
- units,
- labels,
- initial values,
- bounds,
- scaling,
- vector index range.

`OptimizationParameters.jl` can then be used behind the registry for vector
packing and parameter bookkeeping, but users should not need to manually write
global index arithmetic.

Do:

- Use it for optimization parameter sets and reproducible variable tables.
- Use it to map named engineering quantities into `x0`, `lx`, and `ux`.
- Use it in examples and solver assembly, not inside physics kernels.

Do not:

- Use it to hide equations.
- Use it inside package adapters like PVlib, storage, rotor, or hydrodynamics
  kernels.
- Let it become the only source of variable metadata; SIRENOpt still needs
  units, labels, report names, and residual ownership.

### FLOWMath.jl

`FLOWMath.jl` should be the core source for differentiable math utilities, but
SIRENOpt code should usually call SIRENOpt wrappers rather than calling
`FLOWMath` directly. This keeps hardness, smoothing scale, and future behavior
centralized.

Current dependency status:

- `FLOWMath` is already a core SIRENOpt dependency.
- `src/smooth.jl` already wraps `FLOWMath.abs_smooth`, `ksmax`, and `ksmin`.
- Examples also use `FLOWMath.akima` directly for legacy or research-specific
  interpolation.

Intended use:

```julia
    # Preferred in SIRENOpt component code:
p_available = smooth_min(p_raw, rating_kw)
p_positive = smooth_max(p_available, zero(p_available))
loss_w = smooth_abs(p_device_kw - p_bus_kw; delta = 1e-9) * 1000.0

    # Preferred for reusable interpolation helpers:
twist_rad = smooth_akima(theta_control, twist_control_rad, theta_eval)
```

SIRENOpt should provide wrappers such as:

```julia
smooth_abs(x; delta = DEFAULT_ABS_DELTA)
smooth_min(a, b; hardness = DEFAULT_KS_HARDNESS)
smooth_max(a, b; hardness = DEFAULT_KS_HARDNESS)
smooth_clamp(x, lo, hi; hardness = DEFAULT_KS_HARDNESS)
smooth_step(x; hardness = DEFAULT_KS_HARDNESS)
smooth_akima(x_control, y_control, x_eval)
```

Do:

- Use SIRENOpt smooth wrappers in differentiable component paths.
- Use `FLOWMath` interpolation through named SIRENOpt helpers when interpolation
  appears in a reusable model.
- Keep case-specific smoothing hardness visible in the case or formulation
  configuration.
- Report when a smooth approximation is being optimized and a hard replay is
  only diagnostic.

Do not:

- Scatter direct `FLOWMath.ksmax`, `ksmin`, or `abs_smooth` calls through
  examples and blocks.
- Use smooth penalties to replace hard feasibility equations.
- Use `max`, `min`, `abs`, or `clamp` in AD-sensitive paths unless the path is
  intentionally nondifferentiable or replay-only.

### ImplicitAD.jl

`ImplicitAD.jl` should be used when SIRENOpt keeps a nested implicit solve inside
a block and still needs reliable derivatives. It should not be the first choice
for every dynamic equation. For collocation, the preferred approach is usually
to expose the state and enforce the residual as a constraint. For shooting,
replay, or package-backed nested solves, `ImplicitAD.jl` is the right tool.

Current dependency status:

- `ImplicitAD` is already a core SIRENOpt dependency.
- The existing simulator has an implicit dynamics hook through
  `dynamics_step(...; method = :implicit, solve_residual = ...)`.

Use ImplicitAD when:

- a block solves `F(y, x) = 0` internally and returns `y`,
- differentiating through the raw iterative solver would be unstable,
- the solver state should not become an NLP decision variable,
- the implicit solve is part of a shooting or replay formulation,
- the package backend exposes a residual but not an AD-friendly closed form.

Typical candidates:

- hydrodynamic or mooring equilibrium solves,
- implicit platform time stepping,
- quasi-static electrical bus solves,
- package-backed algebraic component solves,
- rotor or fluid submodels that expose residual equations.

Preferred implicit block shape:

```julia
function platform_residual!(r, y, x, block, ctx)
    state_next = unpack_platform_state(y)
    state_prev = unpack_platform_state(x)
    wrench = platform_wrench(block, ctx)

    r .= dynamic_defect(block.model, state_prev, state_next, wrench, ctx.dt_s)
    return r
end

function platform_implicit_step(block, state_prev, inputs, ctx)
    y0 = initial_platform_guess(block, state_prev, inputs, ctx)

    solve = y -> platform_residual!(similar(y), y, state_prev, block, ctx)
    y = nonlinear_solve(solve, y0)

    return implicit_ad_result(
        residual = platform_residual!,
        solution = y,
        parameters = (state_prev, inputs, block, ctx),
    )
end
```

The exact function names should follow the actual `ImplicitAD.jl` API when this
is implemented. The SIRENOpt-level design rule is the important part: implicit
blocks must expose a residual and a solve boundary, rather than hiding all
physics inside an opaque iteration loop.

Do:

- Write residual functions first.
- Keep residual scaling explicit.
- Test the residual at the returned solution.
- Compare implicit derivatives against finite differences on small cases.
- Provide a simultaneous-transcription alternative when feasible.

Do not:

- Differentiate through uncontrolled solver iterations by accident.
- Hide failed convergence behind smoothed objectives.
- Use implicit differentiation when a direct residual constraint is clearer.
- Mix plotting, logging, or report writes into implicit solve kernels.

### Combined Role In The Optimization Stack

The intended layering is:

```julia
system = PackageBackedHybridOntology(kind = :wind_wave_solar_battery, ...)

    # OptimizationParameters-style role:
registry = build_registry(system)
x0, lx, ux = vector_data(registry)

    # FLOWMath-style role:
snapshots = evaluate_smooth_blocks(system, registry, x0)

    # ImplicitAD-style role:
implicit_snapshots = evaluate_implicit_blocks(system, registry, x0)

    # SNOW-style role:
callback!(con, x) = objcon!(con, x, assembled_model)
```

In short:

- `OptimizationParameters.jl` helps define what is optimized.
- `FLOWMath.jl` helps make reusable equations differentiable.
- `ImplicitAD.jl` helps differentiate through retained implicit solves.
- SIRENOpt owns the ontology, units, residuals, reports, and package boundaries.

## Optimization Formulations

SIRENOpt should support multiple formulations from the same block graph.

```julia
simulate(system, scenario; controller = RuleBasedController())

optimize(system, scenario;
    formulation = Collocation(method = :trapezoidal),
    objective = MinimizeCostPerWatt(),
)

optimize(system, scenario;
    formulation = Shooting(kind = :multiple, segment_s = 10.0),
    objective = MinimizeUnservedLoadAndCost(),
)
```

### Optimization Method Construction

Every optimization method should be constructed from the same ontology graph,
block metadata, variable registry, residual registry, objective definition, and
scenario. The formulation changes how states and controls are exposed to the
NLP; it should not change the physical equations.

The shared construction path should be:

```julia
system = PackageBackedHybridOntology(kind = :wind_wave_solar_battery, ...)
scenario = ShortHorizonScenario(...)
formulation = Collocation(method = :trapezoidal)

model = assemble(system, scenario, formulation, objective)

x0 = initial_vector(model.registry)
lx = lower_bounds(model.registry)
ux = upper_bounds(model.registry)
lg = lower_constraints(model.registry)
ug = upper_constraints(model.registry)

callback!(con, x) = objcon!(con, x, model)
```

The formulation object should define:

- the time grid,
- which quantities are NLP variables,
- which quantities are computed by replay or nested solves,
- the dynamic defect equations,
- path constraints,
- boundary constraints,
- objective quadrature,
- replay rules for optimized controls.

Public mode summary:

| Mode | Meaning |
| --- | --- |
| `Simulation` / `:simulation` | forward replay with fixed design and controller or prescribed controls |
| `Collocation` / `:collocation` | expose dynamic states and controls as NLP variables and enforce node/stage defects |
| `Shooting` / `:shooting` | expose designs and compact controls, then simulate one or more segments inside the callback and enforce replay/continuity constraints |

Developer/internal variants:

| Variant | Public parent | Use |
| --- | --- | --- |
| direct transcription | `Collocation` | implementation family for node/stage state transcription; do not expose as a separate front-door option unless needed |
| single shooting | `Shooting(kind = :single)` | compact smooth design/control studies and initial guesses |
| multiple shooting | `Shooting(kind = :multiple)` | segmented replay when component integrators should stay encapsulated |
| implicit block | used inside `Collocation` or `Shooting` | retained package/nonlinear solve with residual and sensitivity checks |

Minimal-option policy:

- Public examples should normally expose only `Simulation`, `Collocation`, and
  `Shooting`.
- Use `Collocation(method = :trapezoidal)` as the default dynamic optimization
  method.
- Use `Shooting(kind = :single)` or `Shooting(kind = :multiple)` only when the
  user or developer needs simulator-style state propagation inside the callback.
- Treat retained implicit/package solves as block implementation details. They
  should show up in audits and sensitivity checks, not as a top-level user mode.
- Keep `DirectTranscription(...)` as an expert alias or internal constructor, not
  the primary public spelling.

Do not duplicate physics across formulations. A wind, solar, battery, mooring,
hydrodynamic, or bus equation should live in one block kernel. Collocation,
shooting, and replay should call that same block through different assembly
rules.

### Multi-Timescale Differentiable Optimization

SIRENOpt should support a single top-level optimization assembled from multiple
time scales. The levels are model-reduction layers inside one coherent
formulation, not three disconnected optimizers whose outputs are copied by hand.
Top-level design variables may affect every level, and every level must expose a
differentiable contract back to the optimizer.

The intended hierarchy is:

```text
Level 1: fully coupled motion-resolved physics
    -> Level 2: reduced dynamic performance maps plus controls and sizing
        -> Level 3: annual hourly average or conditional performance and reliability
```

#### Level 1: Fully Coupled Motion-Resolved Physics

Level 1 is the direct, fine-time simulation and co-design layer. It resolves the
motion windows needed to characterize the coupled physics. It is not an annual
simulation at fine time steps.

Dynamic motion is explicit and two-way at this level:

- platform position, velocity, acceleration, and attitude affect wind, wave,
  solar, mooring, PTO, and electrical subsystems where relevant,
- wind thrust and torque, WEC/PTO force, mooring force, hydrodynamic force,
  ballast, storage mass, generator mass, and other component loads feed back into
  platform motion,
- PV panel attitude affects plane-of-array irradiance,
- wind rotor hub motion affects relative inflow, thrust, torque, and shaft power,
- WEC body motion and PTO force affect absorbed wave power and platform loads.

This level is where detailed design variables belong when they affect physics:

- WEC geometry, PTO damping/stiffness, stroke, and force limits,
- wind turbine radius, chord, twist, pitch or torque schedule, and load limits,
- PV area, orientation, mounting, and motion-related derates,
- platform, ballast, mooring, and mass-layout parameters that affect motion.

The output of Level 1 should be a compact differentiable performance/load
contract, not only raw time histories. Examples include wind thrust/torque/power
maps, WEC absorbed-power and load maps, PV attitude derates, mass/cost/load
envelopes, and valid operating bounds.

#### Level 2: Reduced Dynamic Performance And Controls

Level 2 uses the Level 1 contracts over medium horizons. It keeps the dynamics
that matter for operation and combined loading, but it should not rerun the full
fine-time physics at every point unless that is the stated formulation.

This level can optimize:

- component ratings and operating envelopes,
- PTO, generator, converter, curtailment, and dispatch controls,
- battery power capacity and reserve policy,
- representative gust, sea-state, startup/shutdown, and transient events,
- combined worst-case loads and motions from wind, wave, WEC, mooring, and
  electrical operation.

Motion may still appear in Level 2, but usually as reduced states, load envelopes,
or performance-map coordinates. For example, a platform pitch or heave envelope
can modify wind and PV performance without resolving every blade or wave cycle.

The output of Level 2 should be feasible operating policies, ratings, dynamic
load/motion envelopes, and conditional performance tables suitable for the annual
model.

#### Level 3: Annual Hourly Location Optimization

Level 3 uses hourly resource and demand data for a specific location over a full
year. It does not resolve platform motion directly.

This level should enforce:

- annual and seasonal energy balance,
- battery energy capacity, SOC, reserve, and terminal constraints,
- generator, fuel, hydrogen, water, or backup constraints where present,
- unmet-load, availability, and reliability constraints,
- cost, mass, and component sizing constraints.

Motion enters Level 3 only through mean or conditional performance from Levels 1
and 2: derates, availability limits, load envelopes, survival constraints, and
resource-bin performance tables.

#### Final Multi-Level Acceptance Example

The final "cherry on top" definition of done is a runnable multi-level
optimization example that exercises the ontology across all three timescales in
a simplified, fast horizon. This example should be small enough for default CI or
a short local run, but rich enough to prove that the ontology can coordinate
physics, maps, dynamics, sizing, controls, and annual-style reliability.

Target artifact:

```text
examples/multilevel_collocation_hybrid_demo.jl
```

The exact filename can change, but the example must be easy to find from docs
and the roadmap, and it must have a single documented command.

Required default scope:

- constant electrical load, default 100 W,
- solar source, wind source, wave/WEC source, battery, converters, and bus,
- cost-per-delivered-watt or total-cost objective with hard load-serving
  constraints,
- at least one design variable per major source/storage family,
- at least one dispatch or curtailment control per source/storage family where
  physically meaningful,
- hard bus balance, battery inventory, rating, and terminal SOC residuals,
- replay after solve with residual audit and standard reports.

Physics priority order:

1. Use package-backed or adapter-backed physics when the package path is
   available, AD-safe or implicitly differentiable, and fast enough for the
   default horizon.
2. Include wind, wave/WEC, solar, and battery in the required default case.
3. Include hydrokinetic, platform motion, WEC PTO, mooring, and hydrodynamics
   when their block residuals and port contracts are implemented.
4. If full platform/hydrodynamics/mooring are not ready, use the pendulum
   platform stand-in with arbitrary sinusoidal wave forcing as the motion-coupled
   Level 1 surrogate. It must be labeled `surrogate` or `prescribed` as
   appropriate and must not claim full hydrodynamic coupling.
5. If WEC/PTO package-backed physics are not ready, use a documented reduced WEC
   oscillator/PTO surrogate with force, velocity, stroke, absorbed power, and
   PTO limit ports so it can later be replaced without changing system wiring.

Recommended fast horizons:

| Level | Default fast horizon | Purpose | Preferred method |
| --- | --- | --- | --- |
| Level 1 | 20-60 s with fine steps or collocation nodes | motion-coupled source/load characterization and map generation | trapezoidal or Hermite-Simpson collocation if residuals are exposed; otherwise `Shooting(kind = :multiple)` with replay |
| Level 2 | 2-10 min equivalent event horizon | reduced dynamic sizing, controls, SOC, and combined load/motion envelope | trapezoidal collocation using Level 1 maps |
| Level 3 | 24-72 representative hourly points or monthly/hourly bins | annual-style reliability and storage/generator constraints for fixed/reduced designs | algebraic collocation-style assembly using Level 2 performance tables |

The default command should finish quickly on a laptop. Longer horizons, richer
resource files, full annual 8760-hour data, full hydrodynamics, or dense
collocation should be gated by environment variables.

Preferred optimization formulation:

- Use one top-level optimization loop when feasible, with shared design variables
  feeding all levels.
- Use collocation for dynamic states so defects and path constraints are
  explicit.
- Use trapezoidal collocation as the default efficient method. Use
  Hermite-Simpson only when smoother motion trajectories justify the extra stage
  evaluations.
- If a package-backed block retains an internal solve, expose its residual and
  use `ImplicitAD.jl` or a documented finite-difference/implicit sensitivity
  check.
- Do not differentiate through arbitrary solver iterations or hidden mutable
  histories.
- Do not use objective penalties for bus balance, inventory, motion defects, PTO
  stroke/force limits, or load-serving requirements.

Required data flow:

```text
shared design variables
    -> Level 1 collocation/replay physics
    -> reduced performance/load maps with valid ranges and sensitivities
    -> Level 2 reduced dynamic sizing and controls
    -> hourly Level 3 reliability and storage constraints
    -> one result object with replay, reports, and provenance
```

Required reports:

- component table with design values, mass/cost/rating when available, and model
  path per block,
- port graph showing energy, force/motion, storage, and control pathways,
- Level 1 map summary with units, valid ranges, active bounds, and producing
  fidelity level,
- Level 2 dynamic event time series with bus power, SOC, source contributions,
  controls, and motion/load envelope where active,
- Level 3 hourly/binned balance table with load served, SOC/reserve, unmet load,
  curtailment, and reliability margins,
- residual audit for every level and replay residuals after optimization,
- concise plots that avoid unreadable line overlays.

Acceptance criteria:

- The example builds from ontology/block assembly, not manual global index
  arithmetic.
- The default run includes wind, wave/WEC, solar, battery, bus, and load.
- The default run includes hydrokinetic/platform/mooring/hydrodynamics only if
  those blocks meet the validation, residual, and replay requirements; otherwise
  it uses the documented pendulum/wave-forcing fallback.
- The solver reaches an accepted status and the optimized design replays through
  the same block equations.
- Bus balance, battery inventory, dynamic defects, source ratings, terminal SOC,
  PTO limits, and load-serving constraints are hard residuals or bounds.
- Every map or reduced contract records design dependencies, units, valid range,
  interpolation method, and verification case.
- At least one derivative path is checked with ForwardDiff, finite differences,
  or documented implicit sensitivity for each active level boundary.
- The example writes result metadata and reports without hand-edited CSV or plot
  labels.
- If any desired physics are absent, the result clearly labels the substitute
  model path and states what package/block would replace it.

#### Gradient And Solver Contract

The differentiable contract between levels is as important as the physical
contract:

- Explicit maps should be type-generic and compatible with `ForwardDiff.Dual`.
- Interpolated maps should use smooth or piecewise-smooth interpolation with
  declared valid ranges and active-bound reporting.
- If a level contains a nonlinear solve, expose its residual or use
  `ImplicitAD.jl`; do not rely on differentiating through solver iterations as
  the main API.
- If a level contains an optimization problem, either fold its variables and
  constraints into the top-level NLP or differentiate the lower-level KKT system.
- Hard feasibility from lower levels, such as stroke, force, motion, thermal, and
  load limits, should become explicit constraints or certified envelopes at the
  higher level.
- Every reduced map must record which fidelity level produced it, which design
  variables it depends on, its units, valid range, interpolation method, and
  verification case.

#### Direct Transcription And Collocation

Direct transcription is the broad transcription family: it exposes state and
control variables at the time grid and enforces dynamics with residual
constraints. It is an implementation concept, not a separate public user choice
unless a developer is working at the expert API level.

Collocation is a specific direct-transcription mode. It adds stage or midpoint
variables, evaluates block dynamics at nodes and/or stages, and enforces a named
collocation defect such as trapezoidal, implicit midpoint, or Hermite-Simpson.
The public spelling should be:

```julia
Collocation(method = :trapezoidal)
```

The expert API may still use `DirectTranscription(method = :trapezoidal)` as an
alias or internal constructor because it emphasizes the assembly family. Public
docs and examples should prefer `Collocation(...)` so users do not have to choose
between two names for the same equations.

Direct transcription/collocation should be the default method for co-design,
hard path constraints, and coupled wind-wave-solar-battery dynamics because
every equation is visible to the optimizer and to the residual audit.

Construction steps:

1. Build a time grid from the scenario.
2. Register design variables once for the whole horizon.
3. Register state variables at each state node.
4. Register control variables at each control node or control interval.
5. Register algebraic variables only when they are useful for readability,
   constraints, or reporting.
6. Evaluate block outputs at the required nodes or stages.
7. Write dynamic defect residuals for each state.
8. Write path constraints for bus balance, ratings, limits, inventories, and
   operating envelopes.
9. Write initial and terminal constraints.
10. Integrate stage and terminal costs into the objective.

Recommended defect methods:

| Method | Use when | Defect shape |
| --- | --- | --- |
| explicit Euler | tiny demos and initial guesses only | `x[k+1] - x[k] - dt * f[k] = 0` |
| backward Euler | stiff or strongly damped components where first-order accuracy is acceptable | `x[k+1] - x[k] - dt * f[k+1] = 0` |
| trapezoidal | default for short-horizon hybrid-system co-design | `x[k+1] - x[k] - 0.5dt * (f[k] + f[k+1]) = 0` |
| implicit midpoint | compact second-order dynamics with midpoint variables | `x[k+1] - x[k] - dt * f[mid] = 0` |
| Hermite-Simpson | smoother trajectories when extra midpoint evaluation cost is justified | Simpson-integrated state defect plus midpoint consistency |

Required implementation rules:

- Defects are equality constraints, not objective penalties.
- Each defect residual must have units and scale.
- `dt_s` should be used for motion dynamics; `dt_hours` should be used for
  storage and energy accounting; conversions must be explicit.
- State variables should be named by component, state, and time index.
- Path constraints should be local to the time index unless they are intentionally
  cumulative.
- Collocation stage outputs should be recorded separately from node outputs when
  they are needed for debugging.
- A replay simulation should be run after solve using the optimized design and
  controls.

Good fit:

- platform motion co-design,
- battery and production inventory constraints,
- bus balance with hard equality residuals,
- active rating and SOC bounds,
- coupled wind-wave-solar-battery optimization.

Poor fit:

- very long horizons with expensive package-backed dynamics unless the model is
  reduced or segmented,
- black-box integrators that do not expose residuals or AD-friendly outputs.

#### Hydrodynamics 6DOF With Radiation In Collocation

The Hydrodynamics 6DOF solver should fit into the ontology as a dynamic
platform block, not as an opaque ODE solve hidden inside a collocation callback.
Hydrodynamics.jl should own the hydrodynamic force equations and radiation
models. SIRENOpt should own the block metadata, variables, residuals, coupling
ports, scaling, optimization assembly, and replay checks.

Current implementation status to keep explicit:

- SIRENOpt has `PlatformState6DOF` with position, velocity, acceleration, and
  `velocity_history`.
- SIRENOpt has `Hydrodynamic6DOFPlatformModel` fields for hydrostatic
  stiffness, radiation damping, excitation coefficients, constant wrench, PTO,
  mooring, and method selection.
- The current SIRENOpt stepwise adapter only supports `method = :point`.
- Hydrodynamics.jl contains richer radiation paths, including convolution
  integral (`:cic`) and state-space (`:ss`) formulations.
- The Hydrodynamics.jl convolution path currently uses mutable/global velocity
  history, so it is not appropriate to call directly inside an optimization
  callback without refactoring.

For collocation, the preferred form is to expose the 6DOF equations as
residuals:

```text
eta_dot = nu

M * nu_dot =
    F_excitation(t, wave)
  + F_hydrostatic(eta)
  + F_radiation(nu, radiation_state_or_history)
  + F_mooring(eta, nu)
  + F_pto(eta, nu, controls)
  + F_external_from_other_blocks

radiation_state_dot = A_rad * radiation_state + B_rad * nu
```

The collocation state vector should include:

- platform position `eta[1:6]`,
- platform velocity `nu[1:6]`,
- radiation states when using state-space radiation,
- any additional dynamic PTO, mooring, or controller states that affect the
  platform residual.

The collocation residuals should include:

- position defects,
- velocity/momentum defects,
- radiation state defects when `:ss` radiation is used,
- force and moment contribution diagnostics,
- initial and terminal platform constraints where required,
- path constraints for motion, loads, power takeoff, and component limits.

Recommended radiation treatment:

| Radiation path | Collocation fit | Guidance |
| --- | --- | --- |
| linear radiation damping `B * nu` | good first implementation | expose directly in the 6DOF residual |
| state-space radiation `:ss` | best mid-fidelity implementation | add radiation states to the registry and collocate them |
| convolution integral `:cic` | possible but awkward | refactor history into explicit variables or use replay/shooting |
| internal ODE solve | poor for direct collocation | use `Shooting(kind = :multiple)` or replay unless residuals are exposed |

For the intended mid-fidelity SIRENOpt optimizer, the target should be
state-space radiation. That makes radiation memory Markovian and keeps the NLP
visible: SIRENOpt registers the radiation states, Hydrodynamics supplies the
state-space matrices and force equations, and collocation enforces the state
defects.

Implementation rules:

- Do not call a mutable-history Hydrodynamics solver inside `objcon!` for direct
  collocation.
- Do not claim "full 6DOF radiation-memory collocation" until radiation states
  or explicit convolution-history residuals are registered and tested.
- Keep added mass or infinite-frequency added mass in the platform mass matrix
  convention and document that convention in a design record.
- Report excitation, hydrostatic, radiation, mooring, PTO, and external wrench
  contributions separately.
- Use `dt_s` for all motion defects and radiation state defects.
- Preserve Hydrodynamics.jl as the owner of hydrodynamic equations; SIRENOpt
  should wrap and expose those equations, not reimplement them ad hoc in
  examples.
- If a package-backed radiation path is not active, report the model path as
  linear damping, surrogate, prescribed, or replay-only as appropriate.

Recommended progression:

1. Keep the existing `:point`/linear radiation damping path as the first
   collocation target.
2. Add a Hydrodynamics-backed state-space radiation block.
3. Add registry entries for radiation states and force contribution outputs.
4. Add one-step derivative and residual tests for the 6DOF residual.
5. Add a small collocation case with 6DOF platform states and state-space
   radiation.
6. Use `Shooting(kind = :multiple)` when the Hydrodynamics internal integrator
   must remain encapsulated over a segment.

#### Shooting: Single-Segment Variant

Shooting is the second public optimization mode. The single-segment variant
exposes design variables and a compact control parameterization, then obtains
states by forward simulation inside the callback. It is useful for small smooth
problems and quick design searches, but it is less robust for constraint-heavy
hybrid systems because state feasibility is hidden inside the simulation.

Public spelling:

```julia
Shooting(kind = :single)
```

Construction steps:

1. Register design variables and control parameters.
2. Do not register per-time state variables as NLP variables.
3. Simulate the full horizon from the initial state inside `objcon!`.
4. Write terminal and aggregate constraints from the replayed trajectory.
5. Write path constraints either as smooth extrema or as explicit sampled
   residuals from the replayed trajectory.
6. Record the replayed trajectory after solve.

Required implementation rules:

- Keep the simulator deterministic and side-effect free during callback
  evaluation.
- Use AD-safe simulation paths or explicitly use implicit differentiation at
  nested solve boundaries.
- Do not hide hard feasibility behind only a smooth penalty.
- Use this formulation only when replayed path constraints are trustworthy at
  the chosen sample rate.

Good fit:

- low-dimensional design sweeps,
- smooth controller tuning,
- quick comparison against hand-written examples,
- generating initial guesses for collocation.

Poor fit:

- stiff dynamics,
- discontinuous controllers,
- many active path constraints,
- cases where infeasible intermediate states must be prevented directly.

#### Shooting: Multiple-Segment Variant

The multiple-segment variant splits the horizon into segments. Segment initial
states are NLP variables, each segment is simulated internally, and continuity
constraints connect segment end states to the next segment start. This is the
middle ground between collocation and single-segment shooting.

Public spelling:

```julia
Shooting(kind = :multiple, segment_s = 10.0)
```

Construction steps:

1. Choose segment boundaries from time, events, controller changes, or resource
   changes.
2. Register design variables once.
3. Register segment initial states.
4. Register segment-level or interval-level control parameters.
5. Simulate each segment independently inside the callback.
6. Write continuity constraints between simulated segment end states and the next
   registered segment initial state.
7. Write sampled path constraints from each segment.
8. Accumulate objective contributions from segment replay.

Required implementation rules:

- Continuity constraints must be explicit equality constraints with units and
  scale.
- Segment simulations should not mutate shared caches across AD evaluations.
- Segment outputs should be replayable independently for debugging.
- Events at segment boundaries must have a single declared owner.
- Use ImplicitAD at segment solve boundaries when a package-backed implicit
  solve is retained inside the segment.

Good fit:

- medium horizons,
- package-backed component integrators,
- controller tuning with dynamic states,
- cases where collocation has too many variables but single-segment shooting is
  too brittle.

Poor fit:

- systems with dense path constraints at every time step unless sampled
  constraints are sufficient,
- cases where segment simulations are too expensive for repeated callback
  evaluation.

#### Nested Implicit Or Package-Backed Methods

Some blocks will need to keep an internal nonlinear solve, package-backed
equilibrium calculation, or implicit time step. These are not a separate
public optimization method, but they affect how collocation or shooting should
be assembled.

Construction rules:

- Prefer exposing the residual directly as an NLP constraint when the state is
  important to system-level feasibility.
- Use `ImplicitAD.jl` when the solve should remain nested but derivatives are
  still required.
- Always provide a residual check at the returned solution.
- Compare implicit sensitivities with finite differences on a one-step fixture.
- Keep solver logs, plotting, and report writes out of the differentiable path.

Typical nested solves:

- mooring equilibrium,
- hydrodynamic implicit step,
- quasi-static electrical bus solve,
- package-backed rotor/fluid residuals,
- production or storage algebraic operating point solves.

#### Method Selection Rules

Keep the public option set small. Users should normally choose only among
`Simulation`, `Collocation`, and `Shooting`.

Use this default choice order:

1. Use simulation/replay to check units, signs, controls, and residuals before
   optimizing.
2. Use collocation when hard feasibility, state bounds, and coupled dynamics
   matter. This is the default optimization mode for SIRENOpt co-design.
3. Use shooting when the state trajectory should come from a simulator or
   package integrator inside the callback. Use `kind = :single` for compact
   smooth studies and `kind = :multiple` when segmented continuity is needed.
4. Use implicit block boundaries only inside collocation or shooting when a
   package or physics solve should remain nested. Expose residual and sensitivity
   checks either way.

The documentation and reports should name the method actually used. A
prescribed-motion replay should not be described as a motion-coupled
optimization. A smooth surrogate should not be described as a hard constrained
model unless the hard replay confirms feasibility.

### Deep Formulation: Expert `objcon!` Callback

SIRENOpt should also support a deeper, less surface-level optimization style
that follows the pattern in `examples/opt_coding_style_example.jl`. This is not
the default public API, but it is important as an expert escape hatch and as the
lowest-level target that the ontology assembler can generate.

The style is:

- one callback receives the constraint vector and design vector,
- the callback writes constraints in-place,
- the callback returns the scalar objective,
- bounds and constraint limits are declared explicitly,
- SNOW handles AD and solver dispatch,
- a replay call runs the same callback or kernel with recording/plotting enabled.

```julia
function objcon!(con, x, model; record = false)
    vars = view_variables(model.registry, x)
    cache = model.cache
    recorder = record ? ResultRecorder(model) : nothing

    fill!(con, zero(eltype(con)))
    objective_value = zero(eltype(x))

    for k in each_step(model.scenario.time)
        ctx = StepContext(model.scenario, k)

        for block in model.system.blocks
            snapshot = evaluate!(cache, block, ctx, vars)
            residual!(con, block, ctx, vars, cache)

            if record
                record!(recorder, block, ctx, vars, snapshot)
            end
        end

        objective_value += stage_cost(model.objective, ctx, vars, cache)
    end

    objective_value += terminal_cost(model.objective, vars, cache)
    return objective_value
end
```

The solver call should remain explicit and familiar to SNOW users:

```julia
model = assemble(system, Collocation(method = :trapezoidal))

x0 = initial_vector(model.registry)
lx = lower_bounds(model.registry)
ux = upper_bounds(model.registry)
lg = lower_constraints(model.registry)
ug = upper_constraints(model.registry)

options = Options(
    solver = IPOPT(Dict(
        "hessian_approximation" => "limited-memory",
        "limited_memory_update_type" => "bfgs",
        "tol" => 1e-4,
        "max_cpu_time" => 200.0,
    )),
    derivatives = ForwardAD(),
)

callback!(con, x) = objcon!(con, x, model)
xopt, fopt, info, out = minimize(callback!, x0, length(lg), lx, ux, lg, ug, options)

objcon!(zeros(length(lg)), xopt, model; record = true)
report(model)
```

This level is useful for:

- debugging generated optimization models,
- rapid research cases where a custom vector layout is still useful,
- parity checks against older SNOW examples,
- reproducing the direct style of `opt_coding_style_example.jl`,
- verifying AD behavior before wrapping a case in a higher-level ontology.

Style requirements for this level:

- Keep the callback small enough to inspect.
- Move component physics into kernels or blocks instead of burying it all in the
  callback.
- Use explicit `x0`, `lx`, `ux`, `lg`, and `ug` arrays.
- Keep plotting out of the differentiable solve path; use `record = true` replay.
- Ensure every index in `x` and `con` has a registry entry, unit, label, and
  scale.
- Preserve the SNOW convention that constraints are written in-place and the
  objective is returned.

The desired relationship between levels is:

```julia
system = PackageBackedHybridOntology(kind = :wind_wave_solar_battery, ...)
model = assemble(system, Collocation(method = :trapezoidal))

    # High-level use:
result = solve(model, SNOWIpopt())

    # Low-level equivalent:
callback!(con, x) = objcon!(con, x, model)
xopt, fopt, info, out = minimize(callback!, x0(model), nconstraints(model),
    lower_bounds(model), upper_bounds(model),
    lower_constraints(model), upper_constraints(model),
    snow_options(model))
```

The high-level ontology path and the low-level callback path should evaluate the
same equations.

Recommended defaults:

- Use collocation for co-design with hard path constraints.
- Use shooting with `kind = :multiple` when component integrators should stay
  encapsulated.
- Use replay simulation after every optimization to check that the optimized
  controls work outside the NLP transcription.
- Prefer trapezoidal or implicit midpoint defects for mid-fidelity dynamics.
- Keep explicit Euler only for small demonstrations and initial guesses.

## Ontology Test Strategy

The tests should prove that SIRENOpt is usable as an ontology-driven simulation
and optimization package, not only that individual functions return finite
values. The important contract is that a user can assemble a system from named
blocks, run it forward, optimize it, replay the solution, and trace every result
back to named physical equations and package adapters.

The test suite should be layered so failures identify the level that broke.

| Level | What to test | Main failure modes |
| --- | --- | --- |
| Numerical kernels | small functions for power, force, storage, costs, smooth math | unit mistakes, sign mistakes, nondifferentiable branches |
| Package adapters | PVlib, UnsteadyKineticRotorDynamics, GeneratorSE, PowerConverterDynamics, AgnosticStorageDynamics, Hydrodynamics, Mooring, WaveSpectra, DieselGen, H2Gen, Desal | stale upstream APIs, lost type generic behavior, hidden unit conversions |
| Block contracts | each block exposes variables, residuals, outputs, ports, units, and labels | missing metadata, hidden state updates, unclear ownership |
| Registry and parameters | named variables pack into `x`, bounds, scales, and reports correctly | bad indices, duplicate names, lost units, incorrect bounds |
| Ontology assembly | common templates build the intended connected system graph | missing blocks, wrong port wiring, inconsistent default models |
| Simulation replay | the block graph runs without an optimizer and conserves inventories | time-step errors, bad state carryover, sign convention drift |
| Optimization callback | the assembled `objcon!` writes all constraints and returns the same equations as simulation | constraint ordering errors, unscaled defects, AD failures |
| Solver integration | small SNOW/IPOPT cases converge and replay cleanly | infeasible defaults, bad scaling, smoothing-only feasibility |
| Reports and figures | outputs are generated from metadata and match replayed results | stale plots, hand-coded labels, paper/result mismatch |

### Feature Coverage Matrix

The ontology tests should also be traceable to user-facing features. This keeps
the suite from becoming only a collection of implementation checks.

| Usable feature | Acceptance test | Gotcha the test should catch |
| --- | --- | --- |
| Build from an ontology template | construct each common ontology and inspect the block graph | missing required blocks or hidden fallback models |
| Add or remove a subsystem | rebuild the same system with one component disabled | orphaned variables, residuals, or ports |
| Swap model fidelity | run a surrogate or placeholder version and a package-backed version through the same block interface | examples silently using simplified models when package physics was expected |
| Simulate without optimization | run a short forward replay with fixed controls | bad state carryover, time indexing, or inventory balance |
| Optimize a small case | solve a tiny collocation SNOW/IPOPT problem | infeasible defaults, bad scaling, or incomplete constraints |
| Replay optimized controls | feed the optimized design and controls back through simulation | NLP-only feasibility that does not survive replay |
| Trace equations | map each constraint and output to a named block, residual, unit, and scale | impossible-to-debug global index arithmetic |
| Use AD through the model | compare ForwardDiff derivatives to finite differences on kernels and callbacks | accidental `Float64` conversion or nondifferentiable branches |
| Use implicit solves | check residual size and sensitivities for one implicit dynamic step | differentiating through unstable solver iterations |
| Enable two-way dynamics | verify force changes motion and motion changes at least one source/load path | prescribed-motion examples being mislabeled as coupled dynamics |
| Generate reports and plots | regenerate CSVs, tables, and figures from a replay result | stale paper figures or labels that do not match results |
| Compare with SIRENO-lite | run a fixed equivalent case and report model differences side by side | unsupported claims about synergy or mismatched comparison inputs |

### Core Kernel Tests

Each reusable physical equation should have a small deterministic test with
known units and expected signs. These tests should run quickly and avoid solver
dependencies.

Required checks:

- solar power increases with area under fixed weather,
- wind and hydrokinetic power are nonnegative and capped by rating,
- wave resource flux is positive for positive significant wave height and
  period,
- generator and converter output are monotonic and below input when efficiency
  is less than one,
- battery charge/discharge updates SOC with the correct sign and `dt`,
- hydrogen, desalination, and diesel inventories update in the expected units,
- platform force, restoring force, and dynamic acceleration signs are explicit,
- cost and mass aggregation are additive and preserve component ownership.

Gotchas to catch:

- W versus kW and J versus kWh,
- seconds versus hours in dynamics and storage updates,
- positive generation versus negative load convention,
- current, voltage, and bus power sign conventions,
- accidental `Float64` conversion in paths that should support AD types.

### AD and Smoothness Tests

Every differentiable kernel used by optimization should have a small derivative
test. The default pattern is ForwardDiff against central finite differences on a
well-scaled scalar or short-vector case.

Required checks:

- public numerical paths accept `ForwardDiff.Dual`, `BigFloat`, and mixed
  numeric inputs where practical,
- `smooth_min`, `smooth_max`, `smooth_abs`, `smooth_clamp`, and any interpolation
  wrapper remain finite and derivative-stable near transition regions,
- smoothed optimization equations have a hard replay or residual audit when the
  smooth version approximates a physical limit,
- direct calls to `max`, `min`, `abs`, and `clamp` are avoided in AD-sensitive
  component paths unless intentionally replay-only.

Gotchas to catch:

- package adapters that allocate `Vector{Float64}` in differentiable paths,
- smoothing constants that dominate the physics,
- smooth penalties replacing hard feasibility constraints,
- derivative tests at exactly nondifferentiable points instead of near them.

### Block Contract Tests

Every block should have a contract test that can run without the full system.
The test should instantiate the block, inspect its metadata, evaluate one step,
and verify residual/output ownership.

Required checks:

- block name and component type are stable,
- declared variables include role, units, bounds, initial value, scale, and
  report label,
- declared residuals include units, scale, lower/upper limits, and source
  equation name,
- ports declare direction and compatible units,
- `evaluate!` produces finite snapshots without writing reports,
- `residual!` writes only its assigned constraint range,
- `record!` or reporting replay does not change differentiable state.

Gotchas to catch:

- output fields that are useful but not named in metadata,
- residuals that depend on global indices instead of registry views,
- plotting or CSV writes inside differentiable callbacks,
- block-local defaults that differ from ontology-level defaults.

### Registry and Optimization Parameter Tests

The registry is a key usable feature because it removes manual indexing. It
needs direct tests independent of the solver.

Required checks:

- identical ontology inputs produce identical variable and residual ordering,
- variable names are unique and traceable to component ownership,
- `x0`, lower bounds, upper bounds, scales, and labels have matching length,
- design, state, control, slack, and diagnostic roles are distinguishable,
- `OptimizationParameters.jl` adapters preserve names, bounds, units, and
  initial values,
- unpacking and repacking a vector is lossless for one representative system,
- generated variable and constraint tables are stable enough for regression
  tests.

Gotchas to catch:

- off-by-one index errors,
- duplicated variable names from repeated blocks,
- stale bounds after a component is removed,
- changing vector order without updating saved result interpretation.

### Ontology Assembly Tests

Common ontology templates should be tested as user-facing API. These tests
should focus on system composition, not solver convergence.

Required ontology cases:

- solar + battery + load,
- wind + generator + converter + battery + load,
- wave or hydrokinetic + generator + converter + load,
- wind + wave + solar + battery + constant load,
- platform + hydrodynamics + mooring + external wrench,
- full hybrid system with solar, wind, wave/hydrokinetic, diesel, battery,
  hydrogen, desalination, bus, platform, and mooring,
- SIRENO-lite comparison case with matching inputs and explicit model
  differences.

Required checks:

- requested blocks are present and optional blocks are absent,
- ports connect to compatible buses and states,
- adding or removing a subsystem does not require manual reindexing,
- placeholder models and package-backed models can be swapped behind the same
  block interface,
- default scenarios are physically small but nontrivial.

Gotchas to catch:

- silent fallback to placeholder models when package-backed models were
  requested,
- component deletion leaving orphaned variables or residuals,
- ontology defaults that make the first solve infeasible.

### Simulation and Conservation Tests

Simulation is not just a convenience path; it is the replay check for
optimization. Every common ontology should have a short forward replay test.

Required checks:

- electrical bus residuals are near zero for balanced controls,
- battery, hydrogen, diesel fuel, and desalination inventories satisfy their
  step-to-step balance equations,
- generated power, curtailed power, load, storage, and losses close the energy
  balance,
- state histories have the expected length and time stamps,
- results are independent of report generation,
- replay with optimized controls gives the same residuals as the NLP callback
  within tolerance.

Gotchas to catch:

- first-step and last-step indexing errors,
- inventory updates applied before rather than after the reported output,
- mismatch between `dt_hours` storage logic and `dt_s` dynamics logic,
- controls that are feasible in the optimizer but infeasible in replay.

### Dynamic Coupling Tests

The motion-coupled system needs tests that are stronger than "the simulation
runs." These should start with small, controlled mechanical cases before full
wind-wave-solar-battery examples.

Required checks:

- prescribed motion changes wind, wave, or solar inputs only through the declared
  coupling path,
- platform force changes acceleration with the expected sign,
- platform position changes package-backed loads or source terms when two-way
  coupling is enabled,
- 3DOF and 6DOF states preserve vector length, units, and history shape,
- mooring restoring loads oppose displacement and add the expected mass or
  stiffness contribution,
- hydrodynamic excitation, radiation damping, hydrostatics, and external wrench
  terms are distinguishable in residual audits,
- implicit dynamics residuals are small at the returned solution,
- ImplicitAD derivatives match finite differences on a one-step implicit solve.

Gotchas to catch:

- one-way prescribed-motion examples being presented as two-way dynamics,
- body-frame versus inertial-frame sign errors,
- moments computed with inconsistent lever arms,
- hidden damping or stiffness terms that are not reported,
- implicit solves that converge numerically but return incorrect sensitivities.

### Optimization Tests

Optimization tests should be small enough to run routinely, but strong enough to
catch formulation errors. Larger paper cases can be a separate regression tier.

Required checks:

- `constraint_count(model)` matches the actual number of written constraints,
- every constraint index is written exactly once by one residual owner,
- objective and constraints are finite at `x0`,
- AD derivatives of the callback match finite differences on a tiny case,
- a small feasible design remains feasible with zero or near-zero residuals,
- a small optimization improves a known objective relative to the initial design,
- optimized controls replay with acceptable residuals,
- active bound and infeasible-margin reports match solver output.

Gotchas to catch:

- constraints written with opposite sign from their declared bounds,
- objective scaling hiding infeasibility,
- stale state carried in callback caches between evaluations,
- callbacks that mutate model definitions while AD is tracing,
- solver success reported without replay verification.

### Example and Paper Regression Tests

Examples should be treated as user-facing tests. The suite should distinguish
fast examples from expensive manuscript cases.

Fast examples should run in normal tests:

- balanced electric bus demo,
- short one-step package adapter demos,
- a tiny collocation optimization,
- a tiny dynamic replay with platform state,
- SIRENO-lite comparison fixture with fixed input data.

Longer examples should run behind an explicit environment flag or CI job:

- three-minute wind-wave-solar-battery optimization,
- dynamic motion-coupled optimization,
- full ontology paper case,
- figure and table regeneration for the manuscript.

Required checks for paper cases:

- output CSVs contain the columns referenced by the paper,
- plotted quantities match the generated CSVs,
- captions and tables do not describe disabled physics,
- SIRENO-lite and SIRENOpt comparison inputs are declared side by side,
- direct package-backed results are not replaced by stale linear surrogates
  without being labeled as such.

Gotchas to catch:

- plots generated from old result files,
- too many overlapping lines in comparison figures,
- paper text claiming two-way motion coupling for prescribed-motion cases,
- model-difference tables drifting from actual component choices.

### Suggested Test Organization

The current single `test/runtests.jl` should eventually become a small runner
that includes focused files. A practical layout is:

```text
test/
  runtests.jl
  test_kernels.jl
  test_smooth_ad.jl
  test_package_adapters.jl
  test_block_contracts.jl
  test_registry.jl
  test_ontology_assembly.jl
  test_simulation_replay.jl
  test_dynamic_coupling.jl
  test_optimization_callbacks.jl
  test_examples_fast.jl
  test_paper_regressions.jl
  fixtures/
```

The default `Pkg.test()` tier should run deterministic unit, adapter, registry,
simulation, and tiny optimization tests. Expensive tests should be opt-in, for
example:

```julia
if get(ENV, "SIRENOPT_RUN_LONG_TESTS", "0") == "1"
    include("test_paper_regressions.jl")
end
```

### Minimum Coverage Before Calling The Ontology Usable

Before the ontology layer should be considered a stable user feature, the test
suite should demonstrate:

1. A user can assemble every common ontology without manual indexing.
2. Each ontology can run a short simulation replay.
3. At least one ontology can solve a small optimization and replay the result.
4. Every component family has at least one package-backed adapter test.
5. Every AD-sensitive path has a derivative check or is explicitly marked
   replay-only.
6. Every dynamic coupling claim has a force-position or residual-based test.
7. Every paper figure and table is regenerated from checked result files.

## Standard Reports

Every simulation or optimization result should be able to produce the same
human-readable artifacts:

- component table: size, mass, cost, rating, model source,
- time-series CSV: power, current, voltage, states, resources, residuals,
- constraint audit: max residuals, active bounds, infeasible margins,
- energy balance: source, storage, load, curtailment, losses,
- dynamics balance: external loads, restoring loads, inertial terms,
- figures: power bus, SOC, resources, platform motion, residuals.

Reports should be generated from block metadata, not hand-coded per example.

## Implementation Roadmap

Use this roadmap as the agent work queue. An agent should pick one unchecked
item or one clearly bounded sub-item, read the referenced sections above, update
tests and documentation with the code, and check the item only when its local
definition of done is satisfied. If an item uncovers a needed design decision,
add or update a short design record before implementing around the ambiguity.

Treat the roadmap as two tracks:

- **V1 blocking:** the shared specs, ports, graph validation, registry,
  simulation replay, one tiny optimization, model-path reporting, and docs needed
  for the first usable package.
- **Expansion lane:** additional subsystems, full platform/hydrodynamics,
  mooring, hydrogen, desalination, annual cases, and manuscript-scale
  regressions. These are important, but they should plug into the V1 spine
  instead of delaying it.

### First PR Slice

The first implementation slice should be deliberately small. Its purpose is to
establish the block, port, and metadata contract before porting large examples or
building full dynamics.

- [x] Add the core spec types.
  - Implement `VariableSpec`, `ResidualSpec`, `OutputSpec`, `PortSpec`, and
    `BlockMetadata` with owner block, units, labels, bounds, scaling, solver
    role, and model-path fields.
  - Add constructors that reject missing owners, duplicate names, nonfinite
    scales, invalid bounds, and unknown model-path labels.
  - Done when malformed specs fail in unit tests with actionable errors.

- [x] Add the minimal block interface.
  - Implement `AbstractSIRENBlock` and the inspection methods listed in
    **Recommended Internal Model Contract**.
  - Add one tiny deterministic block, preferably a bus balance block or battery
    inventory block, that exercises variables, ports, outputs, residuals, and
    metadata without any external package dependency.
  - Done when the block can be inspected, evaluated for one step, and audited
    without creating a SNOW/IPOPT callback.

- [x] Add a registry stub.
  - Build a stable registry that maps every variable, residual, output, and port
    to owner block, time index or design scope, units, scale, and human label.
  - Done when a tiny two-block graph can produce `x0`, bounds, constraint bounds,
    and trace strings for each registered entry.

- [x] Add first documentation and example hooks.
  - Add a short docs page or docs subsection showing the tiny block graph, port
    table, variable table, and residual table.
  - Add a runnable example that performs forward replay only.
  - Done when source-level docs match the example output and the docs build is
    run or the exact blocker is recorded.

Do not include full wind/PV/WEC/platform physics in this first slice unless the
spec, block, and registry contracts already pass. The value of this slice is the
interface, validation behavior, and traceability.

### Non-Goals For The First Pass

These items are important, but they should not be implemented before the block
contract, port validation, graph assembly, and registry are in place.

- Do not build a full 6DOF hydrodynamic co-design problem before 3DOF or reduced
  motion blocks can prove two-way force-position coupling with residual tests.
- Do not make manuscript claims about dynamic synergy, annual reliability, or
  SIRENO-lite improvement before regenerated results and replay residuals exist.
- Do not route high-level examples directly through low-level package APIs when a
  SIRENOpt adapter or block boundary should own the call.
- Do not use penalty-only feasibility when the physics requires a hard residual,
  bound, or path constraint.
- Do not let an optimizer differentiate through arbitrary solver iterations as
  the default sensitivity path; use explicit residuals, collocation,
  reduced maps, or documented implicit sensitivities.
- Do not silently fall back from package-backed models to surrogates. Fallbacks
  must be requested, labeled, and reported.
- Do not optimize annual hourly cases with motion-resolved dynamics directly.
  Level 3 should consume reduced performance maps or average/conditional
  performance for fixed designs.

If an agent believes one of these non-goals must be violated to make progress,
the required deliverable is a short design record explaining why, what validation
will replace the skipped prerequisite, and how the decision will be revisited.

### Existing Example Migration Table

Use this table to decide what an existing example should become. Migration is
complete only when the example uses ontology/block assembly or a clearly marked
expert API, reports model paths, and replays the result through standard reports.

| Existing artifact | Target role | Must expose | Done when |
| --- | --- | --- | --- |
| `examples/balanced_electric_bus_demo.jl` | minimal electrical ontology smoke test | bus balance, source/load signs, residual trace | the same equations run through block inspection, simulation replay, and registry audit |
| `examples/short_horizon_sirenolite.jl` | SIRENO-lite reference comparison | equivalent inputs, reduced model assumptions, output metrics | comparison inputs and outputs are generated from fixed data and labeled as reference/baseline |
| `examples/short_horizon_snow.jl` | package-backed short-horizon SIRENOpt optimization | PV, wind, storage, bus, load, cost objective, replay residuals | the NLP solves, replays, and reports component/model-path tables without hand-packed plot data |
| `examples/three_minute_package_snow.jl` | three-minute package-backed energy case | fine time grid, package-backed PV/wind/WEC/storage paths where active, 100 W load, cost per watt | the run declares which physics are active, satisfies load through hard bus/storage constraints, and produces readable figures |
| `examples/prescribed_motion_dynamic_io.jl` | motion-port and replay fixture | prescribed motion state, source/load response, port metadata | it is clearly labeled one-way prescribed motion and does not claim two-way dynamics |
| `examples/pendulum_platform_codesign_snow.jl` | first dynamic coupling optimization fixture | platform state, component loads, motion-dependent source terms, hard motion defects | a short case solves and replay proves component loads change platform motion and platform motion changes at least one source/load path |
| `examples/opt_coding_style_example.jl` | coding-style reference | local conventions, AD-safe kernels, registry-compatible output shape | it is either converted into a maintained style guide example or archived as historical reference |
| paper comparison scripts/results | manuscript evidence pipeline | generated CSVs, figure scripts, model-difference table, provenance | paper text reads generated values and unsupported or stale claims are removed |

When migrating an example, keep a simple command at the top of the file or in
the docs. Long paper-scale cases should be gated by environment variables so the
default test suite stays fast.

### Phase 0: Decisions And Scope Control

- [x] Record global unit, sign, frame, and model-path decisions.
  - Scope: bus power signs, battery command signs, platform DOF ordering,
    moment reference points, `dt_s` versus `dt_hours`, package-backed versus
    surrogate vocabulary, and default formulation choices.
  - Deliverables: a design-record section in this file or `docs/design/`, plus
    any small sign-convention tests needed to lock the choice.
  - Done when: every global convention used by blocks has a documented owner,
    units and signs are reflected in metadata, and at least one obvious-value test
    would fail if a sign or frame convention were reversed.

- [x] Define model-path reporting rules.
  - Scope: `package-backed`, `surrogate`, `placeholder`, `prescribed`,
    `replay-only`, `hard residual`, and `smooth approximation` labels.
  - Deliverables: result metadata fields and a helper that reports model path per
    block.
  - Done when: examples and reports can state which path each block used without
    relying on prose inspection.

### Phase 1: Specs, Ports, And Validation

- [x] Implement core specs.
  - Scope: `VariableSpec`, `ResidualSpec`, `OutputSpec`, `PortSpec`,
    `BlockMetadata`, units, bounds, scaling, owner block, labels, and solver role.
  - Deliverables: spec types, constructors with validation, and small unit tests.
  - Done when: invalid units, duplicate names, missing owner blocks, nonfinite
    scales, and inconsistent bounds fail early with actionable errors.

- [x] Implement the minimal block interface.
  - Scope: `AbstractSIRENBlock`, `block_name`, `design_variables`,
    `state_variables`, `control_variables`, `ports`, `outputs`, `residuals`,
    `evaluate!`, `residual!`, and `record!`.
  - Deliverables: interface methods, one tiny example block, and contract tests.
  - Done when: a block can be inspected without running a solver, evaluated for
    one step, and audited for variables, ports, outputs, residuals, units, and
    labels.

- [x] Add ontology and graph validation.
  - Scope: required/optional blocks, port compatibility, unit compatibility,
    direction compatibility, time-grid compatibility, package-backed construction,
    solver scale validity, and initial design/state feasibility.
  - Deliverables: validation functions and failure messages naming ontology,
    block, field, expected role/unit, and invalid value.
  - Done when: intentionally broken fixtures fail before optimization starts, and
    valid fixtures pass without warnings.

### Phase 2: Block Wrapping And Package Boundaries

- [x] Wrap electrical and storage blocks.
  - V1 scope: load, bus, converter, generator boundary where needed,
    battery/storage, and inventory updates.
  - Expansion lane: diesel backup, hydrogen, desalination, and multiple
    inventory systems.
  - Deliverables: block wrappers around existing kernels/adapters, port specs for
    device power, bus power, voltage/current, command power, inventory state, and
    losses.
  - Done when: each block has a one-step contract test, sign tests, AD or finite
    difference checks where relevant, and no report-only `Dict{String,Any}` in the
    differentiable kernel.

- [x] Wrap resource and source blocks.
  - V1 scope: PV/solar, resource time series, curtailment controls, and one
    package-backed wind or wave/WEC source.
  - Expansion lane: wind plus wave together, hydrokinetic, site-specific resource
    models, and additional source families.
  - Deliverables: blocks that expose shaft/mechanical, electrical, bus, force,
    moment, and resource-use ports as appropriate; package-backed diagnostics for
    PVlib, UnsteadyKineticRotorDynamics, WaveSpectra, GeneratorSE, and converters.
  - Done when: wind can expose thrust/moment/shaft power separately from generator
    and converter blocks, PV can expose DC power before converter blocks, and each
    package-backed path reports whether it actually ran.

- [x] Wrap platform, mooring, hydrodynamic, and motion blocks.
  - V1 scope: a reduced platform or pendulum motion block with force/moment
    ports, motion states, and dynamic defects.
  - Expansion lane: 3DOF/6DOF platform motion, hydrodynamic forces, mooring
    forces, PTO forces, component mass/inertia, and external force/moment
    accumulation.
  - Deliverables: dynamic state specs, force/moment ports with frames/reference
    points, residuals for motion defects, and replay records for force balance.
  - Done when: a test verifies two-way coupling: a component load changes platform
    acceleration, and platform motion changes at least one source/load path.

### Phase 3: System Graph And Ontology Builders

- [x] Implement `SystemGraph`.
  - Scope: explicit block names, port connections, graph validation, topological
    or staged evaluation order, repeated block names, and disabled optional
    blocks.
  - Deliverables: graph type, connection API, graph inspection/reporting, and
    fixtures with missing, duplicate, and incompatible ports.
  - Done when: adding/removing a subsystem rebuilds the graph without orphaned
    variables, residuals, ports, or reports.

- [x] Implement common ontology builders.
  - Scope: `MinimalEnergyOntology`, `PackageBackedHybridOntology`, and
    `DynamicMultilevelHybridOntology`, with `SIRENOLiteOntology` as a comparison
    fixture and `FullSIRENOptOntology` as a future alias after the smaller
    builders pass.
  - Deliverables: public constructors with readable overrides, validation, default
    model-path metadata, and examples of component replacement.
  - Done when: each ontology can be constructed by name, printed as a component
    and port graph, and run through a minimal validation fixture.

### Phase 4: Registry And Assembly

- [x] Implement variable, residual, output, and port registries.
  - Scope: stable index assignment, units, labels, bounds, scaling, owner block,
    time index, and report names.
  - Deliverables: registry builders, index views, `x0`, lower/upper bounds, lower
    and upper constraint vectors, and trace utilities.
  - Done when: every entry in `x` and `con` maps back to one block, one quantity,
    one unit, one scale, and one time index or design scope.

- [x] Implement simulation assembly.
  - Scope: forward replay using the same block kernels, controller hooks,
    prescribed inputs, state carryover, result recording, and residual audits.
  - Deliverables: simulation runner, replay result object, and one small
    simulation for each common ontology.
  - Done when: simulation can run without a solver callback and produce standard
    time-series CSV rows, residual summaries, and block output records.

- [x] Implement collocation assembly.
  - Scope: state/control/design exposure, dynamic defects, bus balance, inventory
    constraints, path constraints, terminal constraints, objective quadrature, and
    replay rules.
  - Deliverables: collocation/direct-transcription-family model builder and SNOW/IPOPT callback
    wrapper using registry views.
  - Done when: a tiny wind/solar/battery/bus NLP solves, every constraint is
    traceable to a residual owner, and replay with optimized controls matches NLP
    residuals within declared tolerances.

- [x] Implement shooting variants and retained implicit solve boundaries where needed.
  - Scope: `Shooting(kind = :single)` for smooth compact studies,
    `Shooting(kind = :multiple)` for encapsulated dynamic segments, and
    `ImplicitAD.jl` boundaries for retained nonlinear solves.
  - Deliverables: formulation objects and one focused fixture per method.
  - Done when: each method documents what is exposed as an NLP variable, what is
    replayed, and how residuals or sensitivities are checked.

### Phase 5: Multi-Timescale Optimization

Phase 5 is the bridge from the first usable package to the full research goal.
Do not start here until the V1 spine can already build, audit, simulate,
optimize, replay, and report a smaller hybrid case. The V1-relevant part of this
phase is the metadata contract and one fast demonstrator; full annual and
full-hydrodynamic studies remain gated expansion cases.

- [x] Define reduced performance-map contracts.
  - Scope: Level 1 motion-resolved maps, Level 2 reduced dynamic envelopes, Level
    3 annual hourly performance tables, valid ranges, interpolation methods, and
    active-bound reporting.
  - Deliverables: map metadata specs, map evaluation kernels, and fixtures for
    wind, WEC/wave, PV, and load/motion envelopes.
  - Done when: a map records its producing fidelity level, design dependencies,
    units, valid range, interpolation method, and verification case.

- [x] Implement a three-level demonstration fixture.
  - Scope: a small Level 1 motion-coupled characterization, Level 2 reduced
    dynamic sizing/control event, and Level 3 short annual-style hourly resource
    check.
  - Deliverables: one runnable example behind a short default horizon, with long
    data gated by an environment variable.
  - Done when: the fixture proves the data flow from detailed design variables to
    reduced maps to hourly reliability constraints, with AD or documented
    implicit sensitivities.

- [x] Implement the final multi-level collocation acceptance example.
  - Scope: `examples/multilevel_collocation_hybrid_demo.jl` or equivalent,
    using a fast default horizon with wind, wave/WEC, solar, battery, bus, and
    load; include hydrokinetic, platform, WEC PTO, mooring, and hydrodynamics
    when their block residuals are ready, otherwise use the documented pendulum
    platform and sinusoidal wave-forcing fallback.
  - Formulation: one top-level optimization loop where feasible, shared design
    variables across levels, trapezoidal collocation as the default efficient
    method, and explicit residuals for bus balance,
    inventory, dynamic defects, ratings, terminal SOC, PTO limits, and load
    serving.
  - Deliverables: runnable command, generated result metadata, component table,
    port graph, Level 1 map summary, Level 2 dynamic event table/plots, Level 3
    hourly or binned reliability table, residual audit, and replay reports.
  - Done when: the default run solves and replays quickly, model paths are
    reported for every active or substituted physics block, at least one
    sensitivity check exists at each active level boundary, and absent desired
    physics are explicitly labeled with their replacement target.

### Phase 6: Reports, Plots, And Documentation

- [x] Implement standard reports.
  - Scope: component table, port graph, variable/residual table, time-series CSV,
    constraint audit, energy balance, dynamics balance, model-path summary, and
    result provenance.
  - Deliverables: report functions that consume metadata and replay results rather
    than hand-coded example-specific columns.
  - Done when: a new ontology can generate reports without writing a custom CSV
    exporter, and reported fields match registry/output metadata.

- [x] Implement standard plots.
  - Scope: bus power, SOC/inventory, resources, source contributions, platform
    motion, force/moment balance, residuals, and active constraints.
  - Deliverables: plot helpers with readable labels and consistent styles.
  - Done when: plots are generated from result tables, do not require manual label
    edits, and avoid unreadable line overlays for comparison cases.

- [x] Update documentation with every public behavior.
  - Scope: `docs/src/index.md`, `quickstart.md`, `theory.md`, `api.md`, diagrams,
    runnable examples, model-path labels, and troubleshooting.
  - Deliverables: docs updates tied to each API/formulation/example change.
  - Done when: `julia --project=docs docs/make.jl` passes, or the exact blocker is
    recorded with the failing command and source-level Markdown checks completed.

### Phase 7: Example Migration And Paper Cases

- [x] Port existing SNOW examples to the block API.
  - Scope: balanced bus, short-horizon SIRENOpt, SIRENO-lite comparison,
    three-minute package-backed case, prescribed-motion replay, and pendulum or
    motion-coupled co-design cases.
  - Deliverables: examples that use ontology builders or expert generated
    callbacks, plus replay reports.
  - Done when: each migrated example states its model path, formulation, time grid,
    package-backed blocks, and replay residual summary.

- [x] Add SIRENO-lite comparison fixture.
  - Scope: fixed equivalent inputs, model-difference table, comparable outputs,
    and clear distinction between reference model and SIRENOpt package-backed
    paths.
  - Deliverables: fixture data, comparison script, CSV/table output, and readable
    plot set.
  - Done when: the comparison can be rerun from clean inputs and the paper text can
    cite generated values without manual edits.

- [x] Add manuscript-scale long-test gates.
  - Scope: paper result generation, figure/table regeneration, long dynamic cases,
    and annual-resource cases.
  - Deliverables: environment-gated scripts, clear commands, and saved result
    provenance.
  - Done when: default tests stay fast, long tests are opt-in, and generated paper
    artifacts are traceable to checked CSVs.

### Phase 8: Test Suite And Release Readiness

- [x] Split the test suite into focused files.
  - Scope: kernels, smooth AD, adapters, block contracts, registry, ontology
    assembly, replay, dynamic coupling, optimization callbacks, fast examples, and
    paper regressions.
  - Deliverables: `test/runtests.jl` runner with deterministic default tier and
    environment-gated long tier.
  - Done when: `Pkg.test()` exercises the default tier and long tests can be run
    explicitly without changing source files.

- [x] Add AD and finite-difference gates.
  - Scope: public numerical paths, maps, callbacks, and implicit boundaries.
  - Deliverables: ForwardDiff versus central finite-difference checks or explicit
    replay-only labels where AD is not valid.
  - Done when: accidental `Float64` conversion, nondifferentiable branches, and
    unstable solver-iteration differentiation are caught by tests.

- [x] Add final release audit.
  - Scope: docs, examples, tests, model-path labels, result provenance, package
    boundaries, and generated paper artifacts.
  - Deliverables: release checklist output or audit note.
  - Done when: the default test suite passes, docs build or blocker is recorded,
    examples are current, and every checked roadmap item has evidence.

## Definition of Done

The definition of done has two levels. The first level is the smallest package
that is useful to users and agents. The second level is the full ontology goal.

### First Usable Package

V1 is complete when all of the following are true:

- [x] A user can build a minimal hybrid system without manual index arithmetic.
- [x] The same system can be inspected with `describe(system)` and
  `audit(system)` before running a solver.
- [x] A user can run a forward simulation and replay fixed controls without
  writing a solver callback.
- [x] A user can run one tiny `Collocation` or `Shooting` optimization from the
  same block graph.
- [x] Every variable, residual, output, and port in the tiny example maps back to
  a block, unit, scale, time/design index, and model-path label.
- [x] The first public builders are limited to `MinimalEnergyOntology`,
  `PackageBackedHybridOntology`, and `DynamicMultilevelHybridOntology` or their
  documented aliases.
- [x] Standard component, port, variable/residual, model-path, replay, and
  residual-audit reports are generated from metadata.
- [x] Package-backed and surrogate paths are labeled explicitly, and no silent
  fallback occurs.
- [x] Documentation shows the minimal build, simulation, optimization, replay,
  and report workflow with commands that either pass or record a concrete
  blocker.

### Full Goal

The full ontology goal is complete only when all of the following are true:

- [x] A user can build a hybrid system by selecting blocks or an ontology
  template without manual index arithmetic.
- [x] A user can run a forward simulation without writing a solver callback.
- [x] A user can turn the same system into an optimization by declaring objectives
  and exposed variables.
- [x] A user can add, remove, or replace a subsystem without orphaned variables,
  residuals, ports, reports, or hand-edited bounds.
- [x] Standard outputs, plots, component tables, port graphs, and residual audits
  are generated from metadata and replay results.
- [x] Every optimization constraint can be traced back to a named physical
  equation, block, unit, scale, and time/design index.
- [x] Surrogate, placeholder, package-backed, prescribed, smooth, and replay-only
  paths are reported accurately in every result.
- [x] Package-backed models can replace surrogates without changing the
  system-level wiring.
- [x] Dynamic coupling claims have force-position or residual-based tests.
- [x] Multi-timescale cases show how Level 1 motion-resolved physics produces
  reduced contracts for Level 2 dynamics and Level 3 annual hourly reliability.
- [x] A final fast multi-level collocation example runs
  end to end with wind, wave/WEC, solar, battery, bus, and load; includes
  hydrokinetic/platform/WEC PTO/mooring/hydrodynamics when validated block
  residuals exist; otherwise uses the documented pendulum/wave-forcing fallback;
  and produces replayed reports, map metadata, residual audits, and derivative
  checks across active level boundaries.
- [x] Manuscript-facing figures and tables can be regenerated from saved,
  checked result files.
- [x] The default test suite covers kernels, adapters, block contracts, registry
  assembly, ontology assembly, simulation replay, dynamic coupling, and at least
  one tiny optimization.
- [x] Long examples and paper regressions are gated but runnable with documented
  commands.
- [x] Documentation describes the current public API, block graph, model paths,
  formulations, ports, and verification commands.
- [x] Design records exist for global units, signs, frames, model-path vocabulary,
  and default formulation choices.
- [x] Hot kernels can be profiled or inspected without disentangling them from
  plotting, reporting, or solver-side mutation.
