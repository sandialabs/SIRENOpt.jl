# # Pendulum Platform Ontology Tutorial
#
# This notebook walks through the reduced pendulum platform example without
# hiding the setup behind local helper functions. It shows the building blocks
# that matter to a new user:
#
# 1. define a short motion-coupled scenario,
# 2. make a parameter table with `OptimizationParameters.jl`,
# 3. pass those parameters into the existing ontology builder,
# 4. inspect the graph, ports, variables, residuals, bounds, and constraints,
# 5. run `optimize`, `replay`, and `report`,
# 6. save plots that are pulled into the documentation, and
# 7. reuse the same parameter table for another fidelity/horizon assembly.
#
# The dynamic platform here is the V1 reduced pendulum fallback. It is useful
# for learning the ontology flow and testing force-motion coupling; it is not a
# validated hydrodynamic or mooring solve.

ENV["GKSwstype"] = "100"

using SIRENOpt
using OptimizationParameters
using Plots

# The notebook can be run from the repository root, from `docs/literate`, or
# from the generated notebook location. The checks below keep output paths
# stable without requiring a custom setup function.

repo_root = abspath(joinpath(@__DIR__, "..", ".."))
if !isfile(joinpath(repo_root, "Project.toml")) || !isdir(joinpath(repo_root, "src"))
    repo_root = abspath(joinpath(@__DIR__, "..", "..", ".."))
end
if !isfile(joinpath(repo_root, "Project.toml")) || !isdir(joinpath(repo_root, "src"))
    repo_root = pwd()
end

plot_dir = get(ENV, "SIRENOPT_TUTORIAL_OUTPUT_DIR",
    joinpath(repo_root, "docs", "src", "generated", "pendulum_platform_tutorial"))
report_dir = get(ENV, "SIRENOPT_TUTORIAL_REPORT_DIR",
    joinpath(repo_root, "docs", "src", "generated", "pendulum_platform_tutorial", "reports"))
mkpath(plot_dir)
mkpath(report_dir);

# ## 1. Scenario: a tiny motion-coupled resource window
#
# Keep the first run short. Three one-minute intervals are enough to see
# platform pitch feed back into wind availability while keeping the generated
# documentation fast.

scenario = ShortHorizonScenario(
    name = :pendulum_tutorial_short,
    horizon_s = 180.0,
    dt_s = 60.0,
    solar_irradiance_kw_per_m2 = [0.16, 0.14, 0.12],
    wind_speed_m_s = [8.0, 8.0, 8.0],
    wave_power_flux_kw_per_m = [1.0, 1.0, 1.0],
    hydrokinetic_current_m_s = [2.0, 2.0, 2.0],
    load_kw = [1.4, 1.5, 1.4],
    initial_battery_soc = 0.70,
    provenance_note = "Literate pendulum platform ontology tutorial",
);

# ## 2. Parameters: one table for model settings and optimization variables
#
# `OptimizationParameters.jl` separates a physical initial value from scaling,
# bounds, and whether the parameter is an active design variable. That mirrors
# the larger SNOW examples while staying compact enough to inspect by eye.

