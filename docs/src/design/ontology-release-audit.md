# Ontology Release Audit

Status: accepted
Date: 2026-06-24

This audit records the release-readiness evidence for the ontology V1 and full
goal checklist in `OntologyGoal.md`.

## Verified Scope

- Public builders remain `MinimalEnergyOntology`, `PackageBackedHybridOntology`,
  `DynamicMultilevelHybridOntology`, and the comparison fixture
  `SIRENOLiteOntology`. `FullSIRENOptOntology` remains reserved so the name does
  not overstate package-backed WEC/PTO, hydrodynamic, or mooring coverage.
- Metadata-generated reports cover components, ports, connections, variables,
  residuals, outputs, model paths, formulation boundaries, replay residuals,
  level-map contracts, result provenance, and standard SVG plots.
- The final multi-level acceptance fixture regenerates residual audits, map
  metadata, derivative checks, Level 1/2/3 summaries, manuscript tables, and a
  figure manifest from checked result files.
- Package-backed paths are labeled explicitly for wind, generator, converters,
  hydrokinetic, diesel, hydrogen, and desalination blocks. Wave/WEC and reduced
  platform paths are labeled as surrogate or reduced dynamics where appropriate.
- SIRENO-lite comparison outputs distinguish the legacy reference simulator from
  the ontology-backed SIRENOpt path and save both time-series and metric tables.
- Long examples, paper regressions, and profiling are opt-in and documented, so
  default `Pkg.test()` style workflows remain fast.

## Evidence Files

- `examples/minimal_ontology_workflow.jl` exercises the public build, audit,
  simulate, optimize, replay, and report workflow.
- `examples/multilevel_collocation_hybrid_demo.jl` is the final fast
  motion-coupled collocation acceptance fixture.
- `examples/sirenolite_comparison_fixture.jl` regenerates the reference-vs-
  ontology comparison tables and plot.
- `examples/snow_examples_block_api.jl` records the migrated SNOW example paths
  and replay summaries.
- `examples/run_long_regressions.jl` and `test/long_runtests.jl` gate long
  examples behind `SIRENOPT_RUN_LONG_TESTS=1`.
- `scripts/profile_hot_kernels.jl` profiles the ontology kernels without
  plotting or solver-side mutation.
- `docs/src/quickstart.md`, `docs/src/api.md`, and
  `docs/src/design/ontology-v1-conventions.md` describe the public API, model
  paths, formulation choices, units, signs, and verification commands.

## Verification Commands

The final code-bearing acceptance chunk was checked with:

```sh
julia --project=. test/runtests.jl
```

Result: default tier passed with 427 tests and no failures.

The final multi-level acceptance fixture was checked with a focused replay smoke
that included terminal SOC and WEC PTO residual evidence:

```sh
julia --project=. -e 'using Test; include("examples/multilevel_collocation_hybrid_demo.jl")'
```

Result: terminal SOC returned to its initial value and maximum registered
constraint violation was `2.220446049250313e-16`.

The documentation was checked after this audit note was added with:

```sh
julia --project=docs docs/make.jl
```

Result: build passed.

Whitespace and patch hygiene were checked with:

```sh
git diff --check
```

Result: no whitespace errors.

## Remaining Reservations

- `FullSIRENOptOntology` is intentionally not an alias yet. The current full
  goal is satisfied by documented builders plus opt-in package-backed subsystems
  and reduced fallback physics; the full name should wait for package-backed
  WEC/PTO, hydrodynamic, and mooring blocks.
- Long-regression and manuscript-scale cases are runnable but environment-gated
  by design. They are release evidence, not default test requirements.
