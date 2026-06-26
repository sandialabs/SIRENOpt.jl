# SIRENOpt Human-Readable Goal

## BLUF

SIRENOpt.jl should become the glue layer that lets hybrid energy system pieces
snap together, run, optimize, and report results without hand-wiring every
example.

The goal is not to rewrite PVlib, GeneratorSE, Hydrodynamics, Mooring, storage,
rotor, WEC, or converter packages. The goal is to wrap them in consistent
SIRENOpt blocks with ports, units, signs, residuals, reports, and optimization
metadata.

The first useful system is simple: solar, converter, battery, load, and bus. The
final proof is a fast multi-level optimization with wind, wave/WEC, solar,
battery, bus, and load, plus platform/mooring/hydrodynamics when those blocks
are ready.

The optimizer should see explicit equations and constraints, not a pile of
example-specific vector indices and hidden penalties.

## One-Page Summary

| Topic | Plain-English Meaning | What Success Looks Like |
| --- | --- | --- |
| SIRENOpt role | The system assembly and optimization layer | It connects packages through typed blocks and ports |
| Blocks | Components such as PV, wind, battery, platform, load, bus | Each block declares inputs, outputs, states, controls, residuals, and reports |
| Ports | Named physical connection points | Power, force, motion, storage, demand, and control paths are explicit |
| Ontology | A validated template for a system | Users select an ontology instead of manually wiring every variable |
| Wrappers | SIRENOpt adapters around subsystem packages | Package-native outputs become SIRENOpt ports with units and signs |
| Residuals | Hard equations or inequalities | Bus balance, SOC update, motion defects, ratings, and limits are constraints |
| Registry | The map from block metadata to optimizer vectors | Every entry in `x` and `con` traces back to a block, unit, scale, and time |
| Reports | Standard result artifacts | Component table, port graph, time series, residual audit, model-path summary |
| SIRENO-lite | Reference comparison | Used for baseline comparison, not as the main SIRENOpt implementation |
| Final demo | Fast multi-level optimization | Wind, wave/WEC, solar, battery, bus, load, and motion fallback or full platform |

## The Main Idea

Each subsystem package can keep its own natural API. SIRENOpt provides the
composable interface around it.

For example:

| Package Or Model | Native Thing It Computes | SIRENOpt Wrapper Exposes |
| --- | --- | --- |
| PVlib | solar/PV power | resource input, device power, bus power through converter, area, mass/cost |
| UnsteadyKineticRotorDynamics | rotor loads and shaft power | wind resource, motion input, thrust, moment, shaft power |
| GeneratorSE | generator conversion | shaft mechanical input, electrical output, loss/rating metadata |
| PowerConverterDynamics | converter losses | device-side power, bus-side power, efficiency/loss residuals |
| AgnosticStorageDynamics | storage state update | SOC/state, charge/discharge command, inventory residual |
| Hydrodynamics | platform/wave forces and motion terms | motion state, hydrodynamic wrench, dynamic residuals |
| Mooring | restoring/mooring loads | platform motion input, mooring wrench output |
| WEC/PTO model | absorbed wave power and PTO force | wave input, motion input, PTO control, force, shaft/device power |

## Interface Rule

Do not make every block pretend to have every possible interface.

Use a few block interface types:

| Interface Type | Examples | Main Ports |
| --- | --- | --- |
| Resource provider | weather, wave, load profile | `resource_state`, `demand_profile` |
| Electrical source | PV, simplified wind/wave source | resource in, electrical out |
| Mechanical prime mover | wind rotor, WEC, hydro rotor | resource/motion in, shaft power and/or force out |
| Converter/generator | inverter, rectifier, generator | upstream power in, downstream electrical out |
| Storage | battery, tank | state, command, power in/out |
| Load/process | load, desalination, H2 | demand in, bus power in |
| Motion dynamics | pendulum, 3DOF, 6DOF platform | force/moment in, motion state out |
| Aggregator | bus, platform wrench, mass/cost | many inputs, one balance residual |

If a component does not have a physical output, do not hide fake physics inside
the component. Either omit the port or add an explicit zero-contribution adapter.

Example: solar usually has no platform force. In a floating-platform ontology,
SIRENOpt can either leave solar out of the platform force sum or add a visible
`zero_platform_wrench` adapter. That adapter returns exactly zero force and
moment and reports "not applicable", not "package-backed physics".

## Three Optimization Levels

| Level | Time Scale | What It Solves | What It Passes Up |
| --- | --- | --- | --- |
| Level 1 | seconds or sub-seconds | detailed motion-coupled physics and design | performance/load maps, valid ranges, sensitivities |
| Level 2 | minutes to events | reduced dynamics, controls, ratings, envelopes | operating policies, load envelopes, reduced performance tables |
| Level 3 | hourly/yearly | annual resource/load reliability and sizing | final energy balance, storage/generator constraints, cost/reliability |

Motion belongs mainly in Level 1 and reduced Level 2. Level 3 should not run
full platform dynamics over an annual horizon. It should use maps and envelopes
created by the lower levels.

## Optimization Modes

Keep the user-facing options small: simulation, collocation, and shooting.

Direct transcription is the broad implementation idea behind collocation: expose
states and controls as optimizer variables and enforce dynamics as residual
constraints. Users should usually see this as `Collocation(...)`.

| Mode | Plain-English Meaning | Use It When |
| --- | --- | --- |
| simulation/replay | run forward with fixed designs and controls | checking signs, units, residuals, and optimized replay |
| collocation | node/stage states with hard dynamic defects | coupled dynamics need accurate, visible constraints |
| shooting | optimize compact controls and simulate one or more segments internally | quick smooth studies, initial guesses, or retained package integrators |