parameters = (
    solar_area_m2 = OptimizationParameter(10.0;
        lb = 2.0, ub = 40.0, scaling = 1.0 / 20.0, dv = true,
        description = "Solar collection area used by the ontology builder"),
    battery_capacity_kwh = OptimizationParameter(5.0;
        lb = 1.0, ub = 20.0, scaling = 1.0 / 10.0, dv = true,
        description = "Battery energy capacity"),
    battery_power_kw = OptimizationParameter(3.0;
        lb = 0.5, ub = 10.0, scaling = 1.0 / 5.0, dv = false,
        description = "Battery charge/discharge power rating"),
    wind_rated_power_kw = OptimizationParameter(4.0;
        lb = 0.5, ub = 15.0, scaling = 1.0 / 8.0, dv = true,
        description = "Wind rotor package boundary rating"),
    wave_capture_width_m = OptimizationParameter(2.0;
        lb = 0.2, ub = 8.0, scaling = 1.0 / 4.0, dv = true,
        description = "Wave/WEC surrogate capture width"),
    wave_rated_power_kw = OptimizationParameter(2.0;
        lb = 0.2, ub = 8.0, scaling = 1.0 / 4.0, dv = false,
        description = "Wave/WEC surrogate PTO rating"),
    hydrokinetic_rated_power_kw = OptimizationParameter(3.0;
        lb = 0.5, ub = 12.0, scaling = 1.0 / 6.0, dv = true,
        description = "Hydrokinetic rotor/generator/converter rating"),
    hydrokinetic_rotor_diameter_m = OptimizationParameter(2.0;
        lb = 0.5, ub = 5.0, scaling = 1.0 / 3.0, dv = false,
        description = "Hydrokinetic rotor diameter"),
    platform_inertia_kg_m2 = OptimizationParameter(1.0e5;
        lb = 2.0e4, ub = 5.0e5, scaling = 1.0 / 1.0e5, dv = true,
        description = "Reduced pendulum pitch inertia"),
    platform_stiffness_nm_per_rad = OptimizationParameter(0.0;
        lb = 0.0, ub = 5.0e4, scaling = 1.0 / 1.0e4, dv = false,
        description = "Optional linear pitch restoring stiffness"),
    platform_damping_nm_s_per_rad = OptimizationParameter(0.0;
        lb = 0.0, ub = 2.0e5, scaling = 1.0 / 1.0e5, dv = false,
        description = "Optional linear pitch damping"),
    wind_platform_moment_per_kw_nm = OptimizationParameter(500.0;
        lb = 50.0, ub = 1200.0, scaling = 1.0 / 500.0, dv = false,
        description = "Pitch moment per kW of wind bus power"),
)

x0_scaled, lower_scaled, upper_scaled = assemble_input(parameters)
parameter_values = get_values(parameters, x0_scaled)
active_parameter_names = [name for name in propertynames(parameters) if get_dv(parameters, name)]

parameter_table = [(
    name = name,
    physical_initial = get_x0(parameters, name),
    lower = get_lb(parameters, name),
    upper = get_ub(parameters, name),
    scaling = get_scaling(parameters, name),
    active_design_variable = get_dv(parameters, name) ? "yes" : "no",
) for name in propertynames(parameters)]

parameter_table

# ## 3. Build the pendulum ontology
#
# `DynamicMultilevelHybridOntology` is the existing ontology template. The
# keyword arguments below are the model parameters from the table above. Setting
# `include_hydrokinetic=true` adds a second package-backed rotor chain so the
# model-path table includes both wind and hydrokinetic package boundaries.

system = DynamicMultilevelHybridOntology(
    scenario = scenario,
    include_hydrokinetic = true,
    solar_area_m2 = parameter_values.solar_area_m2,
    battery_capacity_kwh = parameter_values.battery_capacity_kwh,
    battery_power_kw = parameter_values.battery_power_kw,
    wind_rated_power_kw = parameter_values.wind_rated_power_kw,
    wave_capture_width_m = parameter_values.wave_capture_width_m,
    wave_rated_power_kw = parameter_values.wave_rated_power_kw,
    hydrokinetic_rated_power_kw = parameter_values.hydrokinetic_rated_power_kw,
    hydrokinetic_rotor_diameter_m = parameter_values.hydrokinetic_rotor_diameter_m,
    platform_inertia_kg_m2 = parameter_values.platform_inertia_kg_m2,
    platform_stiffness_nm_per_rad = parameter_values.platform_stiffness_nm_per_rad,
    platform_damping_nm_s_per_rad = parameter_values.platform_damping_nm_s_per_rad,
    wind_platform_moment_per_kw_nm = parameter_values.wind_platform_moment_per_kw_nm,
)

description = describe(system)
component_table(system)

# Model-path labels are important in multi-fidelity work. They say which blocks
# are package-backed, prescribed, surrogate, or hard residual equations.

model_path_table(system)

# ## 4. Audit the graph before running anything
#
# The audit tells us what the ontology will expose under a formulation. Here the
# formulation is collocation with terminal SOC equal to the initial SOC, so a
# terminal battery residual is registered.

formulation = Collocation(terminal_soc_equal_initial = true)
system_audit = audit(system, scenario; formulation = formulation)

first(system_audit.port_table, min(8, length(system_audit.port_table)))

#-

first(system_audit.variable_table, min(10, length(system_audit.variable_table)))

#-

filter(row -> row.owner in (:platform, :battery, :wave_wec, :bus),
    system_audit.residual_table)

# ## 5. Assemble the optimization vectors
#
# `assemble` is the bridge from block metadata to the numerical arrays that an
# optimizer sees. The registry records owner/name/time index for each vector
# entry, plus lower/upper bounds and residual bounds.

model = assemble(system, scenario, formulation)

(
    variable_count = length(model.x0),
    constraint_count = length(model.constraint_lower_bounds),
)

#-

first(variable_table(model.registry), 12)

#-

design_rows = filter(row -> row.role == :design, variable_table(model.registry))
state_rows = filter(row -> row.role == :state, variable_table(model.registry))
control_rows = filter(row -> row.role == :control, variable_table(model.registry))

(
    design_variables = length(design_rows),
    state_variables = length(state_rows),
    control_variables = length(control_rows),
)

# ## 6. Optimize, replay, and report
#
# The small deterministic solve fills a feasible collocation vector for this
# tutorial-sized case. `replay` then rebuilds the physical time series from the
# chosen controls and states. `report` writes CSVs and SVGs from the metadata.

result = optimize(system, scenario; formulation = formulation)
replayed = replay(result)
reported = report(result, report_dir)

result.replay_summary

# ## 7. Save tutorial plots
#
# These are simple teaching plots. The standard ontology report also writes its
# own SVGs in `report_dir`, but these smaller figures focus on power balance,
# platform motion, and variable layout.

times_min = [row.time_s / 60.0 for row in result.timeseries]
state_times_min = [row.time_s / 60.0 for row in result.states]

solar_bus = [row.solar_bus_power_kw for row in result.timeseries]
wind_bus = [row.wind_bus_power_kw for row in result.timeseries]
wave_bus = [row.wave_bus_power_kw for row in result.timeseries]
hydro_bus = [row.hydrokinetic_bus_power_kw for row in result.timeseries]
battery_bus = [row.battery_bus_power_kw for row in result.timeseries]
load_bus = [-row.load_bus_power_kw for row in result.timeseries]

theta = [row.platform_theta_rad for row in result.states]
omega = [row.platform_omega_rad_s for row in result.states]
soc = [row.battery_soc for row in result.states]

role_names = ["design", "state", "control"]
role_counts = [length(design_rows), length(state_rows), length(control_rows)]

power_plot = Plots.plot(times_min, [solar_bus wind_bus wave_bus hydro_bus battery_bus load_bus];
    label = ["solar bus" "wind bus" "wave bus" "hydro bus" "battery bus" "load demand"],
    xlabel = "time (min)", ylabel = "kW", linewidth = 2,
    title = "Pendulum tutorial power balance")
power_plot_path = joinpath(plot_dir, "pendulum_power_balance.svg")
Plots.savefig(power_plot, power_plot_path)

motion_plot = Plots.plot(state_times_min, [theta omega soc];
    label = ["platform theta (rad)" "platform omega (rad/s)" "battery SOC"],
    xlabel = "time (min)", ylabel = "state value", linewidth = 2,
    title = "Reduced pendulum state replay")
motion_plot_path = joinpath(plot_dir, "pendulum_motion_states.svg")
Plots.savefig(motion_plot, motion_plot_path)

layout_plot = Plots.bar(role_names, role_counts;
    label = "", xlabel = "registry role", ylabel = "count",
    title = "Assembled optimization variables")
layout_plot_path = joinpath(plot_dir, "pendulum_registry_layout.svg")
Plots.savefig(layout_plot, layout_plot_path)