Advanced details:

| Detail | Where It Fits |
| --- | --- |
| direct transcription | the implementation family behind collocation |
| single shooting | `Shooting(kind = :single)` for one full-horizon simulation |
| multiple shooting | `Shooting(kind = :multiple)` for segmented simulation with continuity constraints |
| implicit block | not a user mode; a block-level solve used inside collocation or shooting |

Practical rule:

| Situation | Choose | Why |
| --- | --- | --- |
| I just want to run a fixed design | simulation | no optimizer needed |
| I need hard SOC, bus, load, rating, or motion constraints | collocation | states and defects are visible to the optimizer |
| I have a short finite-element/pendulum-style dynamic optimization | collocation | this is the default for coupled dynamics |
| I trust a simulator and only want to tune a few design/control parameters | shooting | avoids exposing every time-step state |
| I need to keep a package integrator intact over short segments | shooting with `kind = :multiple` | exposes segment starts and continuity without rewriting the integrator |
| A package has an algebraic/nonlinear solve inside one block | implicit block inside collocation or shooting | keep the solve local but expose residual and sensitivity checks |

The public docs should not make users choose among six methods. The top-level
choice is simulation, collocation, or shooting. Everything else is an advanced
variant.

## Final Demonstration

The final proof of the ontology is a fast example like:

```text
examples/multilevel_collocation_hybrid_demo.jl
```

Default case:

| Requirement | Meaning |
| --- | --- |
| Load | constant 100 W |
| Sources | wind, wave/WEC, solar |
| Storage | battery with SOC and terminal constraint |
| Network | converters and bus balance |
| Objective | minimize cost per delivered watt or total cost |
| Method | trapezoidal collocation by default |
| Reports | component table, port graph, maps, time series, residual audit |

Optional when ready:

| Physics | Include When | Fallback |
| --- | --- | --- |
| Platform | dynamic residual and motion ports exist | pendulum platform |
| Hydrodynamics | force equations are exposed and replayable | sinusoidal wave forcing |
| Mooring | restoring force port is validated | pendulum restoring torque |
| WEC/PTO | force/power/stroke/limit ports exist | reduced oscillator/PTO surrogate |
| Hydrokinetic | package-backed or surrogate block exists | omit and report absent |

The final demo is not allowed to silently fake unavailable physics. Missing
physics must be labeled with the substitute and the intended replacement.

## Implementation Order

| Step | Build This | Why |
| --- | --- | --- |
| 1 | specs and ports | blocks need a shared language |
| 2 | tiny bus/battery/PV slice | proves assembly without full dynamics |
| 3 | registry | maps block metadata to optimizer vectors |
| 4 | simulation replay | proves the model runs without an optimizer |
| 5 | tiny collocation solve | proves hard constraints and replay |
| 6 | package-backed adapters | moves from toy blocks to real physics |
| 7 | dynamic coupling | proves force affects motion and motion affects sources |
| 8 | multi-level demo | proves Level 1 to Level 2 to Level 3 workflow |

## Q&A

### Is SIRENOpt replacing the physics packages?

No. SIRENOpt is the assembly layer. Physics should live in the subsystem packages
or in clearly labeled SIRENOpt surrogate blocks.

### Does every block need the same interface?

No. Blocks use interface archetypes. A battery is not a platform, and solar is
not a mooring model. They should expose only the ports that make physical sense.

### What happens if an ontology wants every component to contribute force, but a
component has no force?

Use an explicit zero-contribution adapter or omit the connection. Do not bury a
zero force inside the solar kernel. The graph and report should make the zero
contribution visible.

### What is a residual?

A residual is an equation the solver must satisfy. Bus balance, SOC update,
motion defects, force balance, and rating limits should be residuals or bounds,
not vague penalty terms.

### Why do we need a registry?

Optimizers see vectors. Humans see components. The registry is the translation
table between the two. Every vector index must trace back to a block, quantity,
unit, scale, and time index.

### Why not just write one big optimization script?

That is what the current examples drift toward. It works once, then becomes hard
to extend, compare, debug, or trust. The ontology makes the same model reusable
for simulation, optimization, reporting, and paper figures.

### What does "package-backed" mean?

It means the block actually called the relevant package path for the relevant
physics. If a simplified SIRENOpt equation was used instead, call it a surrogate.
If a quantity was imposed from a file or formula, call it prescribed.

### Where does SIRENO-lite fit?

SIRENO-lite is the reference baseline. SIRENOpt should compare against it, but
the SIRENOpt paper and examples should stand on SIRENOpt's own package-backed
and ontology-driven implementation.

### What is the fastest useful first example?

Solar plus converter plus battery plus load plus bus. It proves ports,
residuals, registry, replay, and a tiny collocation solve without
waiting for platform dynamics.

### Is direct transcription the same as collocation?

Direct transcription is the umbrella implementation idea. Collocation is the
user-facing mode for that idea. Public examples should say
`Collocation(method = :trapezoidal)` so users are not asked to choose between two
names for the same equations. Expert code may still use
`DirectTranscription(method = :trapezoidal)` internally.

### What is the final example?

A fast multi-level collocation demo with wind, wave/WEC, solar, battery, bus,
and load. Add hydrokinetic, platform, WEC PTO, mooring, and hydrodynamics when
those block residuals are ready. Use the pendulum and sinusoidal wave forcing as
the honest fallback.

### What makes the result believable?

It solves, replays, reports residuals, labels model paths, checks derivatives or
implicit sensitivities, and regenerates figures/tables from result files.