(
    power_plot = relpath(power_plot_path, repo_root),
    motion_plot = relpath(motion_plot_path, repo_root),
    layout_plot = relpath(layout_plot_path, repo_root),
)

# ![](../generated/pendulum_platform_tutorial/pendulum_power_balance.svg)
#
# ![](../generated/pendulum_platform_tutorial/pendulum_motion_states.svg)
#
# ![](../generated/pendulum_platform_tutorial/pendulum_registry_layout.svg)

# ## 8. Reuse the same parameter table across fidelity and horizon
#
# The next simplest use case is not hand-packing a callback. It is selecting an
# ontology template, passing model parameters, and letting `assemble` build the
# vector layout for the chosen formulation. Below, the same parameter table is
# reused for a short high-fidelity-ish graph with hydrokinetic enabled and a
# longer reduced graph with hydrokinetic disabled. Both are assembled with the
# same formulation.

hourly_scenario = ShortHorizonScenario(
    name = :pendulum_tutorial_hourly,
    horizon_s = 6 * 3600.0,
    dt_s = 3600.0,
    solar_irradiance_kw_per_m2 = [0.05, 0.20, 0.50, 0.65, 0.35, 0.10],
    wind_speed_m_s = [7.0, 7.6, 8.1, 8.5, 8.0, 7.4],
    wave_power_flux_kw_per_m = fill(1.0, 6),
    hydrokinetic_current_m_s = fill(2.0, 6),
    load_kw = fill(1.4, 6),
    initial_battery_soc = 0.70,
    provenance_note = "Longer horizon tutorial assembly",
)

short_package_graph = system

hourly_reduced_graph = DynamicMultilevelHybridOntology(
    scenario = hourly_scenario,
    include_hydrokinetic = false,
    solar_area_m2 = parameter_values.solar_area_m2,
    battery_capacity_kwh = parameter_values.battery_capacity_kwh,
    battery_power_kw = parameter_values.battery_power_kw,
    wind_rated_power_kw = parameter_values.wind_rated_power_kw,
    wave_capture_width_m = parameter_values.wave_capture_width_m,
    wave_rated_power_kw = parameter_values.wave_rated_power_kw,
    platform_inertia_kg_m2 = parameter_values.platform_inertia_kg_m2,
    platform_stiffness_nm_per_rad = parameter_values.platform_stiffness_nm_per_rad,
    platform_damping_nm_s_per_rad = parameter_values.platform_damping_nm_s_per_rad,
    wind_platform_moment_per_kw_nm = parameter_values.wind_platform_moment_per_kw_nm,
)

short_package_model = assemble(short_package_graph, scenario, formulation)
hourly_reduced_model = assemble(hourly_reduced_graph, hourly_scenario, formulation)

horizon_and_fidelity_table = [
    (
        case = :short_package_graph,
        horizon_s = scenario.time_grids.main.horizon_s,
        dt_s = scenario.time_grids.main.dt_s,
        blocks = length(component_table(short_package_graph)),
        package_backed_blocks = count(row -> row.model_path == :package_backed,
            model_path_table(short_package_graph)),
        variables = length(short_package_model.x0),
        constraints = length(short_package_model.constraint_lower_bounds),
    ),
    (
        case = :hourly_reduced_graph,
        horizon_s = hourly_scenario.time_grids.main.horizon_s,
        dt_s = hourly_scenario.time_grids.main.dt_s,
        blocks = length(component_table(hourly_reduced_graph)),
        package_backed_blocks = count(row -> row.model_path == :package_backed,
            model_path_table(hourly_reduced_graph)),
        variables = length(hourly_reduced_model.x0),
        constraints = length(hourly_reduced_model.constraint_lower_bounds),
    ),
]

horizon_and_fidelity_table

# The important pattern is that the user-level code stayed declarative. The
# parameter table carried scaling and design-variable activation; the ontology
# builder selected model fidelity; and `assemble` generated the optimizer-facing
# variable and residual layout for each horizon.
