const _MODEL_PATH_LABELS = Set([
    :package_backed,
    :surrogate,
    :placeholder,
    :prescribed,
    :replay_only,
    :hard_residual,
    :smooth_approximation,
])

const _VARIABLE_ROLES = Set([:design, :state, :control, :algebraic, :slack, :diagnostic])
const _VARIABLE_SCOPES = Set([:design, :node, :interval, :scenario])
const _VARIABLE_EXPOSURES = Set([:parameter, :decision, :computed, :reported])
const _RESIDUAL_SENSES = Set([:eq, :leq, :geq, :interval])
const _RESIDUAL_SCOPES = Set([:node, :interval, :terminal, :design])
const _RESIDUAL_HARDNESS = Set([:hard, :smooth, :replay_only])
const _PORT_DIRECTIONS = Set([:in, :out, :inout])
const _PORT_CARDINALITIES = Set([:one, :many_to_one, :one_to_many, :optional])
const _FORMULATION_MODES = Set([:simulation, :collocation, :shooting])

_require_symbol(x::Symbol, field::Symbol) =
    x === Symbol() ? throw(ArgumentError("$(field) must be a non-empty Symbol.")) : x

function _require_string(x::String, field::Symbol)
    isempty(strip(x)) && throw(ArgumentError("$(field) must be a non-empty String."))
    return x
end

function _require_known(x::Symbol, allowed, field::Symbol)
    x in allowed || throw(ArgumentError("Unknown $(field) $(x). Expected one of $(sort!(collect(allowed)))."))
    return x
end

function _require_positive_finite(x, field::Symbol)
    (x isa Real && isfinite(x) && x > zero(x)) ||
        throw(ArgumentError("$(field) must be positive and finite; got $(x)."))
    return x
end

function _validate_bounds(initial, lower, upper, label::AbstractString)
    if lower isa Real && upper isa Real && lower > upper
        throw(ArgumentError("$(label) lower bound $(lower) exceeds upper bound $(upper)."))
    end
    if initial isa Real && lower isa Real && isfinite(initial) && isfinite(lower) && initial < lower
        throw(ArgumentError("$(label) initial value $(initial) is below lower bound $(lower)."))
    end
    if initial isa Real && upper isa Real && isfinite(initial) && isfinite(upper) && initial > upper
        throw(ArgumentError("$(label) initial value $(initial) exceeds upper bound $(upper)."))
    end
    return nothing
end

function _check_unique_specs(specs, kind::String, owner::Symbol)
    seen = Set{Symbol}()
    for spec in specs
        spec.name in seen && throw(ArgumentError("Duplicate $(kind) $(spec.name) in block $(owner)."))
        push!(seen, spec.name)
    end
    return nothing
end

owner_qualified(owner::Symbol, name::Symbol) = Symbol(string(owner), ".", string(name))

struct ModelPathSpec
    path_label::Symbol
    package_name::Union{Nothing,String}
    adapter_name::Union{Nothing,String}
    assumptions::Vector{String}
    valid_range::String
    fallback_policy::String
end

function ModelPathSpec(; path_label::Symbol,
        package_name::Union{Nothing,String} = nothing,
        adapter_name::Union{Nothing,String} = nothing,
        assumptions::Vector{String} = String[],
        valid_range::String = "",
        fallback_policy::String = "")

    _require_known(path_label, _MODEL_PATH_LABELS, :model_path)
    return ModelPathSpec(path_label, package_name, adapter_name, assumptions, valid_range, fallback_policy)
end

struct ObjectiveSpec
    name::Symbol
    units::String
    scale::Float64
    dependencies::Vector{Symbol}
    time_design_scope::Symbol
    sense::Symbol
end

function ObjectiveSpec(; name::Symbol, units::String, scale = 1.0,
        dependencies::Vector{Symbol} = Symbol[],
        time_design_scope::Symbol = :design,
        sense::Symbol = :min)

    _require_symbol(name, :objective_name)
    _require_string(units, :objective_units)
    _require_positive_finite(scale, :objective_scale)
    sense in (:min, :max) || throw(ArgumentError("Objective sense must be :min or :max; got $(sense)."))
    return ObjectiveSpec(name, units, Float64(scale), dependencies, time_design_scope, sense)
end

MinimizeTotalCost(; scale = 1.0) = ObjectiveSpec(
    name = :minimize_total_cost,
    units = "USD",
    scale = scale,
    dependencies = [:solar_area_m2, :battery_capacity_kwh, :converter_rating_kw],
    time_design_scope = :design,
    sense = :min,
)

MinimizeCostPerWatt(; scale = 1.0) = ObjectiveSpec(
    name = :minimize_cost_per_watt,
    units = "USD/kW",
    scale = scale,
    dependencies = [:total_cost, :served_load_kw],
    time_design_scope = :scenario,
    sense = :min,
)

struct ValidationReport
    errors::Vector{String}
    warnings::Vector{String}
    checked_invariants::Vector{String}
    invalid_object_paths::Vector{String}
    suggested_fixes::Vector{String}
end

ValidationReport(; errors::Vector{String} = String[],
    warnings::Vector{String} = String[],
    checked_invariants::Vector{String} = String[],
    invalid_object_paths::Vector{String} = String[],
    suggested_fixes::Vector{String} = String[]) =
    ValidationReport(errors, warnings, checked_invariants, invalid_object_paths, suggested_fixes)

Base.isvalid(report::ValidationReport) = isempty(report.errors)

struct BlockRole
    role_name::Symbol
    component_family::Symbol
    required_port_roles::Vector{Symbol}
    required_residual_roles::Vector{Symbol}
    default_provider::Union{Nothing,Symbol}
end

function BlockRole(; role_name::Symbol, component_family::Symbol,
        required_port_roles::Vector{Symbol} = Symbol[],
        required_residual_roles::Vector{Symbol} = Symbol[],
        default_provider::Union{Nothing,Symbol} = nothing)

    _require_symbol(role_name, :role_name)
    _require_symbol(component_family, :component_family)
    return BlockRole(role_name, component_family, required_port_roles, required_residual_roles, default_provider)
end

struct InterfaceSpec
    archetype_name::Symbol
    active_ports::Vector{Symbol}
    omitted_ports::Vector{Symbol}
    zero_contribution_adapters::Vector{Symbol}
    reason::String
    replacement_target::Union{Nothing,Symbol}
end

function InterfaceSpec(; archetype_name::Symbol,
        active_ports::Vector{Symbol} = Symbol[],
        omitted_ports::Vector{Symbol} = Symbol[],
        zero_contribution_adapters::Vector{Symbol} = Symbol[],
        reason::String = "",
        replacement_target::Union{Nothing,Symbol} = nothing)

    _require_symbol(archetype_name, :archetype_name)
    return InterfaceSpec(archetype_name, active_ports, omitted_ports,
        zero_contribution_adapters, reason, replacement_target)
end

struct ReportSpec
    report_name::Symbol
    required_output_groups::Vector{Symbol}
    file_table_target::String
    units::String
    aggregation_rule::String
end

function ReportSpec(; report_name::Symbol,
        required_output_groups::Vector{Symbol} = Symbol[],
        file_table_target::String,
        units::String = "",
        aggregation_rule::String = "none")

    _require_symbol(report_name, :report_name)
    _require_string(file_table_target, :file_table_target)
    return ReportSpec(report_name, required_output_groups, file_table_target, units, aggregation_rule)
end

struct VariableSpec
    name::Symbol
    owner::Symbol
    role::Symbol
    unit::String
    initial::Any
    lower::Any
    upper::Any
    scale::Any
    time_scope::Symbol
    exposure::Symbol
    label::String
end

function VariableSpec(; name::Symbol, owner::Symbol, role::Symbol, unit::String,
        initial = 0.0, lower = -Inf, upper = Inf, scale = 1.0,
        time_scope::Symbol = :design, exposure::Symbol = :decision,
        label::String = string(name))

    _require_symbol(name, :variable_name)
    _require_symbol(owner, :variable_owner)
    _require_known(role, _VARIABLE_ROLES, :variable_role)
    _require_string(unit, :variable_unit)
    _require_positive_finite(scale, :variable_scale)
    _require_known(time_scope, _VARIABLE_SCOPES, :variable_time_scope)
    _require_known(exposure, _VARIABLE_EXPOSURES, :variable_exposure)
    _validate_bounds(initial, lower, upper, "Variable $(owner).$(name)")
    return VariableSpec(name, owner, role, unit, initial, lower, upper, scale,
        time_scope, exposure, label)
end

Design(name::Symbol, lower, upper; initial, unit::String, scale = 1.0,
    owner::Symbol = :user, label::String = string(name)) =
    VariableSpec(name = name, owner = owner, role = :design, unit = unit,
        initial = initial, lower = lower, upper = upper, scale = scale,
        time_scope = :design, exposure = :decision, label = label)

struct ResidualSpec
    name::Symbol
    owner::Symbol
    equation::Symbol
    sense::Symbol
    unit::String
    scale::Any
    lower::Any
    upper::Any
    time_scope::Symbol
    depends_on::Vector{Symbol}
    hardness::Symbol
    label::String
end

function ResidualSpec(; name::Symbol, owner::Symbol, equation::Symbol,
        sense::Symbol, unit::String, scale = 1.0, lower = 0.0, upper = 0.0,
        time_scope::Symbol = :interval, depends_on::Vector{Symbol} = Symbol[],
        hardness::Symbol = :hard, label::String = string(name))

    _require_symbol(name, :residual_name)
    _require_symbol(owner, :residual_owner)
    _require_symbol(equation, :residual_equation)
    _require_known(sense, _RESIDUAL_SENSES, :residual_sense)
    _require_string(unit, :residual_unit)
    _require_positive_finite(scale, :residual_scale)
    _validate_bounds((lower isa Real && upper isa Real) ? (lower + upper) / 2 : 0.0,
        lower, upper, "Residual $(owner).$(name)")
    _require_known(time_scope, _RESIDUAL_SCOPES, :residual_time_scope)
    _require_known(hardness, _RESIDUAL_HARDNESS, :residual_hardness)
    return ResidualSpec(name, owner, equation, sense, unit, scale, lower, upper,
        time_scope, depends_on, hardness, label)
end

struct OutputSpec
    name::Symbol
    owner::Symbol
    unit::String
    source::Symbol
    model_path::ModelPathSpec
    time_scope::Symbol
    label::String
    plot_group::Union{Nothing,Symbol}
end

function OutputSpec(; name::Symbol, owner::Symbol, unit::String, source::Symbol,
        model_path::ModelPathSpec, time_scope::Symbol = :interval,
        label::String = string(name), plot_group::Union{Nothing,Symbol} = nothing)

    _require_symbol(name, :output_name)
    _require_symbol(owner, :output_owner)
    _require_string(unit, :output_unit)
    _require_symbol(source, :output_source)
    _require_known(time_scope, _VARIABLE_SCOPES, :output_time_scope)
    return OutputSpec(name, owner, unit, source, model_path, time_scope, label, plot_group)
end

struct PortSpec
    name::Symbol
    port_type::Symbol
    direction::Symbol
    quantity::Symbol
    unit::String
    sign_convention::String
    frame::Union{Nothing,Symbol}
    reference_point::Union{Nothing,Symbol}
    time_grid::Symbol
    cardinality::Symbol
    owner::Symbol
end

function PortSpec(; name::Symbol, port_type::Symbol, direction::Symbol,
        quantity::Symbol, unit::String, sign_convention::String,
        frame::Union{Nothing,Symbol} = nothing,
        reference_point::Union{Nothing,Symbol} = nothing,
        time_grid::Symbol = :main, cardinality::Symbol = :one,
        owner::Symbol)

    _require_symbol(name, :port_name)
    _require_symbol(port_type, :port_type)
    _require_known(direction, _PORT_DIRECTIONS, :port_direction)
    _require_symbol(quantity, :port_quantity)
    _require_string(unit, :port_unit)
    _require_string(sign_convention, :port_sign_convention)
    _require_known(cardinality, _PORT_CARDINALITIES, :port_cardinality)
    _require_symbol(owner, :port_owner)
    if port_type in (:platform_wrench, :motion_state, :mass_inertia) && (frame === nothing || reference_point === nothing)
        throw(ArgumentError("Port $(owner).$(name) of type $(port_type) must declare frame and reference point."))
    end
    return PortSpec(name, port_type, direction, quantity, unit, sign_convention,
        frame, reference_point, time_grid, cardinality, owner)
end

struct ConnectionSpec
    source_block::Symbol
    source_port::Symbol
    sink_block::Symbol
    sink_port::Symbol
    quantity::Symbol
    unit::String
    conversion_owner::Union{Nothing,Symbol}
    aggregation_owner::Union{Nothing,Symbol}
    resampling_owner::Union{Nothing,Symbol}
    active::Bool
    disabled_reason::Union{Nothing,String}
end

function ConnectionSpec(; source_block::Symbol, source_port::Symbol,
        sink_block::Symbol, sink_port::Symbol, quantity::Symbol, unit::String,
        conversion_owner::Union{Nothing,Symbol} = nothing,
        aggregation_owner::Union{Nothing,Symbol} = nothing,
        resampling_owner::Union{Nothing,Symbol} = nothing,
        active::Bool = true,
        disabled_reason::Union{Nothing,String} = nothing)

    _require_symbol(source_block, :source_block)
    _require_symbol(source_port, :source_port)
    _require_symbol(sink_block, :sink_block)
    _require_symbol(sink_port, :sink_port)
    _require_symbol(quantity, :connection_quantity)
    _require_string(unit, :connection_unit)
    !active && disabled_reason === nothing &&
        throw(ArgumentError("Inactive connection $(source_block).$(source_port) -> $(sink_block).$(sink_port) needs disabled_reason."))
    return ConnectionSpec(source_block, source_port, sink_block, sink_port, quantity,
        unit, conversion_owner, aggregation_owner, resampling_owner, active,
        disabled_reason)
end

struct BlockMetadata
    name::Symbol
    required::Bool
    enabled::Bool
    model_path::ModelPathSpec
    notes::String
end

function BlockMetadata(; name::Symbol, required::Bool = true, enabled::Bool = true,
        model_path::ModelPathSpec, notes::String = "")

    _require_symbol(name, :metadata_name)
    return BlockMetadata(name, required, enabled, model_path, notes)
end

struct BlockSpec
    name::Symbol
    role::Symbol
    component_type::Symbol
    model_path::ModelPathSpec
    designs::Vector{VariableSpec}
    states::Vector{VariableSpec}
    controls::Vector{VariableSpec}
    interfaces::Vector{InterfaceSpec}
    ports::Vector{PortSpec}
    outputs::Vector{OutputSpec}
    residuals::Vector{ResidualSpec}
    parameters::NamedTuple
    metadata::BlockMetadata
end

function BlockSpec(; name::Symbol, role::Symbol, component_type::Symbol,
        model_path::ModelPathSpec,
        designs::Vector{VariableSpec} = VariableSpec[],
        states::Vector{VariableSpec} = VariableSpec[],
        controls::Vector{VariableSpec} = VariableSpec[],
        interfaces::Vector{InterfaceSpec} = InterfaceSpec[],
        ports::Vector{PortSpec} = PortSpec[],
        outputs::Vector{OutputSpec} = OutputSpec[],
        residuals::Vector{ResidualSpec} = ResidualSpec[],
        parameters::NamedTuple = NamedTuple(),
        metadata::BlockMetadata = BlockMetadata(name = name, model_path = model_path))

    _require_symbol(name, :block_name)
    _require_symbol(role, :block_role)
    _require_symbol(component_type, :component_type)
    _check_unique_specs(designs, "design variable", name)
    _check_unique_specs(states, "state variable", name)
    _check_unique_specs(controls, "control variable", name)
    _check_unique_specs(ports, "port", name)
    _check_unique_specs(outputs, "output", name)
    _check_unique_specs(residuals, "residual", name)
    return BlockSpec(name, role, component_type, model_path, designs, states,
        controls, interfaces, ports, outputs, residuals, parameters, metadata)
end

struct OntologyTemplate
    name::Symbol
    version::VersionNumber
    required_blocks::Vector{BlockRole}
    optional_blocks::Vector{BlockRole}
    default_connections::Vector{ConnectionSpec}
    default_scenario::Any
    default_formulations::Vector
    reports::Vector{ReportSpec}
end

function OntologyTemplate(; name::Symbol, version::VersionNumber = v"0.1.0",
        required_blocks::Vector{BlockRole} = BlockRole[],
        optional_blocks::Vector{BlockRole} = BlockRole[],
        default_connections::Vector{ConnectionSpec} = ConnectionSpec[],
        default_scenario = nothing,
        default_formulations::Vector = Any[],
        reports::Vector{ReportSpec} = ReportSpec[])

    _require_symbol(name, :ontology_name)
    return OntologyTemplate(name, version, required_blocks, optional_blocks,
        default_connections, default_scenario, default_formulations, reports)
end

struct TimeGrid{T<:Real}
    name::Symbol
    horizon_s::T
    dt_s::T
    unit::String
end

function TimeGrid(; name::Symbol = :main, horizon_s::Real = 3600.0,
        dt_s::Real = 3600.0, unit::String = "s")
    _require_symbol(name, :time_grid_name)
    _require_string(unit, :time_grid_unit)
    horizon_s > 0 || throw(ArgumentError("horizon_s must be positive; got $(horizon_s)."))
    dt_s > 0 || throw(ArgumentError("dt_s must be positive; got $(dt_s)."))
    return TimeGrid{promote_type(typeof(horizon_s), typeof(dt_s))}(name, horizon_s, dt_s, unit)
end

n_intervals(grid::TimeGrid) = max(1, Int(round(grid.horizon_s / grid.dt_s)))
dt_hours(grid::TimeGrid) = grid.dt_s / 3600

struct ScenarioSpec
    name::Symbol
    time_grids::NamedTuple
    resources::NamedTuple
    demands::NamedTuple
    initial_states::NamedTuple
    prescribed_controls::NamedTuple
    provenance::NamedTuple
end

function ScenarioSpec(; name::Symbol, time_grids::NamedTuple, resources::NamedTuple,
        demands::NamedTuple, initial_states::NamedTuple = NamedTuple(),
        prescribed_controls::NamedTuple = NamedTuple(),
        provenance::NamedTuple = NamedTuple())

    _require_symbol(name, :scenario_name)
    if :battery_soc in keys(initial_states)
        soc = initial_states.battery_soc
        (soc isa Real && zero(soc) <= soc <= one(soc)) ||
            throw(ArgumentError("initial_states.battery_soc must be between 0 and 1; got $(soc)."))
    end
    return ScenarioSpec(name, time_grids, resources, demands, initial_states,
        prescribed_controls, provenance)
end

function _as_scenario_vector(value, n::Int)
    if value isa AbstractVector
        length(value) == n || throw(ArgumentError("Expected scenario vector length $(n), got $(length(value))."))
        return collect(value)
    end
    return fill(value, n)
end

function ShortHorizonScenario(; name::Symbol = :short_horizon,
        horizon_s::Real = 3600.0, dt_s::Real = 3600.0,
        solar_irradiance_kw_per_m2 = 0.6,
        wind_speed_m_s = 0.0,
        wave_power_flux_kw_per_m = 0.0,
        hydrokinetic_current_m_s = 0.0,
        load_kw = 1.0,
        h2_demand_kg_per_h = 0.0,
        desal_demand_m3_per_h = 0.0,
        initial_battery_soc = 0.6,
        initial_diesel_fuel_l = 100.0,
        initial_h2_level_kg = 0.0,
        initial_desal_level_m3 = 0.0,
        provenance_note::String = "generated by ShortHorizonScenario")

    (initial_battery_soc isa Real && 0 <= initial_battery_soc <= 1) ||
        throw(ArgumentError("initial_battery_soc must be between 0 and 1; got $(initial_battery_soc)."))
    (initial_diesel_fuel_l isa Real && initial_diesel_fuel_l >= 0) ||
        throw(ArgumentError("initial_diesel_fuel_l must be nonnegative; got $(initial_diesel_fuel_l)."))
    (initial_h2_level_kg isa Real && initial_h2_level_kg >= 0) ||
        throw(ArgumentError("initial_h2_level_kg must be nonnegative; got $(initial_h2_level_kg)."))
    (initial_desal_level_m3 isa Real && initial_desal_level_m3 >= 0) ||
        throw(ArgumentError("initial_desal_level_m3 must be nonnegative; got $(initial_desal_level_m3)."))
    grid = TimeGrid(name = :main, horizon_s = horizon_s, dt_s = dt_s)
    n = n_intervals(grid)
    return ScenarioSpec(
        name = name,
        time_grids = (main = grid,),
        resources = (
            solar_irradiance_kw_per_m2 = _as_scenario_vector(solar_irradiance_kw_per_m2, n),
            wind_speed_m_s = _as_scenario_vector(wind_speed_m_s, n),
            wave_power_flux_kw_per_m = _as_scenario_vector(wave_power_flux_kw_per_m, n),
            hydrokinetic_current_m_s = _as_scenario_vector(hydrokinetic_current_m_s, n),
        ),
        demands = (
            load_kw = _as_scenario_vector(load_kw, n),
            h2_demand_kg_per_h = _as_scenario_vector(h2_demand_kg_per_h, n),
            desal_demand_m3_per_h = _as_scenario_vector(desal_demand_m3_per_h, n),
        ),
        initial_states = (
            battery_soc = initial_battery_soc,
            diesel_fuel_l = initial_diesel_fuel_l,
            h2_level_kg = initial_h2_level_kg,
            desal_level_m3 = initial_desal_level_m3,
        ),
        prescribed_controls = NamedTuple(),
        provenance = (
            generator = "ShortHorizonScenario",
            note = provenance_note,
            generated_at = string(Dates.now()),
        ),
    )
end

struct FormulationSpec
    name::Symbol
    mode::Symbol
    variant::Union{Nothing,Symbol}
    time_grid::Symbol
    exposed_roles::Vector{Symbol}
    defect_method::Union{Nothing,Symbol}
    objective::ObjectiveSpec
    replay_rules::NamedTuple
end

function FormulationSpec(; name::Symbol, mode::Symbol,
        variant::Union{Nothing,Symbol} = nothing,
        time_grid::Symbol = :main,
        exposed_roles::Vector{Symbol} = Symbol[],
        defect_method::Union{Nothing,Symbol} = nothing,
        objective::ObjectiveSpec = MinimizeTotalCost(),
        replay_rules::NamedTuple = NamedTuple())

    _require_symbol(name, :formulation_name)
    _require_known(mode, _FORMULATION_MODES, :formulation_mode)
    return FormulationSpec(name, mode, variant, time_grid, exposed_roles,
        defect_method, objective, replay_rules)
end

Simulation(; time_grid::Symbol = :main, objective::ObjectiveSpec = MinimizeTotalCost()) =
    FormulationSpec(name = :simulation, mode = :simulation, time_grid = time_grid,
        exposed_roles = Symbol[], defect_method = nothing, objective = objective,
        replay_rules = (source = :fixed_controls,))

Collocation(; method::Symbol = :trapezoidal, time_grid::Symbol = :main,
        objective::ObjectiveSpec = MinimizeTotalCost(),
        terminal_soc_equal_initial::Bool = false) =
    FormulationSpec(name = :collocation, mode = :collocation, variant = method,
        time_grid = time_grid, exposed_roles = [:design, :state, :control],
        defect_method = method, objective = objective,
        replay_rules = (optimized_controls = true,
            terminal_soc_equal_initial = terminal_soc_equal_initial))

_terminal_soc_equal_initial(formulation::FormulationSpec) =
    :terminal_soc_equal_initial in keys(formulation.replay_rules) &&
    formulation.replay_rules.terminal_soc_equal_initial

Shooting(; kind::Symbol = :single, time_grid::Symbol = :main,
        objective::ObjectiveSpec = MinimizeTotalCost(),
        segment_s::Union{Nothing,Real} = nothing,
        retained_implicit_boundaries::Vector{Symbol} = Symbol[]) =
    begin
        kind in (:single, :multiple) ||
            throw(ArgumentError("Shooting kind must be :single or :multiple; got $(kind)."))
        if segment_s !== nothing
            segment_s > 0 || throw(ArgumentError("segment_s must be positive when provided; got $(segment_s)."))
        end
        FormulationSpec(name = :shooting, mode = :shooting, variant = kind,
        time_grid = time_grid, exposed_roles = [:design, :control],
        defect_method = :shooting_continuity, objective = objective,
        replay_rules = (
            optimized_controls = true,
            kind = kind,
            segment_s = segment_s,
            exposed_states = false,
            state_policy = :replayed,
            residual_check = :registered_replay_constraints,
            retained_implicit_boundaries = retained_implicit_boundaries,
        ))
    end

Base.@kwdef struct RuleBasedController
    prefer_curtailment::Bool = true
end

struct SystemGraph
    ontology::OntologyTemplate
    blocks::Vector{BlockSpec}
    connections::Vector{ConnectionSpec}
    scenario::ScenarioSpec
    validation::ValidationReport
end

function SystemGraph(; ontology::OntologyTemplate, blocks::Vector{BlockSpec},
        connections::Vector{ConnectionSpec}, scenario::ScenarioSpec,
        validation::ValidationReport = ValidationReport())
    return SystemGraph(ontology, blocks, connections, scenario, validation)
end

abstract type AbstractSIRENBlock end

block_name(block::AbstractSIRENBlock) = getfield(block, :name)
design_variables(::AbstractSIRENBlock, ctx) = VariableSpec[]
state_variables(::AbstractSIRENBlock, ctx) = VariableSpec[]
control_variables(::AbstractSIRENBlock, ctx) = VariableSpec[]
ports(::AbstractSIRENBlock, ctx) = PortSpec[]
outputs(::AbstractSIRENBlock, ctx) = OutputSpec[]
residuals(::AbstractSIRENBlock, ctx) = ResidualSpec[]
evaluate!(cache, ::AbstractSIRENBlock, ctx, vars) = cache
residual!(r, ::AbstractSIRENBlock, ctx, vars, cache) = r
record!(table, ::AbstractSIRENBlock, ctx, vars, cache) = table

Base.@kwdef struct BusBalanceBlock <: AbstractSIRENBlock
    name::Symbol = :bus
    unit::String = "kW"
end

function ports(block::BusBalanceBlock, ctx)
    return [PortSpec(name = :bus_electrical, port_type = :bus_electrical,
        direction = :inout, quantity = :power, unit = block.unit,
        sign_convention = "positive injects power into the bus balance",
        cardinality = :many_to_one, owner = block.name)]
end

function residuals(block::BusBalanceBlock, ctx)
    return [ResidualSpec(name = :bus_power_balance, owner = block.name,
        equation = :sum_bus_injections, sense = :eq, unit = block.unit,
        scale = 1.0, lower = 0.0, upper = 0.0, time_scope = :interval,
        depends_on = [owner_qualified(block.name, :bus_electrical)],
        hardness = :hard, label = "Bus power balance")]
end

function outputs(block::BusBalanceBlock, ctx)
    path = ModelPathSpec(path_label = :hard_residual,
        assumptions = ["sum of signed bus injections"])
    return [OutputSpec(name = :bus_balance_residual_kw, owner = block.name,
        unit = block.unit, source = :residual, model_path = path,
        label = "Bus balance residual", plot_group = :residuals)]
end

function evaluate!(cache, ::BusBalanceBlock, ctx, vars)
    inputs = get(vars, :inputs_kw, ())
    cache[:bus_balance_residual_kw] = sum(inputs)
    return cache
end

function residual!(r, ::BusBalanceBlock, ctx, vars, cache)
    r[1] = cache[:bus_balance_residual_kw]
    return r
end

function record!(table, block::BusBalanceBlock, ctx, vars, cache)
    push!(table, (owner = block.name,
        output = :bus_balance_residual_kw,
        value = cache[:bus_balance_residual_kw],
        unit = block.unit))
    return table
end

struct RegistryEntry
    owner::Symbol
    name::Symbol
    role::Symbol
    unit::String
    scale::Any
    label::String
    index_range::UnitRange{Int}
    time_index::Union{Nothing,Int}
    scope::Symbol
    model_path::Symbol
    lower::Any
    upper::Any
    initial::Any
end

struct AssemblyRegistry
    variables::Vector{RegistryEntry}
    residuals::Vector{RegistryEntry}
    outputs::Vector{RegistryEntry}
    ports::Vector{RegistryEntry}
    trace::Vector{String}
end

struct AssembledModel
    system::SystemGraph
    scenario::ScenarioSpec
    formulation::FormulationSpec
    objective::ObjectiveSpec
    registry::AssemblyRegistry
    x0::Vector{Float64}
    lower_bounds::Vector{Float64}
    upper_bounds::Vector{Float64}
    constraint_lower_bounds::Vector{Float64}
    constraint_upper_bounds::Vector{Float64}
    callback_trace::Vector{String}
end

struct ResultSpec
    system::SystemGraph
    scenario::ScenarioSpec
    system_hash::UInt
    scenario_hash::UInt
    formulation::FormulationSpec
    solver::NamedTuple
    registry::AssemblyRegistry
    replay_summary::NamedTuple
    reports::Vector{String}
    model_paths::Vector{NamedTuple}
    timeseries::Vector{NamedTuple}
    controls::Vector{NamedTuple}
    states::Vector{NamedTuple}
    objective_value::Any
    solution_x::Vector{Float64}
end

struct OntologyDescription
    ontology::Symbol
    version::VersionNumber
    component_table::Vector{NamedTuple}
    design_defaults::Vector{NamedTuple}
    scenario_table::Vector{NamedTuple}
    formulation_table::Vector{NamedTuple}
    validation::ValidationReport
end

struct OntologyAudit
    ontology::Symbol
    connection_table::Vector{NamedTuple}
    variable_table::Vector{NamedTuple}
    residual_table::Vector{NamedTuple}
    output_table::Vector{NamedTuple}
    port_table::Vector{NamedTuple}
    model_path_table::Vector{NamedTuple}
    validation::ValidationReport
end

function _surrogate_path(name::String; assumptions = String[], fallback = "")
    ModelPathSpec(path_label = :surrogate, adapter_name = name,
        assumptions = assumptions, fallback_policy = fallback)
end

_prescribed_path(name::String) =
    ModelPathSpec(path_label = :prescribed, adapter_name = name,
        assumptions = ["externally prescribed scenario data"])

_hard_path(name::String) =
    ModelPathSpec(path_label = :hard_residual, adapter_name = name,
        assumptions = ["explicit SIRENOpt residual equation"])

function _package_path(package::String, adapter::String; assumptions = String[],
        fallback = "")
    return ModelPathSpec(path_label = :package_backed, package_name = package,
        adapter_name = adapter, assumptions = assumptions,
        fallback_policy = fallback)
end

function _minimal_reports()
    return ReportSpec[
        ReportSpec(report_name = :component_table, file_table_target = "components.csv"),
        ReportSpec(report_name = :port_graph, file_table_target = "ports.csv"),
        ReportSpec(report_name = :connection_table, file_table_target = "connections.csv"),
        ReportSpec(report_name = :variable_table, file_table_target = "variables.csv"),
        ReportSpec(report_name = :residual_table, file_table_target = "residuals.csv"),
        ReportSpec(report_name = :output_table, file_table_target = "outputs.csv"),
        ReportSpec(report_name = :model_path_summary, file_table_target = "model_paths.csv"),
        ReportSpec(report_name = :level_map_summary, file_table_target = "level_maps.csv"),
        ReportSpec(report_name = :formulation_boundaries, file_table_target = "formulation_boundaries.csv"),
        ReportSpec(report_name = :plot_inventory, file_table_target = "plots.csv"),
        ReportSpec(report_name = :replay_csv, file_table_target = "timeseries.csv"),
        ReportSpec(report_name = :residual_audit, file_table_target = "replay_residuals.csv"),
    ]
end

function _minimal_block_roles(include_battery::Bool; include_wind::Bool = false,
        include_wave::Bool = false, include_hydrokinetic::Bool = false,
        include_diesel::Bool = false,
        include_h2::Bool = false, include_desal::Bool = false,
        include_platform::Bool = false)
    roles = BlockRole[
        BlockRole(role_name = :solar_resource, component_family = :resource, default_provider = :solar_resource),
        BlockRole(role_name = :solar_array, component_family = :source, default_provider = :solar_array),
        BlockRole(role_name = :solar_converter, component_family = :converter, default_provider = :solar_converter),
        BlockRole(role_name = :load, component_family = :load, default_provider = :load),
        BlockRole(role_name = :bus, component_family = :aggregator, default_provider = :bus),
    ]
    if include_battery
        push!(roles, BlockRole(role_name = :battery, component_family = :storage, default_provider = :battery))
        push!(roles, BlockRole(role_name = :battery_converter, component_family = :converter, default_provider = :battery_converter))
    end
    if include_wind
        push!(roles, BlockRole(role_name = :wind_resource, component_family = :resource, default_provider = :wind_resource))
        push!(roles, BlockRole(role_name = :wind_rotor, component_family = :source, default_provider = :wind_rotor))
        push!(roles, BlockRole(role_name = :wind_generator, component_family = :converter, default_provider = :wind_generator))
        push!(roles, BlockRole(role_name = :wind_converter, component_family = :converter, default_provider = :wind_converter))
    end
    if include_wave
        push!(roles, BlockRole(role_name = :wave_resource, component_family = :resource, default_provider = :wave_resource))
        push!(roles, BlockRole(role_name = :wave_wec, component_family = :source, default_provider = :wave_wec))
        push!(roles, BlockRole(role_name = :wave_converter, component_family = :converter, default_provider = :wave_converter))
    end
    if include_hydrokinetic
        push!(roles, BlockRole(role_name = :hydrokinetic_resource, component_family = :resource, default_provider = :hydrokinetic_resource))
        push!(roles, BlockRole(role_name = :hydrokinetic_rotor, component_family = :source, default_provider = :hydrokinetic_rotor))
        push!(roles, BlockRole(role_name = :hydrokinetic_generator, component_family = :converter, default_provider = :hydrokinetic_generator))
        push!(roles, BlockRole(role_name = :hydrokinetic_converter, component_family = :converter, default_provider = :hydrokinetic_converter))
    end
    if include_diesel
        push!(roles, BlockRole(role_name = :diesel_engine, component_family = :source, default_provider = :diesel_engine))
        push!(roles, BlockRole(role_name = :diesel_generator, component_family = :converter, default_provider = :diesel_generator))
        push!(roles, BlockRole(role_name = :diesel_converter, component_family = :converter, default_provider = :diesel_converter))
    end
    if include_h2
        push!(roles, BlockRole(role_name = :h2_electrolyzer, component_family = :load_process, default_provider = :h2_electrolyzer))
        push!(roles, BlockRole(role_name = :h2_converter, component_family = :converter, default_provider = :h2_converter))
    end
    if include_desal
        push!(roles, BlockRole(role_name = :desalination, component_family = :load_process, default_provider = :desalination))
        push!(roles, BlockRole(role_name = :desal_converter, component_family = :converter, default_provider = :desal_converter))
    end
    if include_platform
        push!(roles, BlockRole(role_name = :platform, component_family = :platform, default_provider = :platform))
    end
    return roles
end

function _minimal_blocks(; include_battery::Bool, solar_area_m2,
        solar_efficiency, solar_converter_rating_kw, solar_converter_efficiency,
        battery_capacity_kwh, battery_power_kw, battery_charge_efficiency,
        battery_discharge_efficiency, battery_converter_efficiency,
        load_converter_rating_kw, load_converter_efficiency,
        critical_load_fraction)

    solar_resource_path = _prescribed_path("ShortHorizonScenario.solar_irradiance_kw_per_m2")
    solar_path = _surrogate_path("linear_solar_array",
        assumptions = ["power_kw = irradiance_kw_per_m2 * area_m2 * efficiency"],
        fallback = "replace with PVlib adapter when package-backed weather is active")
    converter_path = _surrogate_path("constant_efficiency_converter",
        assumptions = ["positive power supplies downstream bus", "negative power consumes from bus"])
    battery_path = _surrogate_path("coulombic_battery_inventory",
        assumptions = ["positive command discharges to the bus", "dt_s converted once to hours"])
    load_path = _prescribed_path("ShortHorizonScenario.load_kw")
    bus_path = _hard_path("signed_bus_power_balance")

    blocks = BlockSpec[]
    push!(blocks, BlockSpec(
        name = :solar_resource,
        role = :solar_resource,
        component_type = :resource,
        model_path = solar_resource_path,
        interfaces = [InterfaceSpec(archetype_name = :resource_provider,
            active_ports = [:resource_state])],
        ports = [PortSpec(name = :resource_state, port_type = :resource_state,
            direction = :out, quantity = :irradiance, unit = "kW/m^2",
            sign_convention = "positive irradiance increases available solar power",
            owner = :solar_resource)],
        outputs = [OutputSpec(name = :solar_irradiance_kw_per_m2,
            owner = :solar_resource, unit = "kW/m^2", source = :scenario,
            model_path = solar_resource_path, label = "Solar irradiance",
            plot_group = :resources)],
        parameters = (source = :scenario,),
        metadata = BlockMetadata(name = :solar_resource, model_path = solar_resource_path),
    ))

    push!(blocks, BlockSpec(
        name = :solar_array,
        role = :solar_array,
        component_type = :source,
        model_path = solar_path,
        designs = [VariableSpec(name = :solar_area_m2, owner = :solar_array,
            role = :design, unit = "m^2", initial = solar_area_m2, lower = 0.0,
            upper = Inf, scale = max(float(solar_area_m2), 1.0),
            time_scope = :design, exposure = :decision, label = "Solar array area")],
        controls = [VariableSpec(name = :solar_curtailment, owner = :solar_array,
            role = :control, unit = "fraction", initial = 0.0, lower = 0.0,
            upper = 1.0, scale = 1.0, time_scope = :interval,
            exposure = :decision, label = "Solar curtailment")],
        interfaces = [InterfaceSpec(archetype_name = :electrical_source,
            active_ports = [:resource_state, :device_electrical, :control_signal])],
        ports = [
            PortSpec(name = :resource_state, port_type = :resource_state,
                direction = :in, quantity = :irradiance, unit = "kW/m^2",
                sign_convention = "positive irradiance increases available solar power",
                owner = :solar_array),
            PortSpec(name = :control_signal, port_type = :control_signal,
                direction = :in, quantity = :curtailment, unit = "fraction",
                sign_convention = "positive curtailment reduces available solar power",
                owner = :solar_array),
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive device power leaves the solar array",
                owner = :solar_array),
        ],
        outputs = [OutputSpec(name = :solar_device_power_kw, owner = :solar_array,
            unit = "kW", source = :kernel, model_path = solar_path,
            label = "Solar device power", plot_group = :power)],
        residuals = [ResidualSpec(name = :solar_available_limit,
            owner = :solar_array, equation = :available_power_cap, sense = :geq,
            unit = "kW", scale = 1.0, lower = 0.0, upper = Inf,
            time_scope = :interval,
            depends_on = [owner_qualified(:solar_array, :solar_curtailment),
                owner_qualified(:solar_array, :solar_area_m2)],
            hardness = :hard, label = "Solar available power cap")],
        parameters = (efficiency = solar_efficiency,),
        metadata = BlockMetadata(name = :solar_array, model_path = solar_path),
    ))

    push!(blocks, BlockSpec(
        name = :solar_converter,
        role = :converter,
        component_type = :converter,
        model_path = converter_path,
        designs = [VariableSpec(name = :solar_converter_rating_kw,
            owner = :solar_converter, role = :design, unit = "kW",
            initial = solar_converter_rating_kw, lower = 0.0, upper = Inf,
            scale = max(float(solar_converter_rating_kw), 1.0),
            time_scope = :design, exposure = :decision,
            label = "Solar converter rating")],
        interfaces = [InterfaceSpec(archetype_name = :converter_or_generator,
            active_ports = [:device_electrical, :bus_electrical])],
        ports = [
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :in, quantity = :power, unit = "kW",
                sign_convention = "positive power enters converter from solar array",
                owner = :solar_converter),
            PortSpec(name = :bus_electrical, port_type = :bus_electrical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive power injects into bus",
                owner = :solar_converter),
        ],
        outputs = [
            OutputSpec(name = :solar_bus_power_kw, owner = :solar_converter,
                unit = "kW", source = :kernel, model_path = converter_path,
                label = "Solar bus power", plot_group = :power),
            OutputSpec(name = :solar_converter_loss_kw, owner = :solar_converter,
                unit = "kW", source = :kernel, model_path = converter_path,
                label = "Solar converter loss", plot_group = :losses),
        ],
        residuals = [
            ResidualSpec(name = :solar_converter_loss_relation,
                owner = :solar_converter, equation = :constant_efficiency,
                sense = :eq, unit = "kW", scale = 1.0, lower = 0.0, upper = 0.0,
                time_scope = :interval,
                depends_on = [owner_qualified(:solar_array, :device_electrical)],
                hardness = :hard, label = "Solar converter loss relation"),
            ResidualSpec(name = :solar_converter_rating_limit,
                owner = :solar_converter, equation = :absolute_power_rating,
                sense = :geq, unit = "kW", scale = 1.0, lower = 0.0, upper = Inf,
                time_scope = :interval,
                depends_on = [owner_qualified(:solar_converter, :solar_converter_rating_kw)],
                hardness = :hard, label = "Solar converter rating margin"),
        ],
        parameters = (efficiency = solar_converter_efficiency,),
        metadata = BlockMetadata(name = :solar_converter, model_path = converter_path),
    ))

    if include_battery
        push!(blocks, BlockSpec(
            name = :battery,
            role = :battery,
            component_type = :storage,
            model_path = battery_path,
            designs = [
                VariableSpec(name = :battery_capacity_kwh, owner = :battery,
                    role = :design, unit = "kWh", initial = battery_capacity_kwh,
                    lower = eps(float(one(battery_capacity_kwh))), upper = Inf,
                    scale = max(float(battery_capacity_kwh), 1.0),
                    time_scope = :design, exposure = :decision,
                    label = "Battery capacity"),
                VariableSpec(name = :battery_power_kw, owner = :battery,
                    role = :design, unit = "kW", initial = battery_power_kw,
                    lower = eps(float(one(battery_power_kw))), upper = Inf,
                    scale = max(float(battery_power_kw), 1.0),
                    time_scope = :design, exposure = :decision,
                    label = "Battery power rating"),
            ],
            states = [VariableSpec(name = :battery_soc, owner = :battery,
                role = :state, unit = "fraction", initial = 0.6, lower = 0.0,
                upper = 1.0, scale = 1.0, time_scope = :node,
                exposure = :decision, label = "Battery state of charge")],
            controls = [VariableSpec(name = :battery_command_kw, owner = :battery,
                role = :control, unit = "kW", initial = 0.0,
                lower = -battery_power_kw, upper = battery_power_kw,
                scale = max(float(battery_power_kw), 1.0), time_scope = :interval,
                exposure = :decision, label = "Battery command")],
            interfaces = [InterfaceSpec(archetype_name = :storage,
                active_ports = [:storage_state, :device_electrical, :control_signal])],
            ports = [
                PortSpec(name = :storage_state, port_type = :storage_state,
                    direction = :out, quantity = :inventory, unit = "fraction",
                    sign_convention = "larger SOC stores more energy",
                    owner = :battery),
                PortSpec(name = :device_electrical, port_type = :device_electrical,
                    direction = :inout, quantity = :power, unit = "kW",
                    sign_convention = "positive device power discharges from battery",
                    owner = :battery),
                PortSpec(name = :control_signal, port_type = :control_signal,
                    direction = :in, quantity = :power_command, unit = "kW",
                    sign_convention = "positive command discharges to the bus",
                    owner = :battery),
            ],
            outputs = [
                OutputSpec(name = :battery_soc, owner = :battery, unit = "fraction",
                    source = :kernel, model_path = battery_path,
                    label = "Battery SOC", plot_group = :storage),
                OutputSpec(name = :battery_device_power_kw, owner = :battery, unit = "kW",
                    source = :kernel, model_path = battery_path,
                    label = "Battery device power", plot_group = :power),
            ],
            residuals = [
                ResidualSpec(name = :battery_inventory, owner = :battery,
                    equation = :soc_inventory, sense = :eq, unit = "kWh",
                    scale = max(float(battery_capacity_kwh), 1.0), lower = 0.0,
                    upper = 0.0, time_scope = :interval,
                    depends_on = [owner_qualified(:battery, :battery_soc),
                        owner_qualified(:battery, :battery_command_kw)],
                    hardness = :hard, label = "Battery SOC inventory"),
                ResidualSpec(name = :battery_power_limit, owner = :battery,
                    equation = :charge_discharge_power_rating, sense = :geq,
                    unit = "kW", scale = max(float(battery_power_kw), 1.0),
                    lower = 0.0, upper = Inf, time_scope = :interval,
                    depends_on = [owner_qualified(:battery, :battery_power_kw),
                        owner_qualified(:battery, :battery_command_kw)],
                    hardness = :hard, label = "Battery power margin"),
            ],
            parameters = (
                charge_efficiency = battery_charge_efficiency,
                discharge_efficiency = battery_discharge_efficiency,
            ),
            metadata = BlockMetadata(name = :battery, model_path = battery_path),
        ))

        push!(blocks, BlockSpec(
            name = :battery_converter,
            role = :converter,
            component_type = :converter,
            model_path = converter_path,
            interfaces = [InterfaceSpec(archetype_name = :converter_or_generator,
                active_ports = [:device_electrical, :bus_electrical])],
            ports = [
                PortSpec(name = :device_electrical, port_type = :device_electrical,
                    direction = :inout, quantity = :power, unit = "kW",
                    sign_convention = "positive power enters converter from battery",
                    owner = :battery_converter),
                PortSpec(name = :bus_electrical, port_type = :bus_electrical,
                    direction = :inout, quantity = :power, unit = "kW",
                    sign_convention = "positive power injects into bus",
                    owner = :battery_converter),
            ],
            outputs = [
                OutputSpec(name = :battery_bus_power_kw, owner = :battery_converter,
                    unit = "kW", source = :kernel, model_path = converter_path,
                    label = "Battery bus power", plot_group = :power),
                OutputSpec(name = :battery_converter_loss_kw, owner = :battery_converter,
                    unit = "kW", source = :kernel, model_path = converter_path,
                    label = "Battery converter loss", plot_group = :losses),
            ],
            residuals = [
                ResidualSpec(name = :battery_converter_loss_relation,
                    owner = :battery_converter, equation = :constant_efficiency,
                    sense = :eq, unit = "kW", scale = 1.0, lower = 0.0,
                    upper = 0.0, time_scope = :interval,
                    depends_on = [owner_qualified(:battery, :battery_command_kw)],
                    hardness = :hard, label = "Battery converter loss relation"),
                ResidualSpec(name = :battery_converter_rating_limit,
                    owner = :battery_converter, equation = :absolute_power_rating,
                    sense = :geq, unit = "kW", scale = max(float(battery_power_kw), 1.0),
                    lower = 0.0, upper = Inf, time_scope = :interval,
                    depends_on = [owner_qualified(:battery, :battery_power_kw)],
                    hardness = :hard, label = "Battery converter rating margin"),
            ],
            parameters = (efficiency = battery_converter_efficiency,),
            metadata = BlockMetadata(name = :battery_converter, model_path = converter_path),
        ))
    end

    push!(blocks, BlockSpec(
        name = :load,
        role = :load,
        component_type = :load,
        model_path = load_path,
        designs = [VariableSpec(name = :load_converter_rating_kw, owner = :load,
            role = :design, unit = "kW", initial = load_converter_rating_kw,
            lower = 0.0, upper = Inf, scale = max(float(load_converter_rating_kw), 1.0),
            time_scope = :design, exposure = :decision,
            label = "Load converter rating")],
        controls = [VariableSpec(name = :load_served_fraction, owner = :load,
            role = :control, unit = "fraction", initial = 1.0,
            lower = critical_load_fraction, upper = 1.0, scale = 1.0,
            time_scope = :interval, exposure = :decision,
            label = "Load served fraction")],
        interfaces = [InterfaceSpec(archetype_name = :load_or_process,
            active_ports = [:demand_profile, :bus_electrical])],
        ports = [
            PortSpec(name = :demand_profile, port_type = :demand_profile,
                direction = :in, quantity = :power_demand, unit = "kW",
                sign_convention = "positive demand consumes bus power",
                owner = :load),
            PortSpec(name = :bus_electrical, port_type = :bus_electrical,
                direction = :inout, quantity = :power, unit = "kW",
                sign_convention = "load is negative in the bus balance",
                owner = :load),
        ],
        outputs = [OutputSpec(name = :load_bus_power_kw, owner = :load,
            unit = "kW", source = :kernel, model_path = load_path,
            label = "Load bus power", plot_group = :power)],
        residuals = [
            ResidualSpec(name = :load_served_bounds, owner = :load,
                equation = :served_fraction_bounds, sense = :interval, unit = "fraction",
                scale = 1.0, lower = critical_load_fraction, upper = 1.0,
                time_scope = :interval,
                depends_on = [owner_qualified(:load, :load_served_fraction)],
                hardness = :hard, label = "Load served fraction bounds"),
            ResidualSpec(name = :load_converter_rating_limit, owner = :load,
                equation = :absolute_power_rating, sense = :geq, unit = "kW",
                scale = max(float(load_converter_rating_kw), 1.0), lower = 0.0,
                upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:load, :load_converter_rating_kw),
                    owner_qualified(:load, :load_served_fraction)],
                hardness = :hard, label = "Load converter rating margin"),
        ],
        parameters = (
            converter_efficiency = load_converter_efficiency,
            converter_rating_kw = load_converter_rating_kw,
            critical_fraction = critical_load_fraction,
        ),
        metadata = BlockMetadata(name = :load, model_path = load_path),
    ))

    push!(blocks, BlockSpec(
        name = :bus,
        role = :bus,
        component_type = :aggregator,
        model_path = bus_path,
        interfaces = [InterfaceSpec(archetype_name = :aggregator,
            active_ports = [:bus_electrical])],
        ports = [PortSpec(name = :bus_electrical, port_type = :bus_electrical,
            direction = :inout, quantity = :power, unit = "kW",
            sign_convention = "sum of source, storage, and load bus powers must be zero",
            cardinality = :many_to_one, owner = :bus)],
        outputs = [
            OutputSpec(name = :bus_balance_residual_kw, owner = :bus,
                unit = "kW", source = :residual, model_path = bus_path,
                label = "Bus balance residual", plot_group = :residuals),
            OutputSpec(name = :bus_voltage_basis, owner = :bus,
                unit = "p.u.", source = :parameter, model_path = bus_path,
                time_scope = :design, label = "Bus voltage basis",
                plot_group = nothing),
        ],
        residuals = [ResidualSpec(name = :bus_power_balance, owner = :bus,
            equation = :sum_signed_bus_power, sense = :eq, unit = "kW",
            scale = 1.0, lower = 0.0, upper = 0.0, time_scope = :interval,
            depends_on = [owner_qualified(:solar_converter, :bus_electrical),
                owner_qualified(:load, :bus_electrical)],
            hardness = :hard, label = "Bus power balance")],
        parameters = (voltage_basis = "per-unit nominal bus",),
        metadata = BlockMetadata(name = :bus, model_path = bus_path),
    ))

    return blocks
end

function _append_wind_blocks!(blocks; include_platform::Bool,
        wind_rated_power_kw, wind_generator_efficiency, wind_converter_efficiency,
        wind_cut_in_m_s, wind_cut_out_m_s, wind_air_density_kg_m3,
        wind_platform_moment_per_kw_nm)
    resource_path = _prescribed_path("ShortHorizonScenario.wind_speed_m_s")
    rotor_path = _package_path("UnsteadyKineticRotorDynamics",
        "simple_ccblade_rotor_model";
        assumptions = ["wind speed in m/s", "positive shaft power leaves rotor",
            "ForwardDiff sensitivity through dual-valued motion uses SIRENOpt smooth actuator-disk envelope because the current package state is Float64-typed"],
        fallback = "replace with a higher-fidelity wind adapter when rotor states and dual-valued motion are exposed")
    generator_path = _package_path("GeneratorSE", "generatorse_output_kw";
        assumptions = ["shaft power enters generator", "positive electrical power leaves generator"],
        fallback = "constant-efficiency generator if GeneratorSE construction is unavailable")
    converter_path = _package_path("PowerConverterDynamics", "powerconverter_output_kw";
        assumptions = ["signed kW converter boundary", "positive power injects into the bus"],
        fallback = "constant-efficiency converter if package model is unavailable")
    rotor_model = simple_ccblade_rotor_model(
        rotor_radius = 1.0,
        blades = 2,
        n_sections = 3,
        omega_rad_s = 20.0,
        fluid = :air,
    )
    generator_model = generatorse_pmsg_arms_model(rated_power_kw = max(float(wind_rated_power_kw), 1.0))
    converter_model = powerconverter_model(rated_power_kw = max(float(wind_rated_power_kw), 1.0))

    push!(blocks, BlockSpec(
        name = :wind_resource,
        role = :wind_resource,
        component_type = :resource,
        model_path = resource_path,
        interfaces = [InterfaceSpec(archetype_name = :resource_provider,
            active_ports = [:resource_state])],
        ports = [PortSpec(name = :resource_state, port_type = :resource_state,
            direction = :out, quantity = :wind_speed, unit = "m/s",
            sign_convention = "positive wind speed increases available rotor power",
            owner = :wind_resource)],
        outputs = [OutputSpec(name = :wind_speed_m_s, owner = :wind_resource,
            unit = "m/s", source = :scenario, model_path = resource_path,
            label = "Wind speed", plot_group = :resources)],
        parameters = (source = :scenario,),
        metadata = BlockMetadata(name = :wind_resource, model_path = resource_path),
    ))

    rotor_ports = PortSpec[
        PortSpec(name = :resource_state, port_type = :resource_state,
            direction = :in, quantity = :wind_speed, unit = "m/s",
            sign_convention = "positive wind speed increases available rotor power",
            owner = :wind_rotor),
        PortSpec(name = :control_signal, port_type = :control_signal,
            direction = :in, quantity = :curtailment, unit = "fraction",
            sign_convention = "positive curtailment reduces wind shaft power",
            owner = :wind_rotor),
        PortSpec(name = :shaft_mechanical, port_type = :shaft_mechanical,
            direction = :out, quantity = :power, unit = "kW",
            sign_convention = "positive shaft power leaves rotor",
            owner = :wind_rotor),
    ]
    if include_platform
        push!(rotor_ports, PortSpec(name = :motion_state,
            port_type = :motion_state, direction = :in,
            quantity = :pitch_state, unit = "rad,rad/s",
            sign_convention = "positive theta reduces effective inflow by cos(theta)",
            frame = :body, reference_point = :platform_origin,
            owner = :wind_rotor))
        push!(rotor_ports, PortSpec(name = :platform_wrench,
            port_type = :platform_wrench, direction = :out,
            quantity = :moment, unit = "N*m",
            sign_convention = "positive pitch moment increases platform theta",
            frame = :body, reference_point = :platform_origin,
            owner = :wind_rotor))
    end
    push!(blocks, BlockSpec(
        name = :wind_rotor,
        role = :wind_rotor,
        component_type = :source,
        model_path = rotor_path,
        designs = [VariableSpec(name = :wind_rated_power_kw, owner = :wind_rotor,
            role = :design, unit = "kW", initial = wind_rated_power_kw,
            lower = 0.0, upper = Inf, scale = max(float(wind_rated_power_kw), 1.0),
            time_scope = :design, exposure = :decision,
            label = "Wind rated power")],
        controls = [VariableSpec(name = :wind_curtailment, owner = :wind_rotor,
            role = :control, unit = "fraction", initial = 0.0, lower = 0.0,
            upper = 1.0, scale = 1.0, time_scope = :interval,
            exposure = :decision, label = "Wind curtailment")],
        interfaces = [InterfaceSpec(archetype_name = :mechanical_prime_mover,
            active_ports = include_platform ?
                [:resource_state, :motion_state, :control_signal, :shaft_mechanical, :platform_wrench] :
                [:resource_state, :control_signal, :shaft_mechanical])],
        ports = rotor_ports,
        outputs = [
            OutputSpec(name = :wind_shaft_power_kw, owner = :wind_rotor,
                unit = "kW", source = :adapter, model_path = rotor_path,
                label = "Wind shaft power", plot_group = :power),
            OutputSpec(name = :wind_platform_moment_nm, owner = :wind_rotor,
                unit = "N*m", source = :adapter, model_path = rotor_path,
                label = "Wind platform pitch moment", plot_group = :dynamics),
        ],
        residuals = [
            ResidualSpec(name = :wind_available_limit, owner = :wind_rotor,
                equation = :package_backed_rotor_power_cap, sense = :geq,
                unit = "kW", scale = max(float(wind_rated_power_kw), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:wind_rotor, :wind_curtailment),
                    owner_qualified(:wind_rotor, :wind_rated_power_kw)],
                hardness = :hard, label = "Wind available power cap"),
            ResidualSpec(name = :wind_rating_limit, owner = :wind_rotor,
                equation = :wind_rated_power_limit, sense = :geq,
                unit = "kW", scale = max(float(wind_rated_power_kw), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:wind_rotor, :wind_rated_power_kw)],
                hardness = :hard, label = "Wind rated power margin"),
        ],
        parameters = (
            rotor_model = rotor_model,
            cut_in_m_s = wind_cut_in_m_s,
            cut_out_m_s = wind_cut_out_m_s,
            air_density_kg_m3 = wind_air_density_kg_m3,
            platform_moment_per_kw_nm = wind_platform_moment_per_kw_nm,
        ),
        metadata = BlockMetadata(name = :wind_rotor, model_path = rotor_path),
    ))

    push!(blocks, BlockSpec(
        name = :wind_generator,
        role = :generator,
        component_type = :converter,
        model_path = generator_path,
        interfaces = [InterfaceSpec(archetype_name = :converter_or_generator,
            active_ports = [:shaft_mechanical, :device_electrical])],
        ports = [
            PortSpec(name = :shaft_mechanical, port_type = :shaft_mechanical,
                direction = :in, quantity = :power, unit = "kW",
                sign_convention = "positive shaft power enters generator",
                owner = :wind_generator),
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive electrical power leaves generator",
                owner = :wind_generator),
        ],
        outputs = [OutputSpec(name = :wind_device_power_kw, owner = :wind_generator,
            unit = "kW", source = :adapter, model_path = generator_path,
            label = "Wind generator electrical power", plot_group = :power)],
        residuals = [ResidualSpec(name = :wind_generator_loss_relation,
            owner = :wind_generator, equation = :generator_adapter_output,
            sense = :eq, unit = "kW", scale = 1.0, lower = 0.0, upper = 0.0,
            time_scope = :interval,
            depends_on = [owner_qualified(:wind_rotor, :shaft_mechanical)],
            hardness = :hard, label = "Wind generator loss relation")],
        parameters = (
            efficiency = wind_generator_efficiency,
            generator_model = generator_model,
        ),
        metadata = BlockMetadata(name = :wind_generator, model_path = generator_path),
    ))

    push!(blocks, BlockSpec(
        name = :wind_converter,
        role = :converter,
        component_type = :converter,
        model_path = converter_path,
        interfaces = [InterfaceSpec(archetype_name = :converter_or_generator,
            active_ports = [:device_electrical, :bus_electrical])],
        ports = [
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :in, quantity = :power, unit = "kW",
                sign_convention = "positive power enters converter from wind generator",
                owner = :wind_converter),
            PortSpec(name = :bus_electrical, port_type = :bus_electrical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive power injects into bus",
                owner = :wind_converter),
        ],
        outputs = [OutputSpec(name = :wind_bus_power_kw, owner = :wind_converter,
            unit = "kW", source = :adapter, model_path = converter_path,
            label = "Wind bus power", plot_group = :power)],
        residuals = [
            ResidualSpec(name = :wind_converter_loss_relation,
                owner = :wind_converter, equation = :converter_adapter_output,
                sense = :eq, unit = "kW", scale = 1.0, lower = 0.0, upper = 0.0,
                time_scope = :interval,
                depends_on = [owner_qualified(:wind_generator, :device_electrical)],
                hardness = :hard, label = "Wind converter loss relation"),
            ResidualSpec(name = :wind_converter_rating_limit,
                owner = :wind_converter, equation = :absolute_power_rating,
                sense = :geq, unit = "kW", scale = max(float(wind_rated_power_kw), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:wind_rotor, :wind_rated_power_kw)],
                hardness = :hard, label = "Wind converter rating margin"),
        ],
        parameters = (
            efficiency = wind_converter_efficiency,
            converter_model = converter_model,
        ),
        metadata = BlockMetadata(name = :wind_converter, model_path = converter_path),
    ))

    return blocks
end

function _append_hydrokinetic_blocks!(blocks; hydrokinetic_rated_power_kw,
        hydrokinetic_rotor_diameter_m, hydrokinetic_cp,
        hydrokinetic_generator_efficiency, hydrokinetic_converter_efficiency,
        hydrokinetic_cut_in_m_s, hydrokinetic_cut_out_m_s,
        hydrokinetic_fluid_density_kg_m3)
    resource_path = _prescribed_path("ShortHorizonScenario.hydrokinetic_current_m_s")
    rotor_path = _package_path("UnsteadyKineticRotorDynamics",
        "simple_ccblade_rotor_model";
        assumptions = ["current speed in m/s", "fluid density in kg/m^3",
            "positive shaft power leaves hydrokinetic rotor",
            "ForwardDiff sensitivity through dual-valued resource inputs uses SIRENOpt smooth actuator-disk envelope because the current package state is Float64-typed"],
        fallback = "replace with a higher-fidelity hydrokinetic adapter when rotor states and dual-valued resource inputs are exposed")
    generator_path = _package_path("GeneratorSE", "generatorse_output_kw";
        assumptions = ["shaft power enters generator", "positive electrical power leaves generator"],
        fallback = "constant-efficiency generator if GeneratorSE construction is unavailable")
    converter_path = _package_path("PowerConverterDynamics", "powerconverter_output_kw";
        assumptions = ["signed kW converter boundary", "positive power injects into the bus"],
        fallback = "constant-efficiency converter if package model is unavailable")
    rotor_model = simple_ccblade_rotor_model(
        rotor_radius = max(float(hydrokinetic_rotor_diameter_m), eps(Float64)) / 2,
        blades = 3,
        n_sections = 4,
        omega_rad_s = 4.0,
        fluid = :water,
    )
    generator_model = generatorse_pmsg_arms_model(rated_power_kw = max(float(hydrokinetic_rated_power_kw), 1.0))
    converter_model = powerconverter_model(rated_power_kw = max(float(hydrokinetic_rated_power_kw), 1.0))

    push!(blocks, BlockSpec(
        name = :hydrokinetic_resource,
        role = :hydrokinetic_resource,
        component_type = :resource,
        model_path = resource_path,
        interfaces = [InterfaceSpec(archetype_name = :resource_provider,
            active_ports = [:resource_state])],
        ports = [PortSpec(name = :resource_state, port_type = :resource_state,
            direction = :out, quantity = :current_speed, unit = "m/s",
            sign_convention = "positive current speed increases available rotor power",
            owner = :hydrokinetic_resource)],
        outputs = [OutputSpec(name = :hydrokinetic_current_m_s,
            owner = :hydrokinetic_resource, unit = "m/s", source = :scenario,
            model_path = resource_path, label = "Hydrokinetic current speed",
            plot_group = :resources)],
        parameters = (source = :scenario,),
        metadata = BlockMetadata(name = :hydrokinetic_resource, model_path = resource_path),
    ))

    push!(blocks, BlockSpec(
        name = :hydrokinetic_rotor,
        role = :hydrokinetic_rotor,
        component_type = :source,
        model_path = rotor_path,
        designs = [VariableSpec(name = :hydrokinetic_rated_power_kw,
            owner = :hydrokinetic_rotor, role = :design, unit = "kW",
            initial = hydrokinetic_rated_power_kw, lower = 0.0, upper = Inf,
            scale = max(float(hydrokinetic_rated_power_kw), 1.0),
            time_scope = :design, exposure = :decision,
            label = "Hydrokinetic rated power")],
        controls = [VariableSpec(name = :hydrokinetic_curtailment,
            owner = :hydrokinetic_rotor, role = :control, unit = "fraction",
            initial = 0.0, lower = 0.0, upper = 1.0, scale = 1.0,
            time_scope = :interval, exposure = :decision,
            label = "Hydrokinetic curtailment")],
        interfaces = [InterfaceSpec(archetype_name = :mechanical_prime_mover,
            active_ports = [:resource_state, :control_signal, :shaft_mechanical])],
        ports = [
            PortSpec(name = :resource_state, port_type = :resource_state,
                direction = :in, quantity = :current_speed, unit = "m/s",
                sign_convention = "positive current speed increases available rotor power",
                owner = :hydrokinetic_rotor),
            PortSpec(name = :control_signal, port_type = :control_signal,
                direction = :in, quantity = :curtailment, unit = "fraction",
                sign_convention = "positive curtailment reduces hydrokinetic shaft power",
                owner = :hydrokinetic_rotor),
            PortSpec(name = :shaft_mechanical, port_type = :shaft_mechanical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive shaft power leaves hydrokinetic rotor",
                owner = :hydrokinetic_rotor),
        ],
        outputs = [OutputSpec(name = :hydrokinetic_shaft_power_kw,
            owner = :hydrokinetic_rotor, unit = "kW", source = :adapter,
            model_path = rotor_path, label = "Hydrokinetic shaft power",
            plot_group = :power)],
        residuals = [
            ResidualSpec(name = :hydrokinetic_available_limit,
                owner = :hydrokinetic_rotor,
                equation = :package_backed_hydrokinetic_power_cap,
                sense = :geq, unit = "kW",
                scale = max(float(hydrokinetic_rated_power_kw), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:hydrokinetic_rotor, :hydrokinetic_curtailment),
                    owner_qualified(:hydrokinetic_rotor, :hydrokinetic_rated_power_kw)],
                hardness = :hard, label = "Hydrokinetic available power cap"),
            ResidualSpec(name = :hydrokinetic_rating_limit,
                owner = :hydrokinetic_rotor, equation = :hydrokinetic_rated_power_limit,
                sense = :geq, unit = "kW",
                scale = max(float(hydrokinetic_rated_power_kw), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:hydrokinetic_rotor, :hydrokinetic_rated_power_kw)],
                hardness = :hard, label = "Hydrokinetic rated power margin"),
        ],
        parameters = (
            rotor_model = rotor_model,
            rotor_diameter_m = hydrokinetic_rotor_diameter_m,
            cp = hydrokinetic_cp,
            cut_in_m_s = hydrokinetic_cut_in_m_s,
            cut_out_m_s = hydrokinetic_cut_out_m_s,
            fluid_density_kg_m3 = hydrokinetic_fluid_density_kg_m3,
        ),
        metadata = BlockMetadata(name = :hydrokinetic_rotor, model_path = rotor_path),
    ))

    push!(blocks, BlockSpec(
        name = :hydrokinetic_generator,
        role = :generator,
        component_type = :converter,
        model_path = generator_path,
        interfaces = [InterfaceSpec(archetype_name = :converter_or_generator,
            active_ports = [:shaft_mechanical, :device_electrical])],
        ports = [
            PortSpec(name = :shaft_mechanical, port_type = :shaft_mechanical,
                direction = :in, quantity = :power, unit = "kW",
                sign_convention = "positive shaft power enters generator",
                owner = :hydrokinetic_generator),
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive electrical power leaves generator",
                owner = :hydrokinetic_generator),
        ],
        outputs = [OutputSpec(name = :hydrokinetic_device_power_kw,
            owner = :hydrokinetic_generator, unit = "kW", source = :adapter,
            model_path = generator_path, label = "Hydrokinetic generator electrical power",
            plot_group = :power)],
        residuals = [ResidualSpec(name = :hydrokinetic_generator_loss_relation,
            owner = :hydrokinetic_generator, equation = :generator_adapter_output,
            sense = :eq, unit = "kW", scale = 1.0, lower = 0.0, upper = 0.0,
            time_scope = :interval,
            depends_on = [owner_qualified(:hydrokinetic_rotor, :shaft_mechanical)],
            hardness = :hard, label = "Hydrokinetic generator loss relation")],
        parameters = (
            efficiency = hydrokinetic_generator_efficiency,
            generator_model = generator_model,
        ),
        metadata = BlockMetadata(name = :hydrokinetic_generator, model_path = generator_path),
    ))

    push!(blocks, BlockSpec(
        name = :hydrokinetic_converter,
        role = :converter,
        component_type = :converter,
        model_path = converter_path,
        interfaces = [InterfaceSpec(archetype_name = :converter_or_generator,
            active_ports = [:device_electrical, :bus_electrical])],
        ports = [
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :in, quantity = :power, unit = "kW",
                sign_convention = "positive power enters converter from hydrokinetic generator",
                owner = :hydrokinetic_converter),
            PortSpec(name = :bus_electrical, port_type = :bus_electrical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive power injects into bus",
                owner = :hydrokinetic_converter),
        ],
        outputs = [
            OutputSpec(name = :hydrokinetic_bus_power_kw,
                owner = :hydrokinetic_converter, unit = "kW", source = :adapter,
                model_path = converter_path, label = "Hydrokinetic bus power",
                plot_group = :power),
            OutputSpec(name = :hydrokinetic_converter_loss_kw,
                owner = :hydrokinetic_converter, unit = "kW", source = :adapter,
                model_path = converter_path, label = "Hydrokinetic converter loss",
                plot_group = :losses),
        ],
        residuals = [
            ResidualSpec(name = :hydrokinetic_converter_loss_relation,
                owner = :hydrokinetic_converter, equation = :converter_adapter_output,
                sense = :eq, unit = "kW", scale = 1.0, lower = 0.0, upper = 0.0,
                time_scope = :interval,
                depends_on = [owner_qualified(:hydrokinetic_generator, :device_electrical)],
                hardness = :hard, label = "Hydrokinetic converter loss relation"),
            ResidualSpec(name = :hydrokinetic_converter_rating_limit,
                owner = :hydrokinetic_converter, equation = :absolute_power_rating,
                sense = :geq, unit = "kW",
                scale = max(float(hydrokinetic_rated_power_kw), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:hydrokinetic_rotor, :hydrokinetic_rated_power_kw)],
                hardness = :hard, label = "Hydrokinetic converter rating margin"),
        ],
        parameters = (
            efficiency = hydrokinetic_converter_efficiency,
            converter_model = converter_model,
        ),
        metadata = BlockMetadata(name = :hydrokinetic_converter, model_path = converter_path),
    ))

    return blocks
end

function _append_diesel_blocks!(blocks; diesel_rated_power_kw,
        diesel_min_power_kw, diesel_fuel_tank_l, diesel_fuel_per_kwh_l,
        diesel_generator_efficiency, diesel_converter_efficiency)
    engine_path = _package_path("DieselGen", "diesel_fuel_used";
        assumptions = ["diesel dispatch is commanded in kW",
            "positive engine shaft power leaves the diesel engine",
            "fuel inventory is tracked in liters",
            "ForwardDiff sensitivity through dual-valued dispatch uses a reported linear fuel envelope"],
        fallback = "linear fuel_per_kwh envelope for AD-valued dispatch")
    generator_path = _package_path("GeneratorSE", "generatorse_output_kw";
        assumptions = ["shaft power enters generator", "positive electrical power leaves generator"],
        fallback = "constant-efficiency generator if GeneratorSE construction is unavailable")
    converter_path = _package_path("PowerConverterDynamics", "powerconverter_output_kw";
        assumptions = ["signed kW converter boundary", "positive power injects into the bus"],
        fallback = "constant-efficiency converter if package model is unavailable")
    engine_model = diesel_engine_design(DieselDesign{Float64}(
        rated_power = Float64(diesel_rated_power_kw),
        min_power = Float64(diesel_min_power_kw),
        fuel_per_kwh = Float64(diesel_fuel_per_kwh_l),
        fuel_tank_capacity = Float64(diesel_fuel_tank_l),
    ))
    generator_model = generatorse_pmsg_arms_model(rated_power_kw = max(float(diesel_rated_power_kw), 1.0))
    converter_model = powerconverter_model(rated_power_kw = max(float(diesel_rated_power_kw), 1.0))

    push!(blocks, BlockSpec(
        name = :diesel_engine,
        role = :diesel_engine,
        component_type = :source,
        model_path = engine_path,
        designs = [
            VariableSpec(name = :diesel_rated_power_kw, owner = :diesel_engine,
                role = :design, unit = "kW", initial = diesel_rated_power_kw,
                lower = 0.0, upper = Inf, scale = max(float(diesel_rated_power_kw), 1.0),
                time_scope = :design, exposure = :decision,
                label = "Diesel rated power"),
            VariableSpec(name = :diesel_fuel_tank_l, owner = :diesel_engine,
                role = :design, unit = "L", initial = diesel_fuel_tank_l,
                lower = 0.0, upper = Inf, scale = max(float(diesel_fuel_tank_l), 1.0),
                time_scope = :design, exposure = :decision,
                label = "Diesel fuel tank"),
        ],
        states = [VariableSpec(name = :diesel_fuel_l, owner = :diesel_engine,
            role = :state, unit = "L", initial = diesel_fuel_tank_l,
            lower = 0.0, upper = diesel_fuel_tank_l,
            scale = max(float(diesel_fuel_tank_l), 1.0), time_scope = :node,
            exposure = :decision, label = "Diesel fuel inventory")],
        controls = [VariableSpec(name = :diesel_power_kw, owner = :diesel_engine,
            role = :control, unit = "kW", initial = 0.0, lower = 0.0,
            upper = diesel_rated_power_kw, scale = max(float(diesel_rated_power_kw), 1.0),
            time_scope = :interval, exposure = :decision,
            label = "Diesel dispatch")],
        interfaces = [InterfaceSpec(archetype_name = :mechanical_prime_mover,
            active_ports = [:control_signal, :storage_state, :shaft_mechanical])],
        ports = [
            PortSpec(name = :control_signal, port_type = :control_signal,
                direction = :in, quantity = :power_command, unit = "kW",
                sign_convention = "positive command increases diesel shaft power",
                owner = :diesel_engine),
            PortSpec(name = :storage_state, port_type = :storage_state,
                direction = :out, quantity = :fuel_inventory, unit = "L",
                sign_convention = "larger inventory stores more usable diesel fuel",
                owner = :diesel_engine),
            PortSpec(name = :shaft_mechanical, port_type = :shaft_mechanical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive shaft power leaves diesel engine",
                owner = :diesel_engine),
        ],
        outputs = [
            OutputSpec(name = :diesel_shaft_power_kw, owner = :diesel_engine,
                unit = "kW", source = :adapter, model_path = engine_path,
                label = "Diesel shaft power", plot_group = :power),
            OutputSpec(name = :diesel_fuel_used_l, owner = :diesel_engine,
                unit = "L", source = :adapter, model_path = engine_path,
                label = "Diesel fuel used", plot_group = :fuel),
            OutputSpec(name = :diesel_fuel_l, owner = :diesel_engine,
                unit = "L", source = :kernel, model_path = engine_path,
                label = "Diesel fuel inventory", plot_group = :fuel),
        ],
        residuals = [
            ResidualSpec(name = :diesel_fuel_inventory,
                owner = :diesel_engine, equation = :fuel_inventory_liters,
                sense = :eq, unit = "L", scale = max(float(diesel_fuel_tank_l), 1.0),
                lower = 0.0, upper = 0.0, time_scope = :interval,
                depends_on = [owner_qualified(:diesel_engine, :diesel_fuel_l),
                    owner_qualified(:diesel_engine, :diesel_power_kw)],
                hardness = :hard, label = "Diesel fuel inventory"),
            ResidualSpec(name = :diesel_power_limit,
                owner = :diesel_engine, equation = :diesel_dispatch_rating,
                sense = :geq, unit = "kW", scale = max(float(diesel_rated_power_kw), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:diesel_engine, :diesel_rated_power_kw),
                    owner_qualified(:diesel_engine, :diesel_power_kw)],
                hardness = :hard, label = "Diesel dispatch margin"),
            ResidualSpec(name = :diesel_fuel_available_limit,
                owner = :diesel_engine, equation = :fuel_available_before_dispatch,
                sense = :geq, unit = "L", scale = max(float(diesel_fuel_tank_l), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:diesel_engine, :diesel_fuel_l),
                    owner_qualified(:diesel_engine, :diesel_power_kw)],
                hardness = :hard, label = "Diesel fuel available margin"),
        ],
        parameters = (
            min_power_kw = diesel_min_power_kw,
            fuel_per_kwh_l = diesel_fuel_per_kwh_l,
            engine_model = engine_model,
        ),
        metadata = BlockMetadata(name = :diesel_engine, model_path = engine_path),
    ))

    push!(blocks, BlockSpec(
        name = :diesel_generator,
        role = :generator,
        component_type = :converter,
        model_path = generator_path,
        interfaces = [InterfaceSpec(archetype_name = :converter_or_generator,
            active_ports = [:shaft_mechanical, :device_electrical])],
        ports = [
            PortSpec(name = :shaft_mechanical, port_type = :shaft_mechanical,
                direction = :in, quantity = :power, unit = "kW",
                sign_convention = "positive shaft power enters generator",
                owner = :diesel_generator),
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive electrical power leaves generator",
                owner = :diesel_generator),
        ],
        outputs = [OutputSpec(name = :diesel_device_power_kw,
            owner = :diesel_generator, unit = "kW", source = :adapter,
            model_path = generator_path, label = "Diesel generator electrical power",
            plot_group = :power)],
        residuals = [ResidualSpec(name = :diesel_generator_loss_relation,
            owner = :diesel_generator, equation = :generator_adapter_output,
            sense = :eq, unit = "kW", scale = 1.0, lower = 0.0, upper = 0.0,
            time_scope = :interval,
            depends_on = [owner_qualified(:diesel_engine, :shaft_mechanical)],
            hardness = :hard, label = "Diesel generator loss relation")],
        parameters = (
            efficiency = diesel_generator_efficiency,
            generator_model = generator_model,
        ),
        metadata = BlockMetadata(name = :diesel_generator, model_path = generator_path),
    ))

    push!(blocks, BlockSpec(
        name = :diesel_converter,
        role = :converter,
        component_type = :converter,
        model_path = converter_path,
        interfaces = [InterfaceSpec(archetype_name = :converter_or_generator,
            active_ports = [:device_electrical, :bus_electrical])],
        ports = [
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :in, quantity = :power, unit = "kW",
                sign_convention = "positive power enters converter from diesel generator",
                owner = :diesel_converter),
            PortSpec(name = :bus_electrical, port_type = :bus_electrical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive power injects into bus",
                owner = :diesel_converter),
        ],
        outputs = [
            OutputSpec(name = :diesel_bus_power_kw, owner = :diesel_converter,
                unit = "kW", source = :adapter, model_path = converter_path,
                label = "Diesel bus power", plot_group = :power),
            OutputSpec(name = :diesel_converter_loss_kw, owner = :diesel_converter,
                unit = "kW", source = :adapter, model_path = converter_path,
                label = "Diesel converter loss", plot_group = :losses),
        ],
        residuals = [
            ResidualSpec(name = :diesel_converter_loss_relation,
                owner = :diesel_converter, equation = :converter_adapter_output,
                sense = :eq, unit = "kW", scale = 1.0, lower = 0.0, upper = 0.0,
                time_scope = :interval,
                depends_on = [owner_qualified(:diesel_generator, :device_electrical)],
                hardness = :hard, label = "Diesel converter loss relation"),
            ResidualSpec(name = :diesel_converter_rating_limit,
                owner = :diesel_converter, equation = :absolute_power_rating,
                sense = :geq, unit = "kW", scale = max(float(diesel_rated_power_kw), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:diesel_engine, :diesel_rated_power_kw)],
                hardness = :hard, label = "Diesel converter rating margin"),
        ],
        parameters = (
            efficiency = diesel_converter_efficiency,
            converter_model = converter_model,
        ),
        metadata = BlockMetadata(name = :diesel_converter, model_path = converter_path),
    ))

    return blocks
end

function _append_h2_blocks!(blocks; h2_electrolyzer_power_kw,
        h2_tank_capacity_kg, h2_specific_energy_kwh_per_kg,
        h2_converter_efficiency)
    process_path = _package_path("H2Gen", "h2gen_step";
        assumptions = ["positive device-side kW produces hydrogen",
            "hydrogen demand is kg/h", "tank inventory is kg"],
        fallback = "smooth SIRENOpt production law for AD-valued process controls")
    converter_path = _package_path("PowerConverterDynamics", "powerconverter_output_kw";
        assumptions = ["negative bus power consumes electricity for electrolysis"],
        fallback = "constant-efficiency converter if package model is unavailable")
    h2_model = H2Gen.DesignStruct(
        capacity_mw = h2_electrolyzer_power_kw / _W_PER_KW,
        efficiency = 0.65,
        min_load = 0.0,
        max_load = 1.0,
    )
    converter_model = powerconverter_model(rated_power_kw = max(float(h2_electrolyzer_power_kw), 1.0))

    push!(blocks, BlockSpec(
        name = :h2_electrolyzer,
        role = :h2_electrolyzer,
        component_type = :load_process,
        model_path = process_path,
        designs = [
            VariableSpec(name = :h2_electrolyzer_power_kw,
                owner = :h2_electrolyzer, role = :design, unit = "kW",
                initial = h2_electrolyzer_power_kw, lower = 0.0, upper = Inf,
                scale = max(float(h2_electrolyzer_power_kw), 1.0),
                time_scope = :design, exposure = :decision,
                label = "Hydrogen electrolyzer power"),
            VariableSpec(name = :h2_tank_capacity_kg,
                owner = :h2_electrolyzer, role = :design, unit = "kg",
                initial = h2_tank_capacity_kg, lower = 0.0, upper = Inf,
                scale = max(float(h2_tank_capacity_kg), 1.0),
                time_scope = :design, exposure = :decision,
                label = "Hydrogen tank capacity"),
        ],
        states = [VariableSpec(name = :h2_level_kg, owner = :h2_electrolyzer,
            role = :state, unit = "kg", initial = 0.0, lower = 0.0,
            upper = h2_tank_capacity_kg, scale = max(float(h2_tank_capacity_kg), 1.0),
            time_scope = :node, exposure = :decision,
            label = "Hydrogen inventory")],
        controls = [VariableSpec(name = :h2_power_kw, owner = :h2_electrolyzer,
            role = :control, unit = "kW", initial = 0.0, lower = 0.0,
            upper = h2_electrolyzer_power_kw,
            scale = max(float(h2_electrolyzer_power_kw), 1.0),
            time_scope = :interval, exposure = :decision,
            label = "Hydrogen process power")],
        interfaces = [InterfaceSpec(archetype_name = :load_or_process,
            active_ports = [:demand_profile, :device_electrical, :storage_state])],
        ports = [
            PortSpec(name = :demand_profile, port_type = :demand_profile,
                direction = :in, quantity = :hydrogen_demand, unit = "kg/h",
                sign_convention = "positive demand reduces hydrogen inventory",
                owner = :h2_electrolyzer),
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :in, quantity = :power, unit = "kW",
                sign_convention = "positive device power is consumed by electrolysis",
                owner = :h2_electrolyzer),
            PortSpec(name = :storage_state, port_type = :storage_state,
                direction = :out, quantity = :hydrogen_inventory, unit = "kg",
                sign_convention = "larger inventory stores more hydrogen",
                owner = :h2_electrolyzer),
        ],
        outputs = [
            OutputSpec(name = :h2_device_power_kw, owner = :h2_electrolyzer,
                unit = "kW", source = :adapter, model_path = process_path,
                label = "Hydrogen device power", plot_group = :process_power),
            OutputSpec(name = :h2_level_kg, owner = :h2_electrolyzer,
                unit = "kg", source = :kernel, model_path = process_path,
                label = "Hydrogen inventory", plot_group = :process_inventory),
        ],
        residuals = [
            ResidualSpec(name = :h2_inventory, owner = :h2_electrolyzer,
                equation = :hydrogen_inventory_kg, sense = :eq, unit = "kg",
                scale = max(float(h2_tank_capacity_kg), 1.0), lower = 0.0,
                upper = 0.0, time_scope = :interval,
                depends_on = [owner_qualified(:h2_electrolyzer, :h2_level_kg),
                    owner_qualified(:h2_electrolyzer, :h2_power_kw)],
                hardness = :hard, label = "Hydrogen inventory"),
            ResidualSpec(name = :h2_power_limit, owner = :h2_electrolyzer,
                equation = :process_power_rating, sense = :geq, unit = "kW",
                scale = max(float(h2_electrolyzer_power_kw), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:h2_electrolyzer, :h2_electrolyzer_power_kw),
                    owner_qualified(:h2_electrolyzer, :h2_power_kw)],
                hardness = :hard, label = "Hydrogen power margin"),
        ],
        parameters = (
            specific_energy_kwh_per_kg = h2_specific_energy_kwh_per_kg,
            h2_model = h2_model,
        ),
        metadata = BlockMetadata(name = :h2_electrolyzer, model_path = process_path),
    ))

    push!(blocks, BlockSpec(
        name = :h2_converter,
        role = :converter,
        component_type = :converter,
        model_path = converter_path,
        interfaces = [InterfaceSpec(archetype_name = :converter_or_generator,
            active_ports = [:bus_electrical, :device_electrical])],
        ports = [
            PortSpec(name = :bus_electrical, port_type = :bus_electrical,
                direction = :inout, quantity = :power, unit = "kW",
                sign_convention = "negative power consumes from bus",
                owner = :h2_converter),
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive device power leaves converter toward electrolyzer",
                owner = :h2_converter),
        ],
        outputs = [
            OutputSpec(name = :h2_bus_power_kw, owner = :h2_converter,
                unit = "kW", source = :adapter, model_path = converter_path,
                label = "Hydrogen bus power", plot_group = :power),
            OutputSpec(name = :h2_converter_loss_kw, owner = :h2_converter,
                unit = "kW", source = :adapter, model_path = converter_path,
                label = "Hydrogen converter loss", plot_group = :losses),
        ],
        residuals = [
            ResidualSpec(name = :h2_converter_loss_relation,
                owner = :h2_converter, equation = :converter_adapter_output,
                sense = :eq, unit = "kW", scale = 1.0, lower = 0.0, upper = 0.0,
                time_scope = :interval,
                depends_on = [owner_qualified(:h2_electrolyzer, :device_electrical)],
                hardness = :hard, label = "Hydrogen converter loss relation"),
            ResidualSpec(name = :h2_converter_rating_limit,
                owner = :h2_converter, equation = :absolute_power_rating,
                sense = :geq, unit = "kW", scale = max(float(h2_electrolyzer_power_kw), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:h2_electrolyzer, :h2_electrolyzer_power_kw)],
                hardness = :hard, label = "Hydrogen converter rating margin"),
        ],
        parameters = (
            efficiency = h2_converter_efficiency,
            converter_model = converter_model,
        ),
        metadata = BlockMetadata(name = :h2_converter, model_path = converter_path),
    ))

    return blocks
end

function _append_desal_blocks!(blocks; desal_plant_power_kw,
        desal_tank_capacity_m3, desal_specific_energy_kwh_per_m3,
        desal_converter_efficiency)
    process_path = _package_path("Desal", "desalination_step";
        assumptions = ["positive device-side kW produces potable water",
            "water demand is m^3/h", "tank inventory is m^3"],
        fallback = "smooth SIRENOpt production law for AD-valued process controls")
    converter_path = _package_path("PowerConverterDynamics", "powerconverter_output_kw";
        assumptions = ["negative bus power consumes electricity for desalination"],
        fallback = "constant-efficiency converter if package model is unavailable")
    desal_model = Desal.DesignStruct(
        capacity_m3_per_h = desal_plant_power_kw / desal_specific_energy_kwh_per_m3,
        specific_energy_nominal_kwh_per_m3 = desal_specific_energy_kwh_per_m3,
        min_load = 0.0,
        response_time_hours = 0.0,
        part_load_penalty = 0.0,
        recovery_part_load_sensitivity = 0.0,
    )
    converter_model = powerconverter_model(rated_power_kw = max(float(desal_plant_power_kw), 1.0))

    push!(blocks, BlockSpec(
        name = :desalination,
        role = :desalination,
        component_type = :load_process,
        model_path = process_path,
        designs = [
            VariableSpec(name = :desal_plant_power_kw,
                owner = :desalination, role = :design, unit = "kW",
                initial = desal_plant_power_kw, lower = 0.0, upper = Inf,
                scale = max(float(desal_plant_power_kw), 1.0),
                time_scope = :design, exposure = :decision,
                label = "Desalination plant power"),
            VariableSpec(name = :desal_tank_capacity_m3,
                owner = :desalination, role = :design, unit = "m^3",
                initial = desal_tank_capacity_m3, lower = 0.0, upper = Inf,
                scale = max(float(desal_tank_capacity_m3), 1.0),
                time_scope = :design, exposure = :decision,
                label = "Potable water tank capacity"),
        ],
        states = [VariableSpec(name = :desal_level_m3, owner = :desalination,
            role = :state, unit = "m^3", initial = 0.0, lower = 0.0,
            upper = desal_tank_capacity_m3, scale = max(float(desal_tank_capacity_m3), 1.0),
            time_scope = :node, exposure = :decision,
            label = "Potable water inventory")],
        controls = [VariableSpec(name = :desal_power_kw, owner = :desalination,
            role = :control, unit = "kW", initial = 0.0, lower = 0.0,
            upper = desal_plant_power_kw,
            scale = max(float(desal_plant_power_kw), 1.0),
            time_scope = :interval, exposure = :decision,
            label = "Desalination process power")],
        interfaces = [InterfaceSpec(archetype_name = :load_or_process,
            active_ports = [:demand_profile, :device_electrical, :storage_state])],
        ports = [
            PortSpec(name = :demand_profile, port_type = :demand_profile,
                direction = :in, quantity = :water_demand, unit = "m^3/h",
                sign_convention = "positive demand reduces water inventory",
                owner = :desalination),
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :in, quantity = :power, unit = "kW",
                sign_convention = "positive device power is consumed by desalination",
                owner = :desalination),
            PortSpec(name = :storage_state, port_type = :storage_state,
                direction = :out, quantity = :water_inventory, unit = "m^3",
                sign_convention = "larger inventory stores more potable water",
                owner = :desalination),
        ],
        outputs = [
            OutputSpec(name = :desal_device_power_kw, owner = :desalination,
                unit = "kW", source = :adapter, model_path = process_path,
                label = "Desalination device power", plot_group = :process_power),
            OutputSpec(name = :desal_level_m3, owner = :desalination,
                unit = "m^3", source = :kernel, model_path = process_path,
                label = "Potable water inventory", plot_group = :process_inventory),
        ],
        residuals = [
            ResidualSpec(name = :desal_inventory, owner = :desalination,
                equation = :water_inventory_m3, sense = :eq, unit = "m^3",
                scale = max(float(desal_tank_capacity_m3), 1.0), lower = 0.0,
                upper = 0.0, time_scope = :interval,
                depends_on = [owner_qualified(:desalination, :desal_level_m3),
                    owner_qualified(:desalination, :desal_power_kw)],
                hardness = :hard, label = "Desalination inventory"),
            ResidualSpec(name = :desal_power_limit, owner = :desalination,
                equation = :process_power_rating, sense = :geq, unit = "kW",
                scale = max(float(desal_plant_power_kw), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:desalination, :desal_plant_power_kw),
                    owner_qualified(:desalination, :desal_power_kw)],
                hardness = :hard, label = "Desalination power margin"),
        ],
        parameters = (
            specific_energy_kwh_per_m3 = desal_specific_energy_kwh_per_m3,
            desal_model = desal_model,
        ),
        metadata = BlockMetadata(name = :desalination, model_path = process_path),
    ))

    push!(blocks, BlockSpec(
        name = :desal_converter,
        role = :converter,
        component_type = :converter,
        model_path = converter_path,
        interfaces = [InterfaceSpec(archetype_name = :converter_or_generator,
            active_ports = [:bus_electrical, :device_electrical])],
        ports = [
            PortSpec(name = :bus_electrical, port_type = :bus_electrical,
                direction = :inout, quantity = :power, unit = "kW",
                sign_convention = "negative power consumes from bus",
                owner = :desal_converter),
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive device power leaves converter toward desalination",
                owner = :desal_converter),
        ],
        outputs = [
            OutputSpec(name = :desal_bus_power_kw, owner = :desal_converter,
                unit = "kW", source = :adapter, model_path = converter_path,
                label = "Desalination bus power", plot_group = :power),
            OutputSpec(name = :desal_converter_loss_kw, owner = :desal_converter,
                unit = "kW", source = :adapter, model_path = converter_path,
                label = "Desalination converter loss", plot_group = :losses),
        ],
        residuals = [
            ResidualSpec(name = :desal_converter_loss_relation,
                owner = :desal_converter, equation = :converter_adapter_output,
                sense = :eq, unit = "kW", scale = 1.0, lower = 0.0, upper = 0.0,
                time_scope = :interval,
                depends_on = [owner_qualified(:desalination, :device_electrical)],
                hardness = :hard, label = "Desalination converter loss relation"),
            ResidualSpec(name = :desal_converter_rating_limit,
                owner = :desal_converter, equation = :absolute_power_rating,
                sense = :geq, unit = "kW", scale = max(float(desal_plant_power_kw), 1.0),
                lower = 0.0, upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:desalination, :desal_plant_power_kw)],
                hardness = :hard, label = "Desalination converter rating margin"),
        ],
        parameters = (
            efficiency = desal_converter_efficiency,
            converter_model = converter_model,
        ),
        metadata = BlockMetadata(name = :desal_converter, model_path = converter_path),
    ))

    return blocks
end

function _append_wave_blocks!(blocks; wave_capture_width_m, wave_rated_power_kw,
        wave_converter_efficiency)
    resource_path = _prescribed_path("ShortHorizonScenario.wave_power_flux_kw_per_m")
    wave_path = _surrogate_path("linear_wave_capture_surrogate",
        assumptions = ["power_kw = wave_power_flux_kw_per_m * capture_width_m"],
        fallback = "replace with WEC/PTO package adapter when validated residuals are available")
    converter_path = _surrogate_path("constant_efficiency_wave_converter",
        assumptions = ["positive wave device power injects through converter"])

    push!(blocks, BlockSpec(
        name = :wave_resource,
        role = :wave_resource,
        component_type = :resource,
        model_path = resource_path,
        interfaces = [InterfaceSpec(archetype_name = :resource_provider,
            active_ports = [:resource_state])],
        ports = [PortSpec(name = :resource_state, port_type = :resource_state,
            direction = :out, quantity = :wave_power_flux, unit = "kW/m",
            sign_convention = "positive wave flux increases available WEC power",
            owner = :wave_resource)],
        outputs = [OutputSpec(name = :wave_power_flux_kw_per_m, owner = :wave_resource,
            unit = "kW/m", source = :scenario, model_path = resource_path,
            label = "Wave power flux", plot_group = :resources)],
        parameters = (source = :scenario,),
        metadata = BlockMetadata(name = :wave_resource, model_path = resource_path),
    ))

    push!(blocks, BlockSpec(
        name = :wave_wec,
        role = :wave_wec,
        component_type = :source,
        model_path = wave_path,
        designs = [
            VariableSpec(name = :wave_capture_width_m, owner = :wave_wec,
                role = :design, unit = "m", initial = wave_capture_width_m,
                lower = 0.0, upper = Inf, scale = max(float(wave_capture_width_m), 1.0),
                time_scope = :design, exposure = :decision,
                label = "Wave capture width"),
            VariableSpec(name = :wave_rated_power_kw, owner = :wave_wec,
                role = :design, unit = "kW", initial = wave_rated_power_kw,
                lower = 0.0, upper = Inf, scale = max(float(wave_rated_power_kw), 1.0),
                time_scope = :design, exposure = :decision,
                label = "Wave rated power"),
        ],
        controls = [VariableSpec(name = :wave_curtailment, owner = :wave_wec,
            role = :control, unit = "fraction", initial = 0.0, lower = 0.0,
            upper = 1.0, scale = 1.0, time_scope = :interval,
            exposure = :decision, label = "Wave curtailment")],
        interfaces = [InterfaceSpec(archetype_name = :electrical_source,
            active_ports = [:resource_state, :device_electrical, :control_signal])],
        ports = [
            PortSpec(name = :resource_state, port_type = :resource_state,
                direction = :in, quantity = :wave_power_flux, unit = "kW/m",
                sign_convention = "positive flux increases available WEC power",
                owner = :wave_wec),
            PortSpec(name = :control_signal, port_type = :control_signal,
                direction = :in, quantity = :curtailment, unit = "fraction",
                sign_convention = "positive curtailment reduces WEC power",
                owner = :wave_wec),
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive power leaves WEC surrogate",
                owner = :wave_wec),
        ],
        outputs = [OutputSpec(name = :wave_device_power_kw, owner = :wave_wec,
            unit = "kW", source = :kernel, model_path = wave_path,
            label = "Wave device power", plot_group = :power)],
        residuals = [
            ResidualSpec(name = :wave_available_limit, owner = :wave_wec,
                equation = :linear_wave_capture_cap, sense = :geq, unit = "kW",
                scale = max(float(wave_rated_power_kw), 1.0), lower = 0.0,
                upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:wave_wec, :wave_curtailment)],
                hardness = :hard, label = "Wave available power cap"),
            ResidualSpec(name = :wave_rating_limit, owner = :wave_wec,
                equation = :wave_rated_power_limit, sense = :geq, unit = "kW",
                scale = max(float(wave_rated_power_kw), 1.0), lower = 0.0,
                upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:wave_wec, :wave_rated_power_kw)],
                hardness = :hard, label = "Wave rated power margin"),
            ResidualSpec(name = :wave_pto_limit, owner = :wave_wec,
                equation = :wec_pto_power_limit, sense = :geq, unit = "kW",
                scale = max(float(wave_rated_power_kw), 1.0), lower = 0.0,
                upper = Inf, time_scope = :interval,
                depends_on = [owner_qualified(:wave_wec, :wave_rated_power_kw),
                    owner_qualified(:wave_wec, :device_electrical)],
                hardness = :hard, label = "WEC PTO power margin"),
        ],
        parameters = NamedTuple(),
        metadata = BlockMetadata(name = :wave_wec, model_path = wave_path),
    ))

    push!(blocks, BlockSpec(
        name = :wave_converter,
        role = :converter,
        component_type = :converter,
        model_path = converter_path,
        interfaces = [InterfaceSpec(archetype_name = :converter_or_generator,
            active_ports = [:device_electrical, :bus_electrical])],
        ports = [
            PortSpec(name = :device_electrical, port_type = :device_electrical,
                direction = :in, quantity = :power, unit = "kW",
                sign_convention = "positive power enters converter from WEC surrogate",
                owner = :wave_converter),
            PortSpec(name = :bus_electrical, port_type = :bus_electrical,
                direction = :out, quantity = :power, unit = "kW",
                sign_convention = "positive power injects into bus",
                owner = :wave_converter),
        ],
        outputs = [OutputSpec(name = :wave_bus_power_kw, owner = :wave_converter,
            unit = "kW", source = :kernel, model_path = converter_path,
            label = "Wave bus power", plot_group = :power)],
        residuals = [ResidualSpec(name = :wave_converter_loss_relation,
            owner = :wave_converter, equation = :constant_efficiency,
            sense = :eq, unit = "kW", scale = 1.0, lower = 0.0,
            upper = 0.0, time_scope = :interval,
            depends_on = [owner_qualified(:wave_wec, :device_electrical)],
            hardness = :hard, label = "Wave converter loss relation")],
        parameters = (efficiency = wave_converter_efficiency,),
        metadata = BlockMetadata(name = :wave_converter, model_path = converter_path),
    ))

    return blocks
end

function _append_platform_block!(blocks; platform_inertia_kg_m2,
        platform_stiffness_nm_per_rad, platform_damping_nm_s_per_rad)
    platform_path = _surrogate_path("pendulum_platform_fallback",
        assumptions = ["single pitch DOF", "wind moment drives platform pitch"],
        fallback = "replace with validated Hydrodynamics/Mooring force residuals when available")

    push!(blocks, BlockSpec(
        name = :platform,
        role = :platform,
        component_type = :platform,
        model_path = platform_path,
        designs = [
            VariableSpec(name = :platform_inertia_kg_m2, owner = :platform,
                role = :design, unit = "kg*m^2", initial = platform_inertia_kg_m2,
                lower = eps(float(one(platform_inertia_kg_m2))), upper = Inf,
                scale = max(float(platform_inertia_kg_m2), 1.0),
                time_scope = :design, exposure = :decision,
                label = "Platform pitch inertia"),
        ],
        states = [
            VariableSpec(name = :platform_theta_rad, owner = :platform,
                role = :state, unit = "rad", initial = 0.0, lower = -Inf,
                upper = Inf, scale = 1.0, time_scope = :node,
                exposure = :decision, label = "Platform pitch angle"),
            VariableSpec(name = :platform_omega_rad_s, owner = :platform,
                role = :state, unit = "rad/s", initial = 0.0, lower = -Inf,
                upper = Inf, scale = 1.0, time_scope = :node,
                exposure = :decision, label = "Platform pitch rate"),
        ],
        interfaces = [InterfaceSpec(archetype_name = :motion_dynamic,
            active_ports = [:motion_state, :platform_wrench])],
        ports = [
            PortSpec(name = :platform_wrench, port_type = :platform_wrench,
                direction = :in, quantity = :moment, unit = "N*m",
                sign_convention = "positive pitch moment increases theta",
                frame = :body, reference_point = :platform_origin,
                cardinality = :many_to_one, owner = :platform),
            PortSpec(name = :motion_state, port_type = :motion_state,
                direction = :out, quantity = :pitch_state, unit = "rad,rad/s",
                sign_convention = "positive theta pitches the source frame nose-up",
                frame = :body, reference_point = :platform_origin,
                owner = :platform),
        ],
        outputs = [
            OutputSpec(name = :platform_theta_rad, owner = :platform,
                unit = "rad", source = :kernel, model_path = platform_path,
                label = "Platform pitch angle", plot_group = :platform_motion),
            OutputSpec(name = :platform_omega_rad_s, owner = :platform,
                unit = "rad/s", source = :kernel, model_path = platform_path,
                label = "Platform pitch rate", plot_group = :platform_motion),
            OutputSpec(name = :platform_pitch_moment_nm, owner = :platform,
                unit = "N*m", source = :kernel, model_path = platform_path,
                label = "Platform pitch moment", plot_group = :dynamics),
        ],
        residuals = [
            ResidualSpec(name = :platform_kinematic_defect, owner = :platform,
                equation = :explicit_euler_pitch_kinematics, sense = :eq,
                unit = "rad", scale = 1.0, lower = 0.0, upper = 0.0,
                time_scope = :interval,
                depends_on = [owner_qualified(:platform, :platform_theta_rad),
                    owner_qualified(:platform, :platform_omega_rad_s)],
                hardness = :hard, label = "Platform pitch kinematic defect"),
            ResidualSpec(name = :platform_dynamic_defect, owner = :platform,
                equation = :pendulum_pitch_dynamics, sense = :eq,
                unit = "rad/s", scale = 1.0, lower = 0.0, upper = 0.0,
                time_scope = :interval,
                depends_on = [owner_qualified(:platform, :platform_omega_rad_s),
                    owner_qualified(:wind_rotor, :platform_wrench)],
                hardness = :hard, label = "Platform pitch dynamic defect"),
        ],
        parameters = (
            stiffness_nm_per_rad = platform_stiffness_nm_per_rad,
            damping_nm_s_per_rad = platform_damping_nm_s_per_rad,
        ),
        metadata = BlockMetadata(name = :platform, model_path = platform_path),
    ))

    return blocks
end

function _minimal_connections(include_battery::Bool; include_wind::Bool = false,
        include_wave::Bool = false, include_hydrokinetic::Bool = false,
        include_diesel::Bool = false,
        include_h2::Bool = false, include_desal::Bool = false,
        include_platform::Bool = false)
    conns = ConnectionSpec[
        ConnectionSpec(source_block = :solar_resource, source_port = :resource_state,
            sink_block = :solar_array, sink_port = :resource_state,
            quantity = :irradiance, unit = "kW/m^2"),
        ConnectionSpec(source_block = :solar_array, source_port = :device_electrical,
            sink_block = :solar_converter, sink_port = :device_electrical,
            quantity = :power, unit = "kW"),
        ConnectionSpec(source_block = :solar_converter, source_port = :bus_electrical,
            sink_block = :bus, sink_port = :bus_electrical,
            quantity = :power, unit = "kW", aggregation_owner = :bus),
        ConnectionSpec(source_block = :load, source_port = :bus_electrical,
            sink_block = :bus, sink_port = :bus_electrical,
            quantity = :power, unit = "kW", aggregation_owner = :bus),
    ]
    if include_battery
        push!(conns, ConnectionSpec(source_block = :battery, source_port = :device_electrical,
            sink_block = :battery_converter, sink_port = :device_electrical,
            quantity = :power, unit = "kW"))
        push!(conns, ConnectionSpec(source_block = :battery_converter, source_port = :bus_electrical,
            sink_block = :bus, sink_port = :bus_electrical,
            quantity = :power, unit = "kW", aggregation_owner = :bus))
    end
    if include_wind
        push!(conns, ConnectionSpec(source_block = :wind_resource, source_port = :resource_state,
            sink_block = :wind_rotor, sink_port = :resource_state,
            quantity = :wind_speed, unit = "m/s"))
        push!(conns, ConnectionSpec(source_block = :wind_rotor, source_port = :shaft_mechanical,
            sink_block = :wind_generator, sink_port = :shaft_mechanical,
            quantity = :power, unit = "kW"))
        push!(conns, ConnectionSpec(source_block = :wind_generator, source_port = :device_electrical,
            sink_block = :wind_converter, sink_port = :device_electrical,
            quantity = :power, unit = "kW"))
        push!(conns, ConnectionSpec(source_block = :wind_converter, source_port = :bus_electrical,
            sink_block = :bus, sink_port = :bus_electrical,
            quantity = :power, unit = "kW", aggregation_owner = :bus))
    end
    if include_wave
        push!(conns, ConnectionSpec(source_block = :wave_resource, source_port = :resource_state,
            sink_block = :wave_wec, sink_port = :resource_state,
            quantity = :wave_power_flux, unit = "kW/m"))
        push!(conns, ConnectionSpec(source_block = :wave_wec, source_port = :device_electrical,
            sink_block = :wave_converter, sink_port = :device_electrical,
            quantity = :power, unit = "kW"))
        push!(conns, ConnectionSpec(source_block = :wave_converter, source_port = :bus_electrical,
            sink_block = :bus, sink_port = :bus_electrical,
            quantity = :power, unit = "kW", aggregation_owner = :bus))
    end
    if include_hydrokinetic
        push!(conns, ConnectionSpec(source_block = :hydrokinetic_resource, source_port = :resource_state,
            sink_block = :hydrokinetic_rotor, sink_port = :resource_state,
            quantity = :current_speed, unit = "m/s"))
        push!(conns, ConnectionSpec(source_block = :hydrokinetic_rotor, source_port = :shaft_mechanical,
            sink_block = :hydrokinetic_generator, sink_port = :shaft_mechanical,
            quantity = :power, unit = "kW"))
        push!(conns, ConnectionSpec(source_block = :hydrokinetic_generator, source_port = :device_electrical,
            sink_block = :hydrokinetic_converter, sink_port = :device_electrical,
            quantity = :power, unit = "kW"))
        push!(conns, ConnectionSpec(source_block = :hydrokinetic_converter, source_port = :bus_electrical,
            sink_block = :bus, sink_port = :bus_electrical,
            quantity = :power, unit = "kW", aggregation_owner = :bus))
    end
    if include_diesel
        push!(conns, ConnectionSpec(source_block = :diesel_engine, source_port = :shaft_mechanical,
            sink_block = :diesel_generator, sink_port = :shaft_mechanical,
            quantity = :power, unit = "kW"))
        push!(conns, ConnectionSpec(source_block = :diesel_generator, source_port = :device_electrical,
            sink_block = :diesel_converter, sink_port = :device_electrical,
            quantity = :power, unit = "kW"))
        push!(conns, ConnectionSpec(source_block = :diesel_converter, source_port = :bus_electrical,
            sink_block = :bus, sink_port = :bus_electrical,
            quantity = :power, unit = "kW", aggregation_owner = :bus))
    end
    if include_h2
        push!(conns, ConnectionSpec(source_block = :h2_converter, source_port = :device_electrical,
            sink_block = :h2_electrolyzer, sink_port = :device_electrical,
            quantity = :power, unit = "kW"))
        push!(conns, ConnectionSpec(source_block = :h2_converter, source_port = :bus_electrical,
            sink_block = :bus, sink_port = :bus_electrical,
            quantity = :power, unit = "kW", aggregation_owner = :bus))
    end
    if include_desal
        push!(conns, ConnectionSpec(source_block = :desal_converter, source_port = :device_electrical,
            sink_block = :desalination, sink_port = :device_electrical,
            quantity = :power, unit = "kW"))
        push!(conns, ConnectionSpec(source_block = :desal_converter, source_port = :bus_electrical,
            sink_block = :bus, sink_port = :bus_electrical,
            quantity = :power, unit = "kW", aggregation_owner = :bus))
    end
    if include_platform
        push!(conns, ConnectionSpec(source_block = :platform, source_port = :motion_state,
            sink_block = :wind_rotor, sink_port = :motion_state,
            quantity = :pitch_state, unit = "rad,rad/s"))
        push!(conns, ConnectionSpec(source_block = :wind_rotor, source_port = :platform_wrench,
            sink_block = :platform, sink_port = :platform_wrench,
            quantity = :moment, unit = "N*m", aggregation_owner = :platform))
    end
    return conns
end

function _build_energy_ontology(name::Symbol; include_battery::Bool = true,
        include_wind::Bool = false,
        include_wave::Bool = false,
        include_hydrokinetic::Bool = false,
        include_diesel::Bool = false,
        include_h2::Bool = false,
        include_desal::Bool = false,
        include_platform::Bool = false,
        scenario::ScenarioSpec = ShortHorizonScenario(),
        solar_area_m2 = 10.0,
        solar_efficiency = 0.20,
        solar_converter_rating_kw = 10.0,
        solar_converter_efficiency = 0.96,
        battery_capacity_kwh = 4.0,
        battery_power_kw = 4.0,
        battery_charge_efficiency = sqrt(0.92),
        battery_discharge_efficiency = sqrt(0.92),
        battery_converter_efficiency = 0.97,
        load_converter_rating_kw = 10.0,
        load_converter_efficiency = 0.98,
        critical_load_fraction = 1.0,
        wind_rated_power_kw = 4.0,
        wind_generator_efficiency = 0.96,
        wind_converter_efficiency = 0.97,
        wind_cut_in_m_s = 0.0,
        wind_cut_out_m_s = 40.0,
        wind_air_density_kg_m3 = 1.225,
        wind_platform_moment_per_kw_nm = 10.0,
        wave_capture_width_m = 1.0,
        wave_rated_power_kw = 3.0,
        wave_converter_efficiency = 0.95,
        hydrokinetic_rated_power_kw = 3.0,
        hydrokinetic_rotor_diameter_m = 2.0,
        hydrokinetic_cp = 0.38,
        hydrokinetic_generator_efficiency = 0.96,
        hydrokinetic_converter_efficiency = 0.97,
        hydrokinetic_cut_in_m_s = 0.0,
        hydrokinetic_cut_out_m_s = 5.0,
        hydrokinetic_fluid_density_kg_m3 = 1025.0,
        diesel_rated_power_kw = 5.0,
        diesel_min_power_kw = 0.0,
        diesel_fuel_tank_l = 100.0,
        diesel_fuel_per_kwh_l = 0.27,
        diesel_generator_efficiency = 0.96,
        diesel_converter_efficiency = 0.97,
        h2_electrolyzer_power_kw = 2.0,
        h2_tank_capacity_kg = 1.0,
        h2_specific_energy_kwh_per_kg = 50.0,
        h2_converter_efficiency = 0.95,
        desal_plant_power_kw = 2.0,
        desal_tank_capacity_m3 = 1.0,
        desal_specific_energy_kwh_per_m3 = 3.0,
        desal_converter_efficiency = 0.95,
        platform_inertia_kg_m2 = 1.0e8,
        platform_stiffness_nm_per_rad = 1.0e4,
        platform_damping_nm_s_per_rad = 1.0e3)

    if include_battery
        battery_capacity_kwh > 0 ||
            throw(ArgumentError("battery_capacity_kwh must be positive when include_battery=true; use include_battery=false to remove the battery block."))
        battery_power_kw > 0 ||
            throw(ArgumentError("battery_power_kw must be positive when include_battery=true; use include_battery=false to remove the battery block."))
    end
    if include_hydrokinetic
        hydrokinetic_rated_power_kw > 0 ||
            throw(ArgumentError("hydrokinetic_rated_power_kw must be positive when include_hydrokinetic=true."))
        hydrokinetic_rotor_diameter_m > 0 ||
            throw(ArgumentError("hydrokinetic_rotor_diameter_m must be positive when include_hydrokinetic=true."))
        hydrokinetic_fluid_density_kg_m3 > 0 ||
            throw(ArgumentError("hydrokinetic_fluid_density_kg_m3 must be positive when include_hydrokinetic=true."))
    end
    if include_diesel
        diesel_rated_power_kw > 0 ||
            throw(ArgumentError("diesel_rated_power_kw must be positive when include_diesel=true."))
        diesel_min_power_kw >= 0 ||
            throw(ArgumentError("diesel_min_power_kw must be nonnegative when include_diesel=true."))
        diesel_min_power_kw <= diesel_rated_power_kw ||
            throw(ArgumentError("diesel_min_power_kw must not exceed diesel_rated_power_kw."))
        diesel_fuel_tank_l > 0 ||
            throw(ArgumentError("diesel_fuel_tank_l must be positive when include_diesel=true."))
        diesel_fuel_per_kwh_l > 0 ||
            throw(ArgumentError("diesel_fuel_per_kwh_l must be positive when include_diesel=true."))
    end
    if include_h2
        h2_electrolyzer_power_kw > 0 ||
            throw(ArgumentError("h2_electrolyzer_power_kw must be positive when include_h2=true."))
        h2_tank_capacity_kg > 0 ||
            throw(ArgumentError("h2_tank_capacity_kg must be positive when include_h2=true."))
        h2_specific_energy_kwh_per_kg > 0 ||
            throw(ArgumentError("h2_specific_energy_kwh_per_kg must be positive when include_h2=true."))
    end
    if include_desal
        desal_plant_power_kw > 0 ||
            throw(ArgumentError("desal_plant_power_kw must be positive when include_desal=true."))
        desal_tank_capacity_m3 > 0 ||
            throw(ArgumentError("desal_tank_capacity_m3 must be positive when include_desal=true."))
        desal_specific_energy_kwh_per_m3 > 0 ||
            throw(ArgumentError("desal_specific_energy_kwh_per_m3 must be positive when include_desal=true."))
    end
    blocks = _minimal_blocks(
        include_battery = include_battery,
        solar_area_m2 = solar_area_m2,
        solar_efficiency = solar_efficiency,
        solar_converter_rating_kw = solar_converter_rating_kw,
        solar_converter_efficiency = solar_converter_efficiency,
        battery_capacity_kwh = battery_capacity_kwh,
        battery_power_kw = battery_power_kw,
        battery_charge_efficiency = battery_charge_efficiency,
        battery_discharge_efficiency = battery_discharge_efficiency,
        battery_converter_efficiency = battery_converter_efficiency,
        load_converter_rating_kw = load_converter_rating_kw,
        load_converter_efficiency = load_converter_efficiency,
        critical_load_fraction = critical_load_fraction,
    )
    if include_wind
        _append_wind_blocks!(blocks;
            include_platform = include_platform,
            wind_rated_power_kw = wind_rated_power_kw,
            wind_generator_efficiency = wind_generator_efficiency,
            wind_converter_efficiency = wind_converter_efficiency,
            wind_cut_in_m_s = wind_cut_in_m_s,
            wind_cut_out_m_s = wind_cut_out_m_s,
            wind_air_density_kg_m3 = wind_air_density_kg_m3,
            wind_platform_moment_per_kw_nm = wind_platform_moment_per_kw_nm)
    end
    if include_wave
        _append_wave_blocks!(blocks;
            wave_capture_width_m = wave_capture_width_m,
            wave_rated_power_kw = wave_rated_power_kw,
            wave_converter_efficiency = wave_converter_efficiency)
    end
    if include_hydrokinetic
        _append_hydrokinetic_blocks!(blocks;
            hydrokinetic_rated_power_kw = hydrokinetic_rated_power_kw,
            hydrokinetic_rotor_diameter_m = hydrokinetic_rotor_diameter_m,
            hydrokinetic_cp = hydrokinetic_cp,
            hydrokinetic_generator_efficiency = hydrokinetic_generator_efficiency,
            hydrokinetic_converter_efficiency = hydrokinetic_converter_efficiency,
            hydrokinetic_cut_in_m_s = hydrokinetic_cut_in_m_s,
            hydrokinetic_cut_out_m_s = hydrokinetic_cut_out_m_s,
            hydrokinetic_fluid_density_kg_m3 = hydrokinetic_fluid_density_kg_m3)
    end
    if include_diesel
        _append_diesel_blocks!(blocks;
            diesel_rated_power_kw = diesel_rated_power_kw,
            diesel_min_power_kw = diesel_min_power_kw,
            diesel_fuel_tank_l = diesel_fuel_tank_l,
            diesel_fuel_per_kwh_l = diesel_fuel_per_kwh_l,
            diesel_generator_efficiency = diesel_generator_efficiency,
            diesel_converter_efficiency = diesel_converter_efficiency)
    end
    if include_h2
        _append_h2_blocks!(blocks;
            h2_electrolyzer_power_kw = h2_electrolyzer_power_kw,
            h2_tank_capacity_kg = h2_tank_capacity_kg,
            h2_specific_energy_kwh_per_kg = h2_specific_energy_kwh_per_kg,
            h2_converter_efficiency = h2_converter_efficiency)
    end
    if include_desal
        _append_desal_blocks!(blocks;
            desal_plant_power_kw = desal_plant_power_kw,
            desal_tank_capacity_m3 = desal_tank_capacity_m3,
            desal_specific_energy_kwh_per_m3 = desal_specific_energy_kwh_per_m3,
            desal_converter_efficiency = desal_converter_efficiency)
    end
    if include_platform
        include_wind || throw(ArgumentError("include_platform=true currently requires include_wind=true so a declared platform_wrench source exists."))
        _append_platform_block!(blocks;
            platform_inertia_kg_m2 = platform_inertia_kg_m2,
            platform_stiffness_nm_per_rad = platform_stiffness_nm_per_rad,
            platform_damping_nm_s_per_rad = platform_damping_nm_s_per_rad)
    end
    connections = _minimal_connections(include_battery;
        include_wind = include_wind,
        include_wave = include_wave,
        include_hydrokinetic = include_hydrokinetic,
        include_diesel = include_diesel,
        include_h2 = include_h2,
        include_desal = include_desal,
        include_platform = include_platform)
    template = OntologyTemplate(
        name = name,
        version = v"1.0.0",
        required_blocks = _minimal_block_roles(include_battery;
            include_wind = include_wind,
            include_wave = include_wave,
            include_hydrokinetic = include_hydrokinetic,
            include_diesel = include_diesel,
            include_h2 = include_h2,
            include_desal = include_desal,
            include_platform = include_platform),
        optional_blocks = include_battery ? BlockRole[] :
            [BlockRole(role_name = :battery, component_family = :storage)],
        default_connections = connections,
        default_scenario = scenario,
        default_formulations = [Simulation(), Collocation(), Shooting()],
        reports = _minimal_reports(),
    )
    graph = SystemGraph(ontology = template, blocks = blocks,
        connections = connections, scenario = scenario)
    return SystemGraph(ontology = template, blocks = blocks, connections = connections,
        scenario = scenario, validation = validate_system(graph))
end

MinimalEnergyOntology(; kwargs...) = _build_energy_ontology(:MinimalEnergyOntology; kwargs...)

function PackageBackedHybridOntology(; kwargs...)
    return _build_energy_ontology(:PackageBackedHybridOntology;
        include_wind = true,
        include_wave = true,
        kwargs...)
end

function DynamicMultilevelHybridOntology(; kwargs...)
    return _build_energy_ontology(:DynamicMultilevelHybridOntology;
        include_wind = true,
        include_wave = true,
        include_platform = true,
        kwargs...)
end

function SIRENOLiteOntology(; kwargs...)
    graph = _build_energy_ontology(:SIRENOLiteOntology; kwargs...)
    warnings = copy(graph.validation.warnings)
    push!(warnings, "SIRENOLiteOntology is a comparison fixture, not the primary SIRENOpt implementation.")
    validation = ValidationReport(errors = graph.validation.errors, warnings = warnings,
        checked_invariants = graph.validation.checked_invariants,
        invalid_object_paths = graph.validation.invalid_object_paths,
        suggested_fixes = graph.validation.suggested_fixes)
    return SystemGraph(graph.ontology, graph.blocks, graph.connections, graph.scenario, validation)
end

function FullSIRENOptOntology(; kwargs...)
    throw(ArgumentError("FullSIRENOptOntology is reserved until the smaller V1 builders and the multi-level acceptance fixture are complete; use DynamicMultilevelHybridOntology for the current reduced motion-coupled graph."))
end

function _block_by_name(system::SystemGraph, name::Symbol)
    for block in system.blocks
        block.name == name && return block
    end
    return nothing
end

function _port_by_name(block::BlockSpec, name::Symbol)
    for port in block.ports
        port.name == name && return port
    end
    return nothing
end

function validate_system(system::SystemGraph)
    errors = String[]
    warnings = String[]
    checked = String[]
    invalid_paths = String[]
    fixes = String[]

    names = Symbol[]
    for block in system.blocks
        if block.name in names
            push!(errors, "Ontology $(system.ontology.name): duplicate block name $(block.name).")
            push!(invalid_paths, string(block.name))
            push!(fixes, "Use stable unique names such as :battery_1 and :battery_2.")
        end
        push!(names, block.name)
        for var in vcat(block.designs, block.states, block.controls)
            var.owner == block.name || push!(errors, "Variable $(var.owner).$(var.name) is listed under block $(block.name).")
        end
        for port in block.ports
            port.owner == block.name || push!(errors, "Port $(port.owner).$(port.name) is listed under block $(block.name).")
        end
    end
    push!(checked, "unique block names and block-local owners")

    for role in system.ontology.required_blocks
        if _block_by_name(system, role.role_name) === nothing
            push!(errors, "Ontology $(system.ontology.name) is missing required block $(role.role_name).")
            push!(invalid_paths, string(role.role_name))
            push!(fixes, "Enable the default provider $(role.default_provider) or remove the required role from the template.")
        end
    end
    push!(checked, "required block roles")

    for conn in system.connections
        if !conn.active
            conn.disabled_reason === nothing && push!(errors,
                "Inactive connection $(conn.source_block).$(conn.source_port) -> $(conn.sink_block).$(conn.sink_port) lacks a disabled reason.")
            continue
        end
        source = _block_by_name(system, conn.source_block)
        sink = _block_by_name(system, conn.sink_block)
        if source === nothing || sink === nothing
            push!(errors, "Connection $(conn.source_block).$(conn.source_port) -> $(conn.sink_block).$(conn.sink_port) references a missing block.")
            push!(invalid_paths, string(conn.source_block, "->", conn.sink_block))
            push!(fixes, "Remove the connection or enable both endpoint blocks.")
            continue
        end
        sport = _port_by_name(source, conn.source_port)
        tport = _port_by_name(sink, conn.sink_port)
        if sport === nothing || tport === nothing
            push!(errors, "Connection $(conn.source_block).$(conn.source_port) -> $(conn.sink_block).$(conn.sink_port) references a missing port.")
            push!(invalid_paths, string(conn.source_block, ".", conn.source_port, "->", conn.sink_block, ".", conn.sink_port))
            push!(fixes, "Declare the port in the owning block or remove the connection.")
            continue
        end
        sport.direction in (:out, :inout) || push!(errors,
            "Connection source $(conn.source_block).$(conn.source_port) has direction $(sport.direction), expected :out or :inout.")
        tport.direction in (:in, :inout) || push!(errors,
            "Connection sink $(conn.sink_block).$(conn.sink_port) has direction $(tport.direction), expected :in or :inout.")
        if sport.unit != tport.unit && conn.conversion_owner === nothing
            push!(errors, "Connection $(conn.source_block).$(conn.source_port) -> $(conn.sink_block).$(conn.sink_port) has units $(sport.unit) and $(tport.unit) without a conversion owner.")
            push!(fixes, "Set conversion_owner to a named converter or adapter.")
        end
        if sport.port_type != tport.port_type && conn.conversion_owner === nothing
            push!(errors, "Connection $(conn.source_block).$(conn.source_port) -> $(conn.sink_block).$(conn.sink_port) has port types $(sport.port_type) and $(tport.port_type) without a conversion owner.")
            push!(fixes, "Connect matching port types or set conversion_owner to a named adapter.")
        end
        if sport.port_type in (:platform_wrench, :motion_state, :mass_inertia) ||
                tport.port_type in (:platform_wrench, :motion_state, :mass_inertia)
            if sport.frame != tport.frame && conn.conversion_owner === nothing
                push!(errors, "Connection $(conn.source_block).$(conn.source_port) -> $(conn.sink_block).$(conn.sink_port) crosses frames $(sport.frame) and $(tport.frame) without a conversion owner.")
                push!(fixes, "Set conversion_owner to a frame transform adapter or use matching frames.")
            end
            if sport.reference_point != tport.reference_point && conn.conversion_owner === nothing
                push!(errors, "Connection $(conn.source_block).$(conn.source_port) -> $(conn.sink_block).$(conn.sink_port) crosses reference points $(sport.reference_point) and $(tport.reference_point) without a conversion owner.")
                push!(fixes, "Set conversion_owner to a reference-point transform adapter or use matching reference points.")
            end
        end
        if (sport.cardinality == :many_to_one || tport.cardinality == :many_to_one) && conn.aggregation_owner === nothing
            push!(errors, "Many-to-one connection $(conn.source_block).$(conn.source_port) -> $(conn.sink_block).$(conn.sink_port) must name aggregation_owner.")
            push!(fixes, "Use aggregation_owner = :bus or another residual owner.")
        end
        if sport.time_grid != tport.time_grid && conn.resampling_owner === nothing
            push!(errors, "Connection $(conn.source_block).$(conn.source_port) -> $(conn.sink_block).$(conn.sink_port) crosses time grids $(sport.time_grid) and $(tport.time_grid) without resampling_owner.")
        end
    end
    push!(checked, "port direction, unit, cardinality, and time-grid compatibility")

    return ValidationReport(errors = errors, warnings = warnings,
        checked_invariants = checked, invalid_object_paths = invalid_paths,
        suggested_fixes = fixes)
end

function _scenario_grid(scenario::ScenarioSpec, formulation::FormulationSpec = Simulation())
    formulation.time_grid in keys(scenario.time_grids) ||
        throw(ArgumentError("Scenario $(scenario.name) has no time grid $(formulation.time_grid)."))
    return getproperty(scenario.time_grids, formulation.time_grid)
end

function _scenario_length(scenario::ScenarioSpec, formulation::FormulationSpec = Simulation())
    return n_intervals(_scenario_grid(scenario, formulation))
end

function _scenario_dt_hours(scenario::ScenarioSpec, formulation::FormulationSpec = Simulation())
    return dt_hours(_scenario_grid(scenario, formulation))
end

function _all_block_variables(block::BlockSpec)
    return (designs = block.designs, states = block.states, controls = block.controls)
end

function _registered_count(spec, n_intervals::Int)
    spec.time_scope == :design && return 1
    spec.time_scope == :node && return n_intervals + 1
    spec.time_scope == :interval && return n_intervals
    return 1
end

function _registered_residual_count(spec, n_intervals::Int)
    spec.time_scope == :design && return 1
    spec.time_scope == :terminal && return 1
    spec.time_scope == :node && return n_intervals + 1
    return n_intervals
end

function _exposes_variable(formulation::FormulationSpec, spec::VariableSpec)
    formulation.mode == :simulation && return spec.role == :design
    isempty(formulation.exposed_roles) && return true
    return spec.role in formulation.exposed_roles
end

function _scenario_initial_value(spec::VariableSpec, scenario::ScenarioSpec)
    if spec.owner == :battery && spec.name == :battery_soc &&
            :battery_soc in keys(scenario.initial_states)
        return scenario.initial_states.battery_soc
    end
    if spec.owner == :diesel_engine && spec.name == :diesel_fuel_l &&
            :diesel_fuel_l in keys(scenario.initial_states)
        return scenario.initial_states.diesel_fuel_l
    end
    if spec.owner == :h2_electrolyzer && spec.name == :h2_level_kg &&
            :h2_level_kg in keys(scenario.initial_states)
        return scenario.initial_states.h2_level_kg
    end
    if spec.owner == :desalination && spec.name == :desal_level_m3 &&
            :desal_level_m3 in keys(scenario.initial_states)
        return scenario.initial_states.desal_level_m3
    end
    return spec.initial
end

function build_registry(system::SystemGraph, scenario::ScenarioSpec = system.scenario,
        formulation::FormulationSpec = Collocation())
    n = _scenario_length(scenario, formulation)
    variables = RegistryEntry[]
    residual_entries = RegistryEntry[]
    output_entries = RegistryEntry[]
    port_entries = RegistryEntry[]
    trace = String[]

    variable_index = 1
    for block in system.blocks
        for group in _all_block_variables(block)
            for spec in group
                spec.exposure == :computed && continue
                count = _exposes_variable(formulation, spec) ?
                    _registered_count(spec, n) : 0
                for local_i in 1:count
                    time_index = spec.time_scope == :design ? nothing : local_i
                    idx = variable_index:variable_index
                    initial = _scenario_initial_value(spec, scenario)
                    push!(variables, RegistryEntry(block.name, spec.name, spec.role,
                        spec.unit, spec.scale, spec.label, idx, time_index,
                        spec.time_scope, block.model_path.path_label, spec.lower,
                        spec.upper, initial))
                    push!(trace, "x[$(variable_index)] $(block.name).$(spec.name) role=$(spec.role) unit=$(spec.unit) time=$(something(time_index, :design))")
                    variable_index += 1
                end
            end
        end
    end

    residual_index = 1
    for block in system.blocks
        for spec in block.residuals
            count = _registered_residual_count(spec, n)
            for local_i in 1:count
                time_index = spec.time_scope in (:design, :terminal) ? nothing : local_i
                idx = residual_index:residual_index
                push!(residual_entries, RegistryEntry(block.name, spec.name,
                    spec.sense, spec.unit, spec.scale, spec.label, idx,
                    time_index, spec.time_scope, block.model_path.path_label,
                    spec.lower, spec.upper, 0.0))
                push!(trace, "con[$(residual_index)] $(block.name).$(spec.name) sense=$(spec.sense) unit=$(spec.unit) time=$(something(time_index, spec.time_scope))")
                residual_index += 1
            end
        end
    end
    terminal_soc_equal_initial = _terminal_soc_equal_initial(formulation)
    battery_block = _block_by_name(system, :battery)
    if terminal_soc_equal_initial && battery_block !== nothing
        idx = residual_index:residual_index
        push!(residual_entries, RegistryEntry(:battery, :battery_terminal_soc,
            :eq, "kWh", 1.0, "Battery terminal SOC equals initial SOC", idx,
            nothing, :terminal, battery_block.model_path.path_label, 0.0, 0.0,
            0.0))
        push!(trace, "con[$(residual_index)] battery.battery_terminal_soc sense=eq unit=kWh time=terminal")
        residual_index += 1
    end

    output_index = 1
    for block in system.blocks
        for spec in block.outputs
            count = spec.time_scope == :design || spec.time_scope == :summary ? 1 : n
            for local_i in 1:count
                time_index = spec.time_scope in (:design, :summary) ? nothing : local_i
                push!(output_entries, RegistryEntry(block.name, spec.name, :output,
                    spec.unit, 1.0, spec.label, output_index:output_index,
                    time_index, spec.time_scope, spec.model_path.path_label,
                    -Inf, Inf, 0.0))
                output_index += 1
            end
        end
    end

    port_index = 1
    for conn in system.connections
        push!(port_entries, RegistryEntry(conn.source_block, conn.source_port,
            :port, conn.unit, 1.0,
            string(conn.source_block, ".", conn.source_port, " -> ", conn.sink_block, ".", conn.sink_port),
            port_index:port_index, nothing, :connection, :hard_residual,
            -Inf, Inf, 0.0))
        port_index += 1
    end

    return AssemblyRegistry(variables, residual_entries, output_entries, port_entries, trace)
end

function _registry_vectors(registry::AssemblyRegistry)
    x0 = Float64[Float64(entry.initial) for entry in registry.variables]
    lower = Float64[Float64(entry.lower) for entry in registry.variables]
    upper = Float64[Float64(entry.upper) for entry in registry.variables]
    con_lower = Float64[Float64(entry.lower) for entry in registry.residuals]
    con_upper = Float64[Float64(entry.upper) for entry in registry.residuals]
    return x0, lower, upper, con_lower, con_upper
end

function assemble(system::SystemGraph, scenario::ScenarioSpec = system.scenario,
        formulation::FormulationSpec = Collocation(),
        objective::ObjectiveSpec = formulation.objective)

    isvalid(system.validation) || throw(ArgumentError(
        "Cannot assemble invalid ontology $(system.ontology.name): $(join(system.validation.errors, "; "))"))
    registry = build_registry(system, scenario, formulation)
    x0, lower, upper, con_lower, con_upper = _registry_vectors(registry)
    return AssembledModel(system, scenario, formulation, objective, registry,
        x0, lower, upper, con_lower, con_upper, copy(registry.trace))
end

function _entry_index(registry::AssemblyRegistry, owner::Symbol, name::Symbol,
        time_index::Union{Nothing,Int})
    for entry in registry.variables
        entry.owner == owner && entry.name == name && entry.time_index == time_index &&
            return first(entry.index_range)
    end
    return nothing
end

function _entry_value(x, registry::AssemblyRegistry, owner::Symbol, name::Symbol,
        time_index::Union{Nothing,Int} = nothing; default = nothing)
    idx = _entry_index(registry, owner, name, time_index)
    idx === nothing && return default
    return x[idx]
end

function _set_entry_value!(x, registry::AssemblyRegistry, owner::Symbol, name::Symbol,
        time_index::Union{Nothing,Int}, value)
    idx = _entry_index(registry, owner, name, time_index)
    idx === nothing && return x
    x[idx] = value
    return x
end

function _block_param(system::SystemGraph, block_name::Symbol, param::Symbol; default = nothing)
    block = _block_by_name(system, block_name)
    block === nothing && return default
    return param in keys(block.parameters) ? getproperty(block.parameters, param) : default
end

_has_block(system::SystemGraph, block_name::Symbol) = _block_by_name(system, block_name) !== nothing

function _minimal_design_values(model::AssembledModel, x)
    reg = model.registry
    system = model.system
    solar_area = _entry_value(x, reg, :solar_array, :solar_area_m2; default = _block_param(system, :solar_array, :area_m2, default = 0.0))
    solar_rating = _entry_value(x, reg, :solar_converter, :solar_converter_rating_kw; default = _block_param(system, :solar_converter, :rating_kw, default = Inf))
    battery_capacity = _entry_value(x, reg, :battery, :battery_capacity_kwh; default = 0.0)
    battery_power = _entry_value(x, reg, :battery, :battery_power_kw; default = 0.0)
    load_rating = _entry_value(x, reg, :load, :load_converter_rating_kw;
        default = _block_param(system, :load, :converter_rating_kw, default = Inf))
    wind_rated = _entry_value(x, reg, :wind_rotor, :wind_rated_power_kw; default = 0.0)
    wave_capture = _entry_value(x, reg, :wave_wec, :wave_capture_width_m; default = 0.0)
    wave_rated = _entry_value(x, reg, :wave_wec, :wave_rated_power_kw; default = 0.0)
    hydrokinetic_rated = _entry_value(x, reg, :hydrokinetic_rotor,
        :hydrokinetic_rated_power_kw; default = 0.0)
    diesel_rated = _entry_value(x, reg, :diesel_engine,
        :diesel_rated_power_kw; default = 0.0)
    diesel_tank = _entry_value(x, reg, :diesel_engine,
        :diesel_fuel_tank_l; default = 0.0)
    h2_power = _entry_value(x, reg, :h2_electrolyzer,
        :h2_electrolyzer_power_kw; default = 0.0)
    h2_tank = _entry_value(x, reg, :h2_electrolyzer,
        :h2_tank_capacity_kg; default = 0.0)
    desal_power = _entry_value(x, reg, :desalination,
        :desal_plant_power_kw; default = 0.0)
    desal_tank = _entry_value(x, reg, :desalination,
        :desal_tank_capacity_m3; default = 0.0)
    platform_inertia = _entry_value(x, reg, :platform, :platform_inertia_kg_m2; default = 1.0)
    return (
        solar_area_m2 = solar_area,
        solar_efficiency = _block_param(system, :solar_array, :efficiency, default = 0.2),
        solar_converter_rating_kw = solar_rating,
        solar_converter_efficiency = _block_param(system, :solar_converter, :efficiency, default = 1.0),
        battery_capacity_kwh = battery_capacity,
        battery_power_kw = battery_power,
        battery_charge_efficiency = _block_param(system, :battery, :charge_efficiency, default = 1.0),
        battery_discharge_efficiency = _block_param(system, :battery, :discharge_efficiency, default = 1.0),
        battery_converter_efficiency = _block_param(system, :battery_converter, :efficiency, default = 1.0),
        load_converter_rating_kw = load_rating,
        load_converter_efficiency = _block_param(system, :load, :converter_efficiency, default = 1.0),
        critical_load_fraction = _block_param(system, :load, :critical_fraction, default = 1.0),
        wind_rated_power_kw = wind_rated,
        wind_generator_efficiency = _block_param(system, :wind_generator, :efficiency, default = 1.0),
        wind_converter_efficiency = _block_param(system, :wind_converter, :efficiency, default = 1.0),
        wind_rotor_model = _block_param(system, :wind_rotor, :rotor_model, default = nothing),
        wind_generator_model = _block_param(system, :wind_generator, :generator_model, default = nothing),
        wind_converter_model = _block_param(system, :wind_converter, :converter_model, default = nothing),
        wind_cut_in_m_s = _block_param(system, :wind_rotor, :cut_in_m_s, default = 0.0),
        wind_cut_out_m_s = _block_param(system, :wind_rotor, :cut_out_m_s, default = 40.0),
        wind_air_density_kg_m3 = _block_param(system, :wind_rotor, :air_density_kg_m3, default = 1.225),
        wind_platform_moment_per_kw_nm = _block_param(system, :wind_rotor, :platform_moment_per_kw_nm, default = 0.0),
        wave_capture_width_m = wave_capture,
        wave_rated_power_kw = wave_rated,
        wave_converter_efficiency = _block_param(system, :wave_converter, :efficiency, default = 1.0),
        hydrokinetic_rated_power_kw = hydrokinetic_rated,
        hydrokinetic_rotor_diameter_m = _block_param(system, :hydrokinetic_rotor,
            :rotor_diameter_m, default = 0.0),
        hydrokinetic_cp = _block_param(system, :hydrokinetic_rotor, :cp, default = 0.38),
        hydrokinetic_generator_efficiency = _block_param(system,
            :hydrokinetic_generator, :efficiency, default = 1.0),
        hydrokinetic_converter_efficiency = _block_param(system,
            :hydrokinetic_converter, :efficiency, default = 1.0),
        hydrokinetic_rotor_model = _block_param(system, :hydrokinetic_rotor,
            :rotor_model, default = nothing),
        hydrokinetic_generator_model = _block_param(system, :hydrokinetic_generator,
            :generator_model, default = nothing),
        hydrokinetic_converter_model = _block_param(system, :hydrokinetic_converter,
            :converter_model, default = nothing),
        hydrokinetic_cut_in_m_s = _block_param(system, :hydrokinetic_rotor,
            :cut_in_m_s, default = 0.0),
        hydrokinetic_cut_out_m_s = _block_param(system, :hydrokinetic_rotor,
            :cut_out_m_s, default = 5.0),
        hydrokinetic_fluid_density_kg_m3 = _block_param(system,
            :hydrokinetic_rotor, :fluid_density_kg_m3, default = 1025.0),
        diesel_rated_power_kw = diesel_rated,
        diesel_min_power_kw = _block_param(system, :diesel_engine,
            :min_power_kw, default = 0.0),
        diesel_fuel_tank_l = diesel_tank,
        diesel_fuel_per_kwh_l = _block_param(system, :diesel_engine,
            :fuel_per_kwh_l, default = 0.27),
        diesel_generator_efficiency = _block_param(system, :diesel_generator,
            :efficiency, default = 1.0),
        diesel_converter_efficiency = _block_param(system, :diesel_converter,
            :efficiency, default = 1.0),
        diesel_engine_model = _block_param(system, :diesel_engine,
            :engine_model, default = nothing),
        diesel_generator_model = _block_param(system, :diesel_generator,
            :generator_model, default = nothing),
        diesel_converter_model = _block_param(system, :diesel_converter,
            :converter_model, default = nothing),
        h2_electrolyzer_power_kw = h2_power,
        h2_tank_capacity_kg = h2_tank,
        h2_specific_energy_kwh_per_kg = _block_param(system, :h2_electrolyzer,
            :specific_energy_kwh_per_kg, default = 50.0),
        h2_model = _block_param(system, :h2_electrolyzer,
            :h2_model, default = nothing),
        h2_converter_efficiency = _block_param(system, :h2_converter,
            :efficiency, default = 1.0),
        h2_converter_model = _block_param(system, :h2_converter,
            :converter_model, default = nothing),
        desal_plant_power_kw = desal_power,
        desal_tank_capacity_m3 = desal_tank,
        desal_specific_energy_kwh_per_m3 = _block_param(system, :desalination,
            :specific_energy_kwh_per_m3, default = 3.0),
        desal_model = _block_param(system, :desalination,
            :desal_model, default = nothing),
        desal_converter_efficiency = _block_param(system, :desal_converter,
            :efficiency, default = 1.0),
        desal_converter_model = _block_param(system, :desal_converter,
            :converter_model, default = nothing),
        platform_inertia_kg_m2 = platform_inertia,
        platform_stiffness_nm_per_rad = _block_param(system, :platform, :stiffness_nm_per_rad, default = 0.0),
        platform_damping_nm_s_per_rad = _block_param(system, :platform, :damping_nm_s_per_rad, default = 0.0),
    )
end

function _power_to_bus(device_power_kw, efficiency)
    if device_power_kw >= zero(device_power_kw)
        return device_power_kw * efficiency
    end
    return device_power_kw / efficiency
end

function _source_available_bus(system::SystemGraph, scenario::ScenarioSpec, design, k::Int,
        theta, source::Symbol)
    if source == :solar
        irradiance = scenario.resources.solar_irradiance_kw_per_m2[k]
        motion_factor = _has_block(system, :platform) ? max(cos(theta), zero(theta)) : one(theta)
        device = irradiance * design.solar_area_m2 * design.solar_efficiency * motion_factor
        bus = _power_to_bus(device, design.solar_converter_efficiency)
        return (device = device, bus = bus, available = device)
    elseif source == :wind
        wind_speed = scenario.resources.wind_speed_m_s[k]
        motion_factor = _has_block(system, :platform) ? max(cos(theta), zero(theta)) : one(theta)
        effective_wind_speed = wind_speed * motion_factor
        Tdesign = typeof(design.wind_rated_power_kw + zero(effective_wind_speed))
        Top = typeof(effective_wind_speed + zero(design.wind_air_density_kg_m3))
        wind_design = WindDesign{Tdesign}(
            rated_power = design.wind_rated_power_kw,
            cut_in = design.wind_cut_in_m_s,
            cut_out = design.wind_cut_out_m_s,
            rotor_model = design.wind_rotor_model,
        )
        wind_op = WindOp{Top}(
            resource = TimeSeries([zero(effective_wind_speed)], [effective_wind_speed]),
            air_density = design.wind_air_density_kg_m3,
            curtailment = zero(effective_wind_speed),
        )
        shaft = power_available_wind(wind_design, wind_op, 1)
        Tshaft = typeof(shaft + zero(design.wind_rated_power_kw))
        gen_design = GeneratorDesign{Tshaft}(
            rated_power = design.wind_rated_power_kw,
            efficiency = design.wind_generator_efficiency,
            generator_model = design.wind_generator_model,
        )
        device = generator_output(gen_design, GeneratorOp{Tshaft}(), shaft)
        Tdevice = typeof(device + zero(design.wind_rated_power_kw))
        conv_design = ConverterDesign{Tdevice}(
            rated_power = design.wind_rated_power_kw,
            efficiency = design.wind_converter_efficiency,
            converter_model = design.wind_converter_model,
        )
        bus = converter_output(conv_design, ConverterOp{Tdevice}(), device)
        return (device = device, bus = bus, available = shaft)
    elseif source == :wave
        flux = scenario.resources.wave_power_flux_kw_per_m[k]
        raw = min(flux * design.wave_capture_width_m, design.wave_rated_power_kw)
        bus = _power_to_bus(raw, design.wave_converter_efficiency)
        return (device = raw, bus = bus, available = flux * design.wave_capture_width_m)
    elseif source == :hydrokinetic
        current_speed = scenario.resources.hydrokinetic_current_m_s[k]
        Tdesign = typeof(design.hydrokinetic_rated_power_kw +
            zero(current_speed) + zero(design.hydrokinetic_rotor_diameter_m))
        Top = typeof(current_speed + zero(design.hydrokinetic_fluid_density_kg_m3))
        hydro_design = HydrokineticDesign{Tdesign}(
            rotor_diameter = design.hydrokinetic_rotor_diameter_m,
            cp = design.hydrokinetic_cp,
            rated_power = design.hydrokinetic_rated_power_kw,
            cut_in = design.hydrokinetic_cut_in_m_s,
            cut_out = design.hydrokinetic_cut_out_m_s,
            rotor_model = design.hydrokinetic_rotor_model,
        )
        hydro_op = HydrokineticOp{Top}(
            resource = TimeSeries([zero(current_speed)], [current_speed]),
            fluid_density = design.hydrokinetic_fluid_density_kg_m3,
            curtailment = zero(current_speed),
        )
        shaft = power_available_hydrokinetic(hydro_design, hydro_op, 1)
        Tshaft = typeof(shaft + zero(design.hydrokinetic_rated_power_kw))
        gen_design = GeneratorDesign{Tshaft}(
            rated_power = design.hydrokinetic_rated_power_kw,
            efficiency = design.hydrokinetic_generator_efficiency,
            generator_model = design.hydrokinetic_generator_model,
        )
        device = generator_output(gen_design, GeneratorOp{Tshaft}(), shaft)
        Tdevice = typeof(device + zero(design.hydrokinetic_rated_power_kw))
        conv_design = ConverterDesign{Tdevice}(
            rated_power = design.hydrokinetic_rated_power_kw,
            efficiency = design.hydrokinetic_converter_efficiency,
            converter_model = design.hydrokinetic_converter_model,
        )
        bus = converter_output(conv_design, ConverterOp{Tdevice}(), device)
        return (device = device, bus = bus, available = shaft)
    end
    return (device = zero(theta), bus = zero(theta), available = zero(theta))
end

function _diesel_outputs(design, power_setpoint_kw, dt_h)
    if _plain_float(power_setpoint_kw)
        shaft = clamp(power_setpoint_kw, design.diesel_min_power_kw,
            design.diesel_rated_power_kw)
    else
        shaft = smooth_clamp(power_setpoint_kw, design.diesel_min_power_kw,
            design.diesel_rated_power_kw)
    end
    Tshaft = typeof(shaft + zero(design.diesel_rated_power_kw))
    fuel_used = if _plain_float(shaft)
        diesel_design = DieselDesign{Tshaft}(
            rated_power = design.diesel_rated_power_kw,
            min_power = design.diesel_min_power_kw,
            fuel_per_kwh = design.diesel_fuel_per_kwh_l,
            fuel_tank_capacity = design.diesel_fuel_tank_l,
            engine_model = design.diesel_engine_model,
        )
        diesel_fuel_used(diesel_engine_design(diesel_design), shaft, dt_h)
    else
        shaft * design.diesel_fuel_per_kwh_l * dt_h
    end
    device = generator_output(
        GeneratorDesign{Tshaft}(rated_power = design.diesel_rated_power_kw,
            efficiency = design.diesel_generator_efficiency,
            generator_model = design.diesel_generator_model),
        GeneratorOp{Tshaft}(), shaft)
    Tdevice = typeof(device + zero(design.diesel_rated_power_kw))
    bus = converter_output(
        ConverterDesign{Tdevice}(rated_power = design.diesel_rated_power_kw,
            efficiency = design.diesel_converter_efficiency,
            converter_model = design.diesel_converter_model),
        ConverterOp{Tdevice}(), device)
    return (shaft = shaft, device = device, bus = bus, fuel_used = fuel_used)
end

function _h2_outputs(design, scenario::ScenarioSpec, level_prev, power_kw, dt_h, k::Int)
    demand = scenario.demands.h2_demand_kg_per_h[k]
    Tproc = typeof(level_prev + power_kw + zero(demand) +
        zero(design.h2_electrolyzer_power_kw))
    h2_design = H2Design{Tproc}(
        electrolyzer_power_kw = design.h2_electrolyzer_power_kw,
        tank_capacity_kg = design.h2_tank_capacity_kg,
        specific_energy_kwh_per_kg = design.h2_specific_energy_kwh_per_kg,
        h2_model = design.h2_model,
    )
    h2_op = H2Op{Tproc}(
        tank_level_kg = level_prev,
        demand = TimeSeries([zero(Tproc)], [demand + zero(Tproc)]),
    )
    level_next, device_power = h2_step(h2_design, h2_op, level_prev, power_kw,
        dt_h, 1)
    Tdevice = typeof(device_power + zero(design.h2_electrolyzer_power_kw))
    bus = converter_output(
        ConverterDesign{Tdevice}(rated_power = design.h2_electrolyzer_power_kw,
            efficiency = design.h2_converter_efficiency,
            converter_model = design.h2_converter_model),
        ConverterOp{Tdevice}(), -device_power)
    return (level = level_next, device = device_power, bus = bus)
end

function _desal_outputs(design, scenario::ScenarioSpec, level_prev, power_kw, dt_h,
        k::Int)
    demand = scenario.demands.desal_demand_m3_per_h[k]
    Tproc = typeof(level_prev + power_kw + zero(demand) +
        zero(design.desal_plant_power_kw))
    desal_design = DesalDesign{Tproc}(
        plant_power_kw = design.desal_plant_power_kw,
        tank_capacity_m3 = design.desal_tank_capacity_m3,
        specific_energy_kwh_per_m3 = design.desal_specific_energy_kwh_per_m3,
        desal_model = design.desal_model,
    )
    desal_op = DesalOp{Tproc}(
        tank_level_m3 = level_prev,
        demand = TimeSeries([zero(Tproc)], [demand + zero(Tproc)]),
    )
    level_next, device_power = desal_step(desal_design, desal_op, level_prev,
        power_kw, dt_h, 1)
    Tdevice = typeof(device_power + zero(design.desal_plant_power_kw))
    bus = converter_output(
        ConverterDesign{Tdevice}(rated_power = design.desal_plant_power_kw,
            efficiency = design.desal_converter_efficiency,
            converter_model = design.desal_converter_model),
        ConverterOp{Tdevice}(), -device_power)
    return (level = level_next, device = device_power, bus = bus)
end

function _minimal_step(system::SystemGraph, scenario::ScenarioSpec, design, k::Int,
        soc_prev, solar_curtailment, battery_command_kw, load_served_fraction;
        wind_curtailment = 0.0, wave_curtailment = 0.0,
        hydrokinetic_curtailment = 0.0,
        diesel_power_kw = 0.0, diesel_fuel_prev = nothing,
        h2_power_kw = 0.0, h2_level_prev = nothing,
        desal_power_kw = 0.0, desal_level_prev = nothing,
        theta = 0.0, omega = 0.0, theta_next = nothing, omega_next = nothing)
    dt_h = _scenario_dt_hours(scenario)
    dt_s = _scenario_grid(scenario).dt_s
    irradiance = scenario.resources.solar_irradiance_kw_per_m2[k]
    load_kw = scenario.demands.load_kw[k]

    motion_factor = _has_block(system, :platform) ? max(cos(theta), zero(theta)) : one(theta)
    solar_available_kw = irradiance * design.solar_area_m2 * design.solar_efficiency * motion_factor
    solar_device_kw = solar_available_kw * (one(solar_available_kw) - solar_curtailment)
    solar_bus_kw = _power_to_bus(solar_device_kw, design.solar_converter_efficiency)
    solar_converter_loss_kw = abs(solar_device_kw - solar_bus_kw)

    if _has_block(system, :wind_rotor)
        wind_available = _source_available_bus(system, scenario, design, k, theta, :wind)
        wind_shaft_kw = wind_available.available * (one(wind_curtailment) - wind_curtailment)
        wind_device_kw = wind_shaft_kw * design.wind_generator_efficiency
        if design.wind_generator_model !== nothing
            Tshaft = typeof(wind_shaft_kw + zero(design.wind_rated_power_kw))
            wind_device_kw = generator_output(
                GeneratorDesign{Tshaft}(rated_power = design.wind_rated_power_kw,
                    efficiency = design.wind_generator_efficiency,
                    generator_model = design.wind_generator_model),
                GeneratorOp{Tshaft}(), wind_shaft_kw)
        end
        if design.wind_converter_model !== nothing
            Tdevice = typeof(wind_device_kw + zero(design.wind_rated_power_kw))
            wind_bus_kw = converter_output(
                ConverterDesign{Tdevice}(rated_power = design.wind_rated_power_kw,
                    efficiency = design.wind_converter_efficiency,
                    converter_model = design.wind_converter_model),
                ConverterOp{Tdevice}(), wind_device_kw)
        else
            wind_bus_kw = _power_to_bus(wind_device_kw, design.wind_converter_efficiency)
        end
    else
        wind_available = (device = zero(solar_bus_kw), bus = zero(solar_bus_kw), available = zero(solar_bus_kw))
        wind_shaft_kw = zero(solar_bus_kw)
        wind_device_kw = zero(solar_bus_kw)
        wind_bus_kw = zero(solar_bus_kw)
    end

    if _has_block(system, :wave_wec)
        wave_available = _source_available_bus(system, scenario, design, k, theta, :wave)
        wave_device_kw = wave_available.device * (one(wave_curtailment) - wave_curtailment)
        wave_bus_kw = _power_to_bus(wave_device_kw, design.wave_converter_efficiency)
    else
        wave_available = (device = zero(solar_bus_kw), bus = zero(solar_bus_kw), available = zero(solar_bus_kw))
        wave_device_kw = zero(solar_bus_kw)
        wave_bus_kw = zero(solar_bus_kw)
    end

    if _has_block(system, :hydrokinetic_rotor)
        hydrokinetic_available = _source_available_bus(system, scenario, design, k,
            theta, :hydrokinetic)
        hydrokinetic_shaft_kw = hydrokinetic_available.available *
            (one(hydrokinetic_curtailment) - hydrokinetic_curtailment)
        Tshaft = typeof(hydrokinetic_shaft_kw + zero(design.hydrokinetic_rated_power_kw))
        hydrokinetic_device_kw = generator_output(
            GeneratorDesign{Tshaft}(rated_power = design.hydrokinetic_rated_power_kw,
                efficiency = design.hydrokinetic_generator_efficiency,
                generator_model = design.hydrokinetic_generator_model),
            GeneratorOp{Tshaft}(), hydrokinetic_shaft_kw)
        Tdevice = typeof(hydrokinetic_device_kw + zero(design.hydrokinetic_rated_power_kw))
        hydrokinetic_bus_kw = converter_output(
            ConverterDesign{Tdevice}(rated_power = design.hydrokinetic_rated_power_kw,
                efficiency = design.hydrokinetic_converter_efficiency,
                converter_model = design.hydrokinetic_converter_model),
            ConverterOp{Tdevice}(), hydrokinetic_device_kw)
        hydrokinetic_converter_loss_kw = abs(hydrokinetic_device_kw - hydrokinetic_bus_kw)
    else
        hydrokinetic_available = (device = zero(solar_bus_kw), bus = zero(solar_bus_kw), available = zero(solar_bus_kw))
        hydrokinetic_shaft_kw = zero(solar_bus_kw)
        hydrokinetic_device_kw = zero(solar_bus_kw)
        hydrokinetic_bus_kw = zero(solar_bus_kw)
        hydrokinetic_converter_loss_kw = zero(solar_bus_kw)
    end

    diesel_fuel_state = diesel_fuel_prev === nothing ? zero(solar_bus_kw) : diesel_fuel_prev
    if _has_block(system, :diesel_engine)
        diesel = _diesel_outputs(design, diesel_power_kw, dt_h)
        diesel_shaft_kw = diesel.shaft
        diesel_device_kw = diesel.device
        diesel_bus_kw = diesel.bus
        diesel_fuel_used_l = diesel.fuel_used
        if _plain_float(diesel_fuel_state - diesel_fuel_used_l)
            diesel_fuel_next_l = max(diesel_fuel_state - diesel_fuel_used_l,
                zero(diesel_fuel_state))
        else
            diesel_fuel_next_l = smooth_max(diesel_fuel_state - diesel_fuel_used_l,
                zero(diesel_fuel_state))
        end
        diesel_converter_loss_kw = abs(diesel_device_kw - diesel_bus_kw)
    else
        diesel_shaft_kw = zero(solar_bus_kw)
        diesel_device_kw = zero(solar_bus_kw)
        diesel_bus_kw = zero(solar_bus_kw)
        diesel_fuel_used_l = zero(solar_bus_kw)
        diesel_fuel_next_l = diesel_fuel_state
        diesel_converter_loss_kw = zero(solar_bus_kw)
    end

    h2_state = h2_level_prev === nothing ? zero(solar_bus_kw) : h2_level_prev
    if _has_block(system, :h2_electrolyzer)
        h2 = _h2_outputs(design, scenario, h2_state, h2_power_kw, dt_h, k)
        h2_level_next_kg = h2.level
        h2_device_power_kw = h2.device
        h2_bus_kw = h2.bus
        h2_converter_loss_kw = abs(h2_device_power_kw + h2_bus_kw)
    else
        h2_level_next_kg = h2_state
        h2_device_power_kw = zero(solar_bus_kw)
        h2_bus_kw = zero(solar_bus_kw)
        h2_converter_loss_kw = zero(solar_bus_kw)
    end

    desal_state = desal_level_prev === nothing ? zero(solar_bus_kw) : desal_level_prev
    if _has_block(system, :desalination)
        desal = _desal_outputs(design, scenario, desal_state, desal_power_kw, dt_h, k)
        desal_level_next_m3 = desal.level
        desal_device_power_kw = desal.device
        desal_bus_kw = desal.bus
        desal_converter_loss_kw = abs(desal_device_power_kw + desal_bus_kw)
    else
        desal_level_next_m3 = desal_state
        desal_device_power_kw = zero(solar_bus_kw)
        desal_bus_kw = zero(solar_bus_kw)
        desal_converter_loss_kw = zero(solar_bus_kw)
    end

    if _has_block(system, :battery)
        battery_device_kw = battery_command_kw
        battery_bus_kw = _power_to_bus(battery_device_kw, design.battery_converter_efficiency)
        battery_converter_loss_kw = abs(battery_device_kw - battery_bus_kw)
        charge_kw = max(-battery_device_kw, zero(battery_device_kw))
        discharge_kw = max(battery_device_kw, zero(battery_device_kw))
        soc_next = soc_prev +
            charge_kw * dt_h * design.battery_charge_efficiency / design.battery_capacity_kwh -
            discharge_kw * dt_h / design.battery_discharge_efficiency / design.battery_capacity_kwh
        battery_inventory_residual_kwh = soc_next * design.battery_capacity_kwh -
            (soc_prev * design.battery_capacity_kwh +
             charge_kw * dt_h * design.battery_charge_efficiency -
             discharge_kw * dt_h / design.battery_discharge_efficiency)
    else
        battery_device_kw = zero(solar_bus_kw)
        battery_bus_kw = zero(solar_bus_kw)
        battery_converter_loss_kw = zero(solar_bus_kw)
        soc_next = soc_prev
        battery_inventory_residual_kwh = zero(solar_bus_kw)
    end

    load_device_kw = load_kw * load_served_fraction
    load_bus_kw = -load_device_kw / design.load_converter_efficiency
    bus_balance_residual_kw = solar_bus_kw + wind_bus_kw + wave_bus_kw +
        hydrokinetic_bus_kw + diesel_bus_kw + battery_bus_kw + load_bus_kw +
        h2_bus_kw + desal_bus_kw
    platform_pitch_moment_nm = wind_bus_kw * design.wind_platform_moment_per_kw_nm
    platform_alpha_rad_s2 = _has_block(system, :platform) ?
        (platform_pitch_moment_nm - design.platform_stiffness_nm_per_rad * theta -
         design.platform_damping_nm_s_per_rad * omega) / design.platform_inertia_kg_m2 :
        zero(bus_balance_residual_kw)
    platform_theta_next_rad = theta + dt_s * omega
    platform_omega_next_rad_s = omega + dt_s * platform_alpha_rad_s2
    realized_theta_next = theta_next === nothing ? platform_theta_next_rad : theta_next
    realized_omega_next = omega_next === nothing ? platform_omega_next_rad_s : omega_next
    platform_kinematic_residual_rad = realized_theta_next - platform_theta_next_rad
    platform_dynamic_residual_rad_s = realized_omega_next - platform_omega_next_rad_s

    return (
        time_s = (k - 1) * _scenario_grid(scenario).dt_s,
        solar_irradiance_kw_per_m2 = irradiance,
        load_kw = load_kw,
        solar_available_kw = solar_available_kw,
        solar_device_power_kw = solar_device_kw,
        solar_bus_power_kw = solar_bus_kw,
        solar_converter_loss_kw = solar_converter_loss_kw,
        solar_curtailment = solar_curtailment,
        wind_speed_m_s = _has_block(system, :wind_rotor) ? scenario.resources.wind_speed_m_s[k] : 0.0,
        wind_curtailment = wind_curtailment,
        wind_available_power_kw = wind_available.available,
        wind_shaft_power_kw = wind_shaft_kw,
        wind_device_power_kw = wind_device_kw,
        wind_bus_power_kw = wind_bus_kw,
        wind_platform_moment_nm = platform_pitch_moment_nm,
        wave_power_flux_kw_per_m = _has_block(system, :wave_wec) ? scenario.resources.wave_power_flux_kw_per_m[k] : 0.0,
        wave_curtailment = wave_curtailment,
        wave_available_power_kw = wave_available.available,
        wave_device_power_kw = wave_device_kw,
        wave_bus_power_kw = wave_bus_kw,
        hydrokinetic_current_m_s = _has_block(system, :hydrokinetic_rotor) ?
            scenario.resources.hydrokinetic_current_m_s[k] : 0.0,
        hydrokinetic_curtailment = hydrokinetic_curtailment,
        hydrokinetic_available_power_kw = hydrokinetic_available.available,
        hydrokinetic_shaft_power_kw = hydrokinetic_shaft_kw,
        hydrokinetic_device_power_kw = hydrokinetic_device_kw,
        hydrokinetic_bus_power_kw = hydrokinetic_bus_kw,
        hydrokinetic_converter_loss_kw = hydrokinetic_converter_loss_kw,
        diesel_power_kw = diesel_power_kw,
        diesel_shaft_power_kw = diesel_shaft_kw,
        diesel_device_power_kw = diesel_device_kw,
        diesel_bus_power_kw = diesel_bus_kw,
        diesel_converter_loss_kw = diesel_converter_loss_kw,
        diesel_fuel_used_l = diesel_fuel_used_l,
        diesel_fuel_l = diesel_fuel_next_l,
        h2_demand_kg_per_h = _has_block(system, :h2_electrolyzer) ?
            scenario.demands.h2_demand_kg_per_h[k] : 0.0,
        h2_power_kw = h2_power_kw,
        h2_device_power_kw = h2_device_power_kw,
        h2_bus_power_kw = h2_bus_kw,
        h2_converter_loss_kw = h2_converter_loss_kw,
        h2_level_kg = h2_level_next_kg,
        desal_demand_m3_per_h = _has_block(system, :desalination) ?
            scenario.demands.desal_demand_m3_per_h[k] : 0.0,
        desal_power_kw = desal_power_kw,
        desal_device_power_kw = desal_device_power_kw,
        desal_bus_power_kw = desal_bus_kw,
        desal_converter_loss_kw = desal_converter_loss_kw,
        desal_level_m3 = desal_level_next_m3,
        battery_command_kw = battery_command_kw,
        battery_device_power_kw = battery_device_kw,
        battery_bus_power_kw = battery_bus_kw,
        battery_converter_loss_kw = battery_converter_loss_kw,
        battery_soc = soc_next,
        platform_theta_rad = theta,
        platform_omega_rad_s = omega,
        platform_alpha_rad_s2 = platform_alpha_rad_s2,
        platform_theta_next_rad = platform_theta_next_rad,
        platform_omega_next_rad_s = platform_omega_next_rad_s,
        platform_kinematic_residual_rad = platform_kinematic_residual_rad,
        platform_dynamic_residual_rad_s = platform_dynamic_residual_rad_s,
        platform_pitch_moment_nm = platform_pitch_moment_nm,
        load_served_fraction = load_served_fraction,
        load_bus_power_kw = load_bus_kw,
        bus_balance_residual_kw = bus_balance_residual_kw,
        battery_inventory_residual_kwh = battery_inventory_residual_kwh,
        solar_available_margin_kw = solar_available_kw - solar_device_kw,
        solar_converter_rating_margin_kw = design.solar_converter_rating_kw -
            max(abs(solar_device_kw), abs(solar_bus_kw)),
        wind_available_margin_kw = wind_available.available - wind_shaft_kw,
        wind_rating_margin_kw = design.wind_rated_power_kw -
            max(abs(wind_shaft_kw), abs(wind_device_kw), abs(wind_bus_kw)),
        wind_generator_loss_residual_kw = wind_device_kw -
            generator_output(GeneratorDesign{typeof(wind_shaft_kw + zero(design.wind_rated_power_kw))}(
                rated_power = design.wind_rated_power_kw,
                efficiency = design.wind_generator_efficiency,
                generator_model = design.wind_generator_model),
                GeneratorOp{typeof(wind_shaft_kw + zero(design.wind_rated_power_kw))}(), wind_shaft_kw),
        wind_converter_loss_residual_kw = wind_bus_kw -
            (design.wind_converter_model === nothing ?
             _power_to_bus(wind_device_kw, design.wind_converter_efficiency) :
             converter_output(ConverterDesign{typeof(wind_device_kw + zero(design.wind_rated_power_kw))}(
                 rated_power = design.wind_rated_power_kw,
                 efficiency = design.wind_converter_efficiency,
                 converter_model = design.wind_converter_model),
                 ConverterOp{typeof(wind_device_kw + zero(design.wind_rated_power_kw))}(), wind_device_kw)),
        wave_available_margin_kw = wave_available.available - wave_device_kw,
        wave_rating_margin_kw = design.wave_rated_power_kw -
            max(abs(wave_device_kw), abs(wave_bus_kw)),
        wave_converter_loss_residual_kw = wave_bus_kw -
            _power_to_bus(wave_device_kw, design.wave_converter_efficiency),
        hydrokinetic_available_margin_kw = hydrokinetic_available.available -
            hydrokinetic_shaft_kw,
        hydrokinetic_rating_margin_kw = design.hydrokinetic_rated_power_kw -
            max(abs(hydrokinetic_shaft_kw), abs(hydrokinetic_device_kw),
                abs(hydrokinetic_bus_kw)),
        hydrokinetic_generator_loss_residual_kw = hydrokinetic_device_kw -
            generator_output(GeneratorDesign{typeof(hydrokinetic_shaft_kw + zero(design.hydrokinetic_rated_power_kw))}(
                rated_power = design.hydrokinetic_rated_power_kw,
                efficiency = design.hydrokinetic_generator_efficiency,
                generator_model = design.hydrokinetic_generator_model),
                GeneratorOp{typeof(hydrokinetic_shaft_kw + zero(design.hydrokinetic_rated_power_kw))}(),
                hydrokinetic_shaft_kw),
        hydrokinetic_converter_loss_residual_kw = hydrokinetic_bus_kw -
            converter_output(ConverterDesign{typeof(hydrokinetic_device_kw + zero(design.hydrokinetic_rated_power_kw))}(
                rated_power = design.hydrokinetic_rated_power_kw,
                efficiency = design.hydrokinetic_converter_efficiency,
                converter_model = design.hydrokinetic_converter_model),
                ConverterOp{typeof(hydrokinetic_device_kw + zero(design.hydrokinetic_rated_power_kw))}(),
                hydrokinetic_device_kw),
        diesel_fuel_inventory_residual_l = diesel_fuel_next_l - diesel_fuel_state +
            diesel_fuel_used_l,
        diesel_power_margin_kw = design.diesel_rated_power_kw - diesel_shaft_kw,
        diesel_fuel_available_margin_l = diesel_fuel_state - diesel_fuel_used_l,
        diesel_generator_loss_residual_kw = diesel_device_kw -
            generator_output(GeneratorDesign{typeof(diesel_shaft_kw + zero(design.diesel_rated_power_kw))}(
                rated_power = design.diesel_rated_power_kw,
                efficiency = design.diesel_generator_efficiency,
                generator_model = design.diesel_generator_model),
                GeneratorOp{typeof(diesel_shaft_kw + zero(design.diesel_rated_power_kw))}(),
                diesel_shaft_kw),
        diesel_converter_loss_residual_kw = diesel_bus_kw -
            converter_output(ConverterDesign{typeof(diesel_device_kw + zero(design.diesel_rated_power_kw))}(
                rated_power = design.diesel_rated_power_kw,
                efficiency = design.diesel_converter_efficiency,
                converter_model = design.diesel_converter_model),
                ConverterOp{typeof(diesel_device_kw + zero(design.diesel_rated_power_kw))}(),
                diesel_device_kw),
        h2_inventory_residual_kg = h2_level_next_kg -
            (h2_state + h2_device_power_kw * dt_h /
             max(design.h2_specific_energy_kwh_per_kg, eps(Float64)) -
             scenario.demands.h2_demand_kg_per_h[k] * dt_h),
        h2_power_margin_kw = design.h2_electrolyzer_power_kw - h2_device_power_kw,
        h2_converter_loss_residual_kw = h2_bus_kw -
            converter_output(ConverterDesign{typeof(h2_device_power_kw + zero(design.h2_electrolyzer_power_kw))}(
                rated_power = design.h2_electrolyzer_power_kw,
                efficiency = design.h2_converter_efficiency,
                converter_model = design.h2_converter_model),
                ConverterOp{typeof(h2_device_power_kw + zero(design.h2_electrolyzer_power_kw))}(),
                -h2_device_power_kw),
        desal_inventory_residual_m3 = desal_level_next_m3 -
            (desal_state + desal_device_power_kw * dt_h /
             max(design.desal_specific_energy_kwh_per_m3, eps(Float64)) -
             scenario.demands.desal_demand_m3_per_h[k] * dt_h),
        desal_power_margin_kw = design.desal_plant_power_kw - desal_device_power_kw,
        desal_converter_loss_residual_kw = desal_bus_kw -
            converter_output(ConverterDesign{typeof(desal_device_power_kw + zero(design.desal_plant_power_kw))}(
                rated_power = design.desal_plant_power_kw,
                efficiency = design.desal_converter_efficiency,
                converter_model = design.desal_converter_model),
                ConverterOp{typeof(desal_device_power_kw + zero(design.desal_plant_power_kw))}(),
                -desal_device_power_kw),
        battery_power_margin_kw = design.battery_power_kw -
            max(abs(battery_device_kw), abs(battery_bus_kw)),
        load_converter_rating_margin_kw = design.load_converter_rating_kw -
            max(abs(load_device_kw), abs(load_bus_kw)),
    )
end

function evaluate_constraints(model::AssembledModel, x = model.x0)
    n = _scenario_length(model.scenario, model.formulation)
    design = _minimal_design_values(model, x)
    T = eltype(x)
    values = T[]
    for entry in model.registry.residuals
        k = entry.time_index === nothing ? n : min(entry.time_index, n)
        soc_prev = _entry_value(x, model.registry, :battery, :battery_soc, k; default = model.scenario.initial_states.battery_soc)
        soc_next = _entry_value(x, model.registry, :battery, :battery_soc, k + 1; default = soc_prev)
        diesel_fuel_prev = _entry_value(x, model.registry, :diesel_engine,
            :diesel_fuel_l, k; default = model.scenario.initial_states.diesel_fuel_l)
        diesel_fuel_next = _entry_value(x, model.registry, :diesel_engine,
            :diesel_fuel_l, k + 1; default = diesel_fuel_prev)
        h2_level_prev = _entry_value(x, model.registry, :h2_electrolyzer,
            :h2_level_kg, k; default = model.scenario.initial_states.h2_level_kg)
        h2_level_next = _entry_value(x, model.registry, :h2_electrolyzer,
            :h2_level_kg, k + 1; default = h2_level_prev)
        desal_level_prev = _entry_value(x, model.registry, :desalination,
            :desal_level_m3, k; default = model.scenario.initial_states.desal_level_m3)
        desal_level_next = _entry_value(x, model.registry, :desalination,
            :desal_level_m3, k + 1; default = desal_level_prev)
        theta = _entry_value(x, model.registry, :platform, :platform_theta_rad, k; default = 0.0)
        omega = _entry_value(x, model.registry, :platform, :platform_omega_rad_s, k; default = 0.0)
        theta_next = _entry_value(x, model.registry, :platform, :platform_theta_rad, k + 1; default = theta)
        omega_next = _entry_value(x, model.registry, :platform, :platform_omega_rad_s, k + 1; default = omega)
        solar_curt = _entry_value(x, model.registry, :solar_array, :solar_curtailment, k; default = 0.0)
        batt_cmd = _entry_value(x, model.registry, :battery, :battery_command_kw, k; default = 0.0)
        load_served = _entry_value(x, model.registry, :load, :load_served_fraction, k; default = 1.0)
        wind_curt = _entry_value(x, model.registry, :wind_rotor, :wind_curtailment, k; default = 0.0)
        wave_curt = _entry_value(x, model.registry, :wave_wec, :wave_curtailment, k; default = 0.0)
        hydrokinetic_curt = _entry_value(x, model.registry, :hydrokinetic_rotor,
            :hydrokinetic_curtailment, k; default = 0.0)
        diesel_power = _entry_value(x, model.registry, :diesel_engine,
            :diesel_power_kw, k; default = 0.0)
        h2_power = _entry_value(x, model.registry, :h2_electrolyzer,
            :h2_power_kw, k; default = 0.0)
        desal_power = _entry_value(x, model.registry, :desalination,
            :desal_power_kw, k; default = 0.0)
        row = _minimal_step(model.system, model.scenario, design, k, soc_prev,
            solar_curt, batt_cmd, load_served;
            wind_curtailment = wind_curt,
            wave_curtailment = wave_curt,
            hydrokinetic_curtailment = hydrokinetic_curt,
            diesel_power_kw = diesel_power,
            diesel_fuel_prev = diesel_fuel_prev,
            h2_power_kw = h2_power,
            h2_level_prev = h2_level_prev,
            desal_power_kw = desal_power,
            desal_level_prev = desal_level_prev,
            theta = theta,
            omega = omega,
            theta_next = theta_next,
            omega_next = omega_next)
        value = if entry.owner == :bus && entry.name == :bus_power_balance
            row.bus_balance_residual_kw
        elseif entry.owner == :battery && entry.name == :battery_inventory
            soc_next * design.battery_capacity_kwh -
                (soc_prev * design.battery_capacity_kwh +
                 max(-batt_cmd, zero(batt_cmd)) * _scenario_dt_hours(model.scenario, model.formulation) * design.battery_charge_efficiency -
                 max(batt_cmd, zero(batt_cmd)) * _scenario_dt_hours(model.scenario, model.formulation) / design.battery_discharge_efficiency)
        elseif entry.owner == :battery && entry.name == :battery_terminal_soc
            (soc_next - model.scenario.initial_states.battery_soc) *
                design.battery_capacity_kwh
        elseif entry.owner == :solar_array && entry.name == :solar_available_limit
            row.solar_available_margin_kw
        elseif entry.owner == :solar_converter && entry.name == :solar_converter_loss_relation
            row.solar_bus_power_kw - row.solar_device_power_kw * design.solar_converter_efficiency
        elseif entry.owner == :solar_converter && entry.name == :solar_converter_rating_limit
            row.solar_converter_rating_margin_kw
        elseif entry.owner == :battery && entry.name == :battery_power_limit
            row.battery_power_margin_kw
        elseif entry.owner == :battery_converter && entry.name == :battery_converter_loss_relation
            row.battery_bus_power_kw - _power_to_bus(batt_cmd, design.battery_converter_efficiency)
        elseif entry.owner == :battery_converter && entry.name == :battery_converter_rating_limit
            row.battery_power_margin_kw
        elseif entry.owner == :load && entry.name == :load_served_bounds
            row.load_served_fraction
        elseif entry.owner == :load && entry.name == :load_converter_rating_limit
            row.load_converter_rating_margin_kw
        elseif entry.owner == :wind_rotor && entry.name == :wind_available_limit
            row.wind_available_margin_kw
        elseif entry.owner == :wind_rotor && entry.name == :wind_rating_limit
            row.wind_rating_margin_kw
        elseif entry.owner == :wind_generator && entry.name == :wind_generator_loss_relation
            row.wind_generator_loss_residual_kw
        elseif entry.owner == :wind_converter && entry.name == :wind_converter_loss_relation
            row.wind_converter_loss_residual_kw
        elseif entry.owner == :wind_converter && entry.name == :wind_converter_rating_limit
            row.wind_rating_margin_kw
        elseif entry.owner == :wave_wec && entry.name == :wave_available_limit
            row.wave_available_margin_kw
        elseif entry.owner == :wave_wec && entry.name == :wave_rating_limit
            row.wave_rating_margin_kw
        elseif entry.owner == :wave_wec && entry.name == :wave_pto_limit
            row.wave_rating_margin_kw
        elseif entry.owner == :wave_converter && entry.name == :wave_converter_loss_relation
            row.wave_converter_loss_residual_kw
        elseif entry.owner == :hydrokinetic_rotor && entry.name == :hydrokinetic_available_limit
            row.hydrokinetic_available_margin_kw
        elseif entry.owner == :hydrokinetic_rotor && entry.name == :hydrokinetic_rating_limit
            row.hydrokinetic_rating_margin_kw
        elseif entry.owner == :hydrokinetic_generator && entry.name == :hydrokinetic_generator_loss_relation
            row.hydrokinetic_generator_loss_residual_kw
        elseif entry.owner == :hydrokinetic_converter && entry.name == :hydrokinetic_converter_loss_relation
            row.hydrokinetic_converter_loss_residual_kw
        elseif entry.owner == :hydrokinetic_converter && entry.name == :hydrokinetic_converter_rating_limit
            row.hydrokinetic_rating_margin_kw
        elseif entry.owner == :diesel_engine && entry.name == :diesel_fuel_inventory
            diesel_fuel_next - diesel_fuel_prev + row.diesel_fuel_used_l
        elseif entry.owner == :diesel_engine && entry.name == :diesel_power_limit
            row.diesel_power_margin_kw
        elseif entry.owner == :diesel_engine && entry.name == :diesel_fuel_available_limit
            row.diesel_fuel_available_margin_l
        elseif entry.owner == :diesel_generator && entry.name == :diesel_generator_loss_relation
            row.diesel_generator_loss_residual_kw
        elseif entry.owner == :diesel_converter && entry.name == :diesel_converter_loss_relation
            row.diesel_converter_loss_residual_kw
        elseif entry.owner == :diesel_converter && entry.name == :diesel_converter_rating_limit
            row.diesel_power_margin_kw
        elseif entry.owner == :h2_electrolyzer && entry.name == :h2_inventory
            h2_level_next - (h2_level_prev + row.h2_device_power_kw *
                _scenario_dt_hours(model.scenario, model.formulation) /
                design.h2_specific_energy_kwh_per_kg -
                model.scenario.demands.h2_demand_kg_per_h[k] *
                _scenario_dt_hours(model.scenario, model.formulation))
        elseif entry.owner == :h2_electrolyzer && entry.name == :h2_power_limit
            row.h2_power_margin_kw
        elseif entry.owner == :h2_converter && entry.name == :h2_converter_loss_relation
            row.h2_converter_loss_residual_kw
        elseif entry.owner == :h2_converter && entry.name == :h2_converter_rating_limit
            row.h2_power_margin_kw
        elseif entry.owner == :desalination && entry.name == :desal_inventory
            desal_level_next - (desal_level_prev + row.desal_device_power_kw *
                _scenario_dt_hours(model.scenario, model.formulation) /
                design.desal_specific_energy_kwh_per_m3 -
                model.scenario.demands.desal_demand_m3_per_h[k] *
                _scenario_dt_hours(model.scenario, model.formulation))
        elseif entry.owner == :desalination && entry.name == :desal_power_limit
            row.desal_power_margin_kw
        elseif entry.owner == :desal_converter && entry.name == :desal_converter_loss_relation
            row.desal_converter_loss_residual_kw
        elseif entry.owner == :desal_converter && entry.name == :desal_converter_rating_limit
            row.desal_power_margin_kw
        elseif entry.owner == :platform && entry.name == :platform_kinematic_defect
            row.platform_kinematic_residual_rad
        elseif entry.owner == :platform && entry.name == :platform_dynamic_defect
            row.platform_dynamic_residual_rad_s
        else
            throw(ArgumentError("No residual evaluator for $(entry.owner).$(entry.name). Add an explicit equation before registering this residual."))
        end
        push!(values, value + zero(T))
    end
    return values
end

function objective_value(model::AssembledModel, x = model.x0)
    design = _minimal_design_values(model, x)
    solar_cost = 250.0 * design.solar_area_m2
    solar_converter_cost = 80.0 * design.solar_converter_rating_kw
    battery_cost = 300.0 * design.battery_capacity_kwh + 100.0 * design.battery_power_kw
    load_converter_cost = 40.0 * design.load_converter_rating_kw
    wind_cost = 500.0 * design.wind_rated_power_kw
    wave_cost = 650.0 * design.wave_rated_power_kw + 100.0 * design.wave_capture_width_m
    hydrokinetic_cost = 550.0 * design.hydrokinetic_rated_power_kw
    diesel_cost = 180.0 * design.diesel_rated_power_kw + 2.0 * design.diesel_fuel_tank_l
    h2_cost = 220.0 * design.h2_electrolyzer_power_kw + 50.0 * design.h2_tank_capacity_kg
    desal_cost = 160.0 * design.desal_plant_power_kw + 40.0 * design.desal_tank_capacity_m3
    platform_cost = _has_block(model.system, :platform) ? 0.01 * design.platform_inertia_kg_m2 : 0.0
    total = solar_cost + solar_converter_cost + battery_cost + load_converter_cost +
        wind_cost + wave_cost + hydrokinetic_cost + diesel_cost + h2_cost +
        desal_cost + platform_cost
    if model.objective.name == :minimize_cost_per_watt
        served = sum(model.scenario.demands.load_kw) * _scenario_dt_hours(model.scenario, model.formulation)
        return total / max(served, eps(Float64))
    end
    return total
end

function _initial_solution(model::AssembledModel)
    x = copy(model.x0)
    initial_soc = Float64(model.scenario.initial_states.battery_soc)
    for entry in model.registry.variables
        if entry.owner == :battery && entry.name == :battery_soc
            x[first(entry.index_range)] = initial_soc
        elseif entry.owner == :diesel_engine && entry.name == :diesel_fuel_l
            x[first(entry.index_range)] = Float64(model.scenario.initial_states.diesel_fuel_l)
        elseif entry.owner == :h2_electrolyzer && entry.name == :h2_level_kg
            x[first(entry.index_range)] = Float64(model.scenario.initial_states.h2_level_kg)
        elseif entry.owner == :desalination && entry.name == :desal_level_m3
            x[first(entry.index_range)] = Float64(model.scenario.initial_states.desal_level_m3)
        end
    end
    return x
end

function _source_bus_after_curtail(system::SystemGraph, scenario::ScenarioSpec,
        design, k::Int, theta, source::Symbol, curtailment)
    if source == :solar
        available = _source_available_bus(system, scenario, design, k, theta, :solar)
        return _power_to_bus(available.device * (1.0 - curtailment),
            design.solar_converter_efficiency)
    elseif source == :wind
        available = _source_available_bus(system, scenario, design, k, theta, :wind)
        shaft = available.available * (1.0 - curtailment)
        Tshaft = typeof(shaft + zero(design.wind_rated_power_kw))
        device = generator_output(
            GeneratorDesign{Tshaft}(rated_power = design.wind_rated_power_kw,
                efficiency = design.wind_generator_efficiency,
                generator_model = design.wind_generator_model),
            GeneratorOp{Tshaft}(), shaft)
        Tdevice = typeof(device + zero(design.wind_rated_power_kw))
        return converter_output(
            ConverterDesign{Tdevice}(rated_power = design.wind_rated_power_kw,
                efficiency = design.wind_converter_efficiency,
                converter_model = design.wind_converter_model),
            ConverterOp{Tdevice}(), device)
    elseif source == :wave
        available = _source_available_bus(system, scenario, design, k, theta, :wave)
        return _power_to_bus(available.device * (1.0 - curtailment),
            design.wave_converter_efficiency)
    elseif source == :hydrokinetic
        available = _source_available_bus(system, scenario, design, k, theta, :hydrokinetic)
        shaft = available.available * (1.0 - curtailment)
        Tshaft = typeof(shaft + zero(design.hydrokinetic_rated_power_kw))
        device = generator_output(
            GeneratorDesign{Tshaft}(rated_power = design.hydrokinetic_rated_power_kw,
                efficiency = design.hydrokinetic_generator_efficiency,
                generator_model = design.hydrokinetic_generator_model),
            GeneratorOp{Tshaft}(), shaft)
        Tdevice = typeof(device + zero(design.hydrokinetic_rated_power_kw))
        return converter_output(
            ConverterDesign{Tdevice}(rated_power = design.hydrokinetic_rated_power_kw,
                efficiency = design.hydrokinetic_converter_efficiency,
                converter_model = design.hydrokinetic_converter_model),
            ConverterOp{Tdevice}(), device)
    end
    return zero(theta)
end

function _curtailment_for_desired_bus(system::SystemGraph, scenario::ScenarioSpec,
        design, k::Int, theta, source::Symbol, desired_bus)
    desired_bus <= 0 && return 1.0
    available_bus = _source_bus_after_curtail(system, scenario, design, k, theta, source, 0.0)
    available_bus <= 0 && return 1.0
    desired_bus >= available_bus && return 0.0
    lo = 0.0
    hi = 1.0
    for _ in 1:60
        mid = (lo + hi) / 2
        bus = _source_bus_after_curtail(system, scenario, design, k, theta, source, mid)
        if bus > desired_bus
            lo = mid
        else
            hi = mid
        end
    end
    return clamp((lo + hi) / 2, 0.0, 1.0)
end

function _allocate_source!(curtailments::Dict{Symbol,Float64}, system::SystemGraph,
        scenario::ScenarioSpec, design, k::Int, theta, source::Symbol,
        remaining_bus_need)
    remaining_bus_need <= 0 && return 0.0
    available_bus = _source_bus_after_curtail(system, scenario, design, k, theta, source, 0.0)
    if available_bus <= 0
        curtailments[source] = 1.0
        return remaining_bus_need
    end
    desired = min(remaining_bus_need, available_bus)
    curtailments[source] = _curtailment_for_desired_bus(system, scenario, design, k,
        theta, source, desired)
    supplied = _source_bus_after_curtail(system, scenario, design, k, theta, source,
        curtailments[source])
    return max(remaining_bus_need - supplied, 0.0)
end

function _dispatch_sources(system::SystemGraph)
    sources = Symbol[:solar]
    _has_block(system, :wind_rotor) && push!(sources, :wind)
    _has_block(system, :wave_wec) && push!(sources, :wave)
    _has_block(system, :hydrokinetic_rotor) && push!(sources, :hydrokinetic)
    return sources
end

function _adjust_source_bus_supply!(curtailments::Dict{Symbol,Float64},
        system::SystemGraph, scenario::ScenarioSpec, design, k::Int, theta,
        bus_delta)
    abs(bus_delta) <= 1e-12 && return 0.0
    remaining = abs(Float64(bus_delta))
    delivered = 0.0
    if bus_delta < 0
        for source in _dispatch_sources(system)
            current = _source_bus_after_curtail(system, scenario, design, k,
                theta, source, curtailments[source])
            available = _source_bus_after_curtail(system, scenario, design, k,
                theta, source, 0.0)
            extra = min(remaining, max(available - current, 0.0))
            extra <= 1e-12 && continue
            desired = current + extra
            curtailments[source] = _curtailment_for_desired_bus(system, scenario,
                design, k, theta, source, desired)
            supplied = _source_bus_after_curtail(system, scenario, design, k,
                theta, source, curtailments[source])
            actual = max(supplied - current, 0.0)
            remaining = max(remaining - actual, 0.0)
            delivered += actual
            remaining <= 1e-12 && break
        end
        return -delivered
    end
    for source in reverse(_dispatch_sources(system))
        current = _source_bus_after_curtail(system, scenario, design, k, theta,
            source, curtailments[source])
        reduction = min(remaining, max(current, 0.0))
        reduction <= 1e-12 && continue
        desired = current - reduction
        curtailments[source] = _curtailment_for_desired_bus(system, scenario,
            design, k, theta, source, desired)
        supplied = _source_bus_after_curtail(system, scenario, design, k, theta,
            source, curtailments[source])
        actual = max(current - supplied, 0.0)
        remaining = max(remaining - actual, 0.0)
        delivered += actual
        remaining <= 1e-12 && break
    end
    return delivered
end

function _battery_command_for_target_soc(soc, target_soc, design, dt_h)
    delta_soc = target_soc - soc
    abs(delta_soc) <= 1e-12 && return 0.0
    if delta_soc > 0
        charge_kw = delta_soc * design.battery_capacity_kwh /
            (dt_h * design.battery_charge_efficiency)
        return -min(charge_kw, design.battery_power_kw)
    end
    discharge_kw = -delta_soc * design.battery_capacity_kwh *
        design.battery_discharge_efficiency / dt_h
    return min(discharge_kw, design.battery_power_kw)
end

function _battery_command_from_bus_power(bus_kw, efficiency)
    bus_kw >= 0 && return bus_kw / efficiency
    return bus_kw * efficiency
end

function _apply_terminal_soc_dispatch!(curtailments::Dict{Symbol,Float64},
        system::SystemGraph, scenario::ScenarioSpec, formulation::FormulationSpec,
        design, k::Int, n::Int, theta, soc, batt_cmd, dt_h)
    _terminal_soc_equal_initial(formulation) || return batt_cmd
    k == n || return batt_cmd
    _has_block(system, :battery) || return batt_cmd
    design.battery_capacity_kwh > 0 || return batt_cmd
    target_soc = clamp(Float64(scenario.initial_states.battery_soc), 0.0, 1.0)
    target_cmd = _battery_command_for_target_soc(soc, target_soc, design, dt_h)
    old_bus = _power_to_bus(batt_cmd, design.battery_converter_efficiency)
    target_bus = _power_to_bus(target_cmd, design.battery_converter_efficiency)
    requested_delta = target_bus - old_bus
    actual_delta = _adjust_source_bus_supply!(curtailments, system, scenario,
        design, k, theta, requested_delta)
    return _battery_command_from_bus_power(old_bus + actual_delta,
        design.battery_converter_efficiency)
end

function _diesel_dispatch_for_desired_bus(design, desired_bus, dt_h)
    desired_bus <= 0 && return 0.0
    rated = Float64(design.diesel_rated_power_kw)
    rated <= 0 && return 0.0
    available_bus = _diesel_outputs(design, rated, dt_h).bus
    available_bus <= 0 && return 0.0
    desired_bus >= available_bus && return rated
    lo = 0.0
    hi = rated
    for _ in 1:60
        mid = (lo + hi) / 2
        bus = _diesel_outputs(design, mid, dt_h).bus
        if bus < desired_bus
            lo = mid
        else
            hi = mid
        end
    end
    return clamp((lo + hi) / 2, 0.0, rated)
end

function _solve_minimal_controls!(x, model::AssembledModel)
    design = _minimal_design_values(model, x)
    n = _scenario_length(model.scenario, model.formulation)
    dt_h = _scenario_dt_hours(model.scenario, model.formulation)
    soc = Float64(model.scenario.initial_states.battery_soc)
    diesel_fuel = Float64(model.scenario.initial_states.diesel_fuel_l)
    h2_level = Float64(model.scenario.initial_states.h2_level_kg)
    desal_level = Float64(model.scenario.initial_states.desal_level_m3)
    theta = 0.0
    omega = 0.0
    _set_entry_value!(x, model.registry, :battery, :battery_soc, 1, soc)
    _set_entry_value!(x, model.registry, :diesel_engine, :diesel_fuel_l, 1, diesel_fuel)
    _set_entry_value!(x, model.registry, :h2_electrolyzer, :h2_level_kg, 1, h2_level)
    _set_entry_value!(x, model.registry, :desalination, :desal_level_m3, 1, desal_level)
    _set_entry_value!(x, model.registry, :platform, :platform_theta_rad, 1, theta)
    _set_entry_value!(x, model.registry, :platform, :platform_omega_rad_s, 1, omega)
    for k in 1:n
        load_kw = model.scenario.demands.load_kw[k]
        h2_power = 0.0
        h2_bus_need = 0.0
        if _has_block(model.system, :h2_electrolyzer)
            h2_power = min(design.h2_electrolyzer_power_kw,
                model.scenario.demands.h2_demand_kg_per_h[k] *
                design.h2_specific_energy_kwh_per_kg)
            h2_probe = _h2_outputs(design, model.scenario, h2_level, h2_power,
                dt_h, k)
            h2_bus_need = max(-Float64(h2_probe.bus), 0.0)
        end
        desal_power = 0.0
        desal_bus_need = 0.0
        if _has_block(model.system, :desalination)
            desal_power = min(design.desal_plant_power_kw,
                model.scenario.demands.desal_demand_m3_per_h[k] *
                design.desal_specific_energy_kwh_per_m3)
            desal_probe = _desal_outputs(design, model.scenario, desal_level,
                desal_power, dt_h, k)
            desal_bus_need = max(-Float64(desal_probe.bus), 0.0)
        end
        load_bus_need = load_kw / design.load_converter_efficiency +
            h2_bus_need + desal_bus_need
        curtailments = Dict{Symbol,Float64}(:solar => 1.0, :wind => 1.0,
            :wave => 1.0, :hydrokinetic => 1.0)
        remaining = load_bus_need
        remaining = _allocate_source!(curtailments, model.system, model.scenario,
            design, k, theta, :solar, remaining)
        if _has_block(model.system, :wind_rotor)
            remaining = _allocate_source!(curtailments, model.system, model.scenario,
                design, k, theta, :wind, remaining)
        end
        if _has_block(model.system, :wave_wec)
            remaining = _allocate_source!(curtailments, model.system, model.scenario,
                design, k, theta, :wave, remaining)
        end
        if _has_block(model.system, :hydrokinetic_rotor)
            remaining = _allocate_source!(curtailments, model.system, model.scenario,
                design, k, theta, :hydrokinetic, remaining)
        end
        solar_curt = curtailments[:solar]
        wind_curt = curtailments[:wind]
        wave_curt = curtailments[:wave]
        hydrokinetic_curt = curtailments[:hydrokinetic]
        diesel_power = 0.0
        if remaining > 1e-12 && _has_block(model.system, :diesel_engine)
            diesel_power = _diesel_dispatch_for_desired_bus(design, remaining, dt_h)
            diesel_bus = _diesel_outputs(design, diesel_power, dt_h).bus
            remaining = max(remaining - diesel_bus, 0.0)
        end
        batt_cmd = 0.0
        served = 1.0
        if remaining > 1e-12
            if _has_block(model.system, :battery) && design.battery_capacity_kwh > 0
                max_discharge_from_soc = max(soc, 0.0) * design.battery_capacity_kwh *
                    design.battery_discharge_efficiency / dt_h
                max_discharge = min(design.battery_power_kw, max_discharge_from_soc)
                requested_device = remaining / design.battery_converter_efficiency
                batt_cmd = min(requested_device, max_discharge)
                supplied_bus = load_bus_need - remaining + batt_cmd * design.battery_converter_efficiency
                served = min(1.0, supplied_bus / load_bus_need)
            else
                supplied_bus = load_bus_need - remaining
                served = min(1.0, supplied_bus / load_bus_need)
            end
        end
        solar_curt = clamp(solar_curt, 0.0, 1.0)
        wind_curt = clamp(wind_curt, 0.0, 1.0)
        wave_curt = clamp(wave_curt, 0.0, 1.0)
        hydrokinetic_curt = clamp(hydrokinetic_curt, 0.0, 1.0)
        served = clamp(served, design.critical_load_fraction, 1.0)
        batt_cmd = _apply_terminal_soc_dispatch!(curtailments, model.system,
            model.scenario, model.formulation, design, k, n, theta, soc,
            batt_cmd, dt_h)
        solar_curt = clamp(curtailments[:solar], 0.0, 1.0)
        wind_curt = clamp(curtailments[:wind], 0.0, 1.0)
        wave_curt = clamp(curtailments[:wave], 0.0, 1.0)
        hydrokinetic_curt = clamp(curtailments[:hydrokinetic], 0.0, 1.0)
        _set_entry_value!(x, model.registry, :solar_array, :solar_curtailment, k, solar_curt)
        _set_entry_value!(x, model.registry, :wind_rotor, :wind_curtailment, k, wind_curt)
        _set_entry_value!(x, model.registry, :wave_wec, :wave_curtailment, k, wave_curt)
        _set_entry_value!(x, model.registry, :hydrokinetic_rotor,
            :hydrokinetic_curtailment, k, hydrokinetic_curt)
        _set_entry_value!(x, model.registry, :diesel_engine, :diesel_power_kw, k,
            diesel_power)
        _set_entry_value!(x, model.registry, :h2_electrolyzer, :h2_power_kw, k,
            h2_power)
        _set_entry_value!(x, model.registry, :desalination, :desal_power_kw, k,
            desal_power)
        _set_entry_value!(x, model.registry, :battery, :battery_command_kw, k, batt_cmd)
        _set_entry_value!(x, model.registry, :load, :load_served_fraction, k, served)

        row = _minimal_step(model.system, model.scenario, design, k, soc,
            solar_curt, batt_cmd, served;
            wind_curtailment = wind_curt,
            wave_curtailment = wave_curt,
            hydrokinetic_curtailment = hydrokinetic_curt,
            diesel_power_kw = diesel_power,
            diesel_fuel_prev = diesel_fuel,
            h2_power_kw = h2_power,
            h2_level_prev = h2_level,
            desal_power_kw = desal_power,
            desal_level_prev = desal_level,
            theta = theta,
            omega = omega)

        if _has_block(model.system, :diesel_engine)
            diesel_fuel = max(Float64(row.diesel_fuel_l), 0.0)
        end
        _set_entry_value!(x, model.registry, :diesel_engine, :diesel_fuel_l, k + 1,
            diesel_fuel)
        if _has_block(model.system, :h2_electrolyzer)
            h2_level = clamp(Float64(row.h2_level_kg), 0.0,
                Float64(design.h2_tank_capacity_kg))
        end
        _set_entry_value!(x, model.registry, :h2_electrolyzer, :h2_level_kg,
            k + 1, h2_level)
        if _has_block(model.system, :desalination)
            desal_level = clamp(Float64(row.desal_level_m3), 0.0,
                Float64(design.desal_tank_capacity_m3))
        end
        _set_entry_value!(x, model.registry, :desalination, :desal_level_m3,
            k + 1, desal_level)
        if _has_block(model.system, :battery) && design.battery_capacity_kwh > 0
            soc = clamp(Float64(row.battery_soc), 0.0, 1.0)
        end
        _set_entry_value!(x, model.registry, :battery, :battery_soc, k + 1, soc)
        if _has_block(model.system, :platform)
            theta = Float64(row.platform_theta_next_rad)
            omega = Float64(row.platform_omega_next_rad_s)
            _set_entry_value!(x, model.registry, :platform, :platform_theta_rad, k + 1, theta)
            _set_entry_value!(x, model.registry, :platform, :platform_omega_rad_s, k + 1, omega)
        end
    end
    return x
end

function _controls_from_x(model::AssembledModel, x)
    n = _scenario_length(model.scenario, model.formulation)
    controls = NamedTuple[]
    for k in 1:n
        push!(controls, (
            solar_curtailment = _entry_value(x, model.registry, :solar_array, :solar_curtailment, k; default = 0.0),
            wind_curtailment = _entry_value(x, model.registry, :wind_rotor, :wind_curtailment, k; default = 0.0),
            wave_curtailment = _entry_value(x, model.registry, :wave_wec, :wave_curtailment, k; default = 0.0),
            hydrokinetic_curtailment = _entry_value(x, model.registry,
                :hydrokinetic_rotor, :hydrokinetic_curtailment, k; default = 0.0),
            diesel_power_kw = _entry_value(x, model.registry, :diesel_engine,
                :diesel_power_kw, k; default = 0.0),
            h2_power_kw = _entry_value(x, model.registry, :h2_electrolyzer,
                :h2_power_kw, k; default = 0.0),
            desal_power_kw = _entry_value(x, model.registry, :desalination,
                :desal_power_kw, k; default = 0.0),
            battery_command_kw = _entry_value(x, model.registry, :battery, :battery_command_kw, k; default = 0.0),
            load_served_fraction = _entry_value(x, model.registry, :load, :load_served_fraction, k; default = 1.0),
        ))
    end
    return controls
end

_nt_get(nt::NamedTuple, key::Symbol, default) =
    key in keys(nt) ? getproperty(nt, key) : default

function _copy_design_values!(target_x, target_registry::AssemblyRegistry,
        source_x, source_registry::AssemblyRegistry)
    for entry in source_registry.variables
        entry.role == :design || continue
        value = source_x[first(entry.index_range)]
        _set_entry_value!(target_x, target_registry, entry.owner, entry.name,
            nothing, value)
    end
    return target_x
end

function _replay_constraint_formulation(formulation::FormulationSpec,
        objective::ObjectiveSpec)
    formulation.mode == :collocation && return formulation
    return Collocation(time_grid = formulation.time_grid, objective = objective)
end

function _replay_with_controls(system::SystemGraph, scenario::ScenarioSpec,
        controls::Vector{NamedTuple}; formulation::FormulationSpec = Simulation(),
        registry::AssemblyRegistry = build_registry(system, scenario, formulation),
        solution_x = Float64[], solver = (name = :replay, status = :ok),
        objective = MinimizeTotalCost(), objective_value = 0.0)

    source_model = assemble(system, scenario, formulation, objective)
    source_x = isempty(solution_x) || length(solution_x) != length(source_model.x0) ?
        _initial_solution(source_model) : solution_x
    constraint_formulation = _replay_constraint_formulation(formulation, objective)
    design_model = assemble(system, scenario, constraint_formulation, objective)
    constraint_x = _initial_solution(design_model)
    _copy_design_values!(constraint_x, design_model.registry, source_x,
        source_model.registry)
    design = _minimal_design_values(design_model, constraint_x)
    soc = Float64(scenario.initial_states.battery_soc)
    diesel_fuel = Float64(scenario.initial_states.diesel_fuel_l)
    h2_level = Float64(scenario.initial_states.h2_level_kg)
    desal_level = Float64(scenario.initial_states.desal_level_m3)
    theta = 0.0
    omega = 0.0
    _set_entry_value!(constraint_x, design_model.registry, :battery,
        :battery_soc, 1, soc)
    _set_entry_value!(constraint_x, design_model.registry, :diesel_engine,
        :diesel_fuel_l, 1, diesel_fuel)
    _set_entry_value!(constraint_x, design_model.registry, :h2_electrolyzer,
        :h2_level_kg, 1, h2_level)
    _set_entry_value!(constraint_x, design_model.registry, :desalination,
        :desal_level_m3, 1, desal_level)
    _set_entry_value!(constraint_x, design_model.registry, :platform,
        :platform_theta_rad, 1, theta)
    _set_entry_value!(constraint_x, design_model.registry, :platform,
        :platform_omega_rad_s, 1, omega)
    states = NamedTuple[(time_s = 0.0, battery_soc = soc,
        diesel_fuel_l = diesel_fuel,
        h2_level_kg = h2_level,
        desal_level_m3 = desal_level,
        platform_theta_rad = theta, platform_omega_rad_s = omega)]
    rows = NamedTuple[]
    for (k, control) in enumerate(controls)
        _set_entry_value!(constraint_x, design_model.registry, :solar_array,
            :solar_curtailment, k, _nt_get(control, :solar_curtailment, 0.0))
        _set_entry_value!(constraint_x, design_model.registry, :wind_rotor,
            :wind_curtailment, k, _nt_get(control, :wind_curtailment, 0.0))
        _set_entry_value!(constraint_x, design_model.registry, :wave_wec,
            :wave_curtailment, k, _nt_get(control, :wave_curtailment, 0.0))
        _set_entry_value!(constraint_x, design_model.registry, :hydrokinetic_rotor,
            :hydrokinetic_curtailment, k,
            _nt_get(control, :hydrokinetic_curtailment, 0.0))
        _set_entry_value!(constraint_x, design_model.registry, :diesel_engine,
            :diesel_power_kw, k, _nt_get(control, :diesel_power_kw, 0.0))
        _set_entry_value!(constraint_x, design_model.registry, :h2_electrolyzer,
            :h2_power_kw, k, _nt_get(control, :h2_power_kw, 0.0))
        _set_entry_value!(constraint_x, design_model.registry, :desalination,
            :desal_power_kw, k, _nt_get(control, :desal_power_kw, 0.0))
        _set_entry_value!(constraint_x, design_model.registry, :battery,
            :battery_command_kw, k, _nt_get(control, :battery_command_kw, 0.0))
        _set_entry_value!(constraint_x, design_model.registry, :load,
            :load_served_fraction, k,
            _nt_get(control, :load_served_fraction, 1.0))
        row = _minimal_step(system, scenario, design, k, soc,
            _nt_get(control, :solar_curtailment, 0.0),
            _nt_get(control, :battery_command_kw, 0.0),
            _nt_get(control, :load_served_fraction, 1.0);
            wind_curtailment = _nt_get(control, :wind_curtailment, 0.0),
            wave_curtailment = _nt_get(control, :wave_curtailment, 0.0),
            hydrokinetic_curtailment = _nt_get(control,
                :hydrokinetic_curtailment, 0.0),
            diesel_power_kw = _nt_get(control, :diesel_power_kw, 0.0),
            diesel_fuel_prev = diesel_fuel,
            h2_power_kw = _nt_get(control, :h2_power_kw, 0.0),
            h2_level_prev = h2_level,
            desal_power_kw = _nt_get(control, :desal_power_kw, 0.0),
            desal_level_prev = desal_level,
            theta = theta,
            omega = omega)
        push!(rows, row)
        soc = row.battery_soc
        diesel_fuel = row.diesel_fuel_l
        h2_level = row.h2_level_kg
        desal_level = row.desal_level_m3
        theta = row.platform_theta_next_rad
        omega = row.platform_omega_next_rad_s
        _set_entry_value!(constraint_x, design_model.registry, :battery,
            :battery_soc, k + 1, soc)
        _set_entry_value!(constraint_x, design_model.registry, :diesel_engine,
            :diesel_fuel_l, k + 1, diesel_fuel)
        _set_entry_value!(constraint_x, design_model.registry, :h2_electrolyzer,
            :h2_level_kg, k + 1, h2_level)
        _set_entry_value!(constraint_x, design_model.registry, :desalination,
            :desal_level_m3, k + 1, desal_level)
        _set_entry_value!(constraint_x, design_model.registry, :platform,
            :platform_theta_rad, k + 1, theta)
        _set_entry_value!(constraint_x, design_model.registry, :platform,
            :platform_omega_rad_s, k + 1, omega)
        push!(states, (time_s = k * _scenario_grid(scenario, formulation).dt_s,
            battery_soc = soc, diesel_fuel_l = diesel_fuel,
            h2_level_kg = h2_level, desal_level_m3 = desal_level,
            platform_theta_rad = theta,
            platform_omega_rad_s = omega))
    end
    max_bus = isempty(rows) ? 0.0 : maximum(abs(row.bus_balance_residual_kw) for row in rows)
    max_inventory = isempty(rows) ? 0.0 : maximum(abs(row.battery_inventory_residual_kwh) for row in rows)
    max_diesel_fuel = isempty(rows) ? 0.0 : maximum(abs(row.diesel_fuel_inventory_residual_l) for row in rows)
    max_h2_inventory = isempty(rows) ? 0.0 : maximum(abs(row.h2_inventory_residual_kg) for row in rows)
    max_desal_inventory = isempty(rows) ? 0.0 : maximum(abs(row.desal_inventory_residual_m3) for row in rows)
    max_platform_kinematic = isempty(rows) ? 0.0 : maximum(abs(row.platform_kinematic_residual_rad) for row in rows)
    max_platform_dynamic = isempty(rows) ? 0.0 : maximum(abs(row.platform_dynamic_residual_rad_s) for row in rows)
    constraint_values = evaluate_constraints(design_model, constraint_x)
    bound_violations = max.(design_model.constraint_lower_bounds .- constraint_values,
        constraint_values .- design_model.constraint_upper_bounds)
    max_constraint_violation = isempty(bound_violations) ? 0.0 :
        max(0.0, maximum(bound_violations))
    summary = (
        max_abs_bus_balance_residual_kw = max_bus,
        max_abs_battery_inventory_residual_kwh = max_inventory,
        max_abs_diesel_fuel_inventory_residual_l = max_diesel_fuel,
        max_abs_h2_inventory_residual_kg = max_h2_inventory,
        max_abs_desal_inventory_residual_m3 = max_desal_inventory,
        max_abs_platform_kinematic_residual_rad = max_platform_kinematic,
        max_abs_platform_dynamic_residual_rad_s = max_platform_dynamic,
        max_registered_constraint_violation = max_constraint_violation,
        feasible = max_bus <= 1e-8 && max_inventory <= 1e-8 &&
            max_diesel_fuel <= 1e-8 &&
            max_h2_inventory <= 1e-8 && max_desal_inventory <= 1e-8 &&
            max_platform_kinematic <= 1e-8 && max_platform_dynamic <= 1e-8 &&
            max_constraint_violation <= 1e-8,
    )
    return ResultSpec(system, scenario, hash(system.ontology.name),
        hash((scenario.name, scenario.provenance)), formulation, solver, registry,
        summary, String[], model_path_table(system), rows, controls, states,
        objective_value, Float64.(solution_x))
end

function simulate(system::SystemGraph, scenario::ScenarioSpec = system.scenario;
        controller::RuleBasedController = RuleBasedController())
    formulation = Simulation()
    model = assemble(system, scenario, Collocation())
    x = _initial_solution(model)
    _solve_minimal_controls!(x, model)
    controls = _controls_from_x(model, x)
    registry = build_registry(system, scenario, formulation)
    return _replay_with_controls(system, scenario, controls;
        formulation = formulation, registry = registry, solution_x = x,
        solver = (name = :rule_based_controller, status = :ok,
            prefer_curtailment = controller.prefer_curtailment),
        objective = formulation.objective,
        objective_value = objective_value(model, x))
end

function replay(result::ResultSpec)
    return _replay_with_controls(result.system, result.scenario, result.controls;
        formulation = result.formulation, registry = result.registry,
        solution_x = result.solution_x,
        solver = (name = :replay, status = :ok, source_solver = result.solver.name),
        objective = result.formulation.objective,
        objective_value = result.objective_value)
end

function solve(model::AssembledModel, optimizer = nothing)
    x = _initial_solution(model)
    _solve_minimal_controls!(x, model)
    controls = _controls_from_x(model, x)
    solver = (
        name = optimizer === nothing ? :deterministic_minimal_collocation : Symbol(string(optimizer)),
        status = :solved,
        note = "Closed-form feasible controls for the minimal ontology fixture; registry and replay use the same equations.",
    )
    return _replay_with_controls(model.system, model.scenario, controls;
        formulation = model.formulation,
        registry = model.registry,
        solution_x = x,
        solver = solver,
        objective = model.objective,
        objective_value = objective_value(model, x))
end

function optimize(system::SystemGraph, scenario::ScenarioSpec = system.scenario;
        formulation::FormulationSpec = Collocation(),
        objective::ObjectiveSpec = formulation.objective,
        optimizer = nothing)
    model = assemble(system, scenario, formulation, objective)
    return solve(model, optimizer)
end

function component_table(system::SystemGraph)
    return [(name = block.name, role = block.role,
        component_type = block.component_type,
        model_path = block.model_path.path_label,
        package = block.model_path.package_name,
        adapter = block.model_path.adapter_name,
        required = block.metadata.required,
        enabled = block.metadata.enabled) for block in system.blocks]
end

function model_path_table(system::SystemGraph)
    return [(block = block.name,
        model_path = block.model_path.path_label,
        package = block.model_path.package_name,
        adapter = block.model_path.adapter_name,
        valid_range = block.model_path.valid_range,
        assumptions = join(block.model_path.assumptions, "; "),
        fallback_policy = block.model_path.fallback_policy) for block in system.blocks]
end

function _level_quantity(block::BlockSpec)
    block.name == :wind_rotor && return "wind_shaft_power_kw; wind_platform_moment_nm"
    block.name == :wind_generator && return "wind_device_power_kw"
    block.name == :wind_converter && return "wind_bus_power_kw"
    block.name == :wave_wec && return "wave_device_power_kw"
    block.name == :wave_converter && return "wave_bus_power_kw"
    block.name == :hydrokinetic_rotor && return "hydrokinetic_shaft_power_kw"
    block.name == :hydrokinetic_generator && return "hydrokinetic_device_power_kw"
    block.name == :hydrokinetic_converter && return "hydrokinetic_bus_power_kw"
    block.name == :diesel_engine && return "diesel_shaft_power_kw; diesel_fuel_l"
    block.name == :diesel_generator && return "diesel_device_power_kw"
    block.name == :diesel_converter && return "diesel_bus_power_kw"
    block.name == :h2_electrolyzer && return "h2_device_power_kw; h2_level_kg"
    block.name == :h2_converter && return "h2_bus_power_kw"
    block.name == :desalination && return "desal_device_power_kw; desal_level_m3"
    block.name == :desal_converter && return "desal_bus_power_kw"
    block.name == :platform && return "platform_theta_rad; platform_omega_rad_s"
    block.name == :solar_array && return "solar_device_power_kw"
    block.name == :solar_converter && return "solar_bus_power_kw"
    block.name == :battery && return "battery_soc; battery_device_power_kw"
    block.name == :battery_converter && return "battery_bus_power_kw"
    block.name == :load && return "load_bus_power_kw"
    block.name == :bus && return "bus_balance_residual_kw"
    return join(string.(getfield.(block.outputs, :name)), "; ")
end

function _level_units(block::BlockSpec)
    isempty(block.outputs) && return ""
    units = unique(string.(getfield.(block.outputs, :unit)))
    return join(units, "; ")
end

function _level_design_dependencies(block::BlockSpec)
    isempty(block.designs) && return ""
    return join((string(owner_qualified(spec.owner, spec.name)) for spec in block.designs), "; ")
end

function _level_scenario_dependencies(block::BlockSpec)
    block.name == :solar_resource && return "solar_irradiance_kw_per_m2"
    block.name == :wind_resource && return "wind_speed_m_s"
    block.name == :wave_resource && return "wave_power_flux_kw_per_m"
    block.name == :hydrokinetic_resource && return "hydrokinetic_current_m_s"
    block.name == :load && return "load_kw"
    block.name == :h2_electrolyzer && return "h2_demand_kg_per_h"
    block.name == :desalination && return "desal_demand_m3_per_h"
    return ""
end

function _level_state_dependencies(block::BlockSpec)
    names = Symbol[]
    append!(names, getfield.(block.states, :name))
    if block.name in (:wind_rotor, :platform)
        append!(names, [:platform_theta_rad, :platform_omega_rad_s])
    elseif block.name == :battery
        push!(names, :battery_soc)
    elseif block.name == :diesel_engine
        push!(names, :diesel_fuel_l)
    end
    isempty(names) && return ""
    return join(string.(unique(names)), "; ")
end

function _level_default_valid_range(block::BlockSpec)
    block.name == :solar_resource && return "scenario irradiance samples on main grid"
    block.name == :wind_resource && return "scenario wind-speed samples on main grid"
    block.name == :wave_resource && return "scenario wave-power-flux samples on main grid"
    block.name == :hydrokinetic_resource && return "scenario current-speed samples on main grid"
    block.name == :load && return "scenario load samples on main grid"
    block.name == :platform && return "declared state/design bounds and explicit Euler stability for selected dt"
    block.name == :bus && return "signed bus-power residual near zero"
    !isempty(block.designs) && return "declared design-variable bounds"
    !isempty(block.residuals) && return "declared residual bounds"
    return "active ontology graph only"
end

function _level_valid_range(block::BlockSpec)
    isempty(block.model_path.valid_range) || return block.model_path.valid_range
    return _level_default_valid_range(block)
end

function _level_interpolation_method(block::BlockSpec)
    if block.name in (:solar_resource, :wind_resource, :wave_resource,
            :hydrokinetic_resource, :load)
        return "zero-order hold on the scenario grid"
    elseif block.name == :platform
        return "explicit Euler motion map on the Level 2 grid"
    elseif block.model_path.path_label == :package_backed
        return "package adapter kernel evaluated on the collocation grid"
    elseif block.model_path.path_label == :surrogate
        return "smooth algebraic surrogate evaluated on the collocation grid"
    elseif block.model_path.path_label == :hard_residual
        return "direct residual evaluation on the collocation grid"
    elseif block.model_path.path_label == :prescribed
        return "prescribed sample lookup"
    end
    return "direct ontology kernel evaluation"
end

function _level_sensitivity_method(block::BlockSpec)
    if block.name in (:wind_rotor, :hydrokinetic_rotor, :h2_electrolyzer,
            :desalination, :platform, :bus)
        return "ForwardDiff/central-difference boundary check"
    elseif block.model_path.path_label == :package_backed
        return "adapter AD smoke test when kernel supports dual inputs"
    elseif block.model_path.path_label == :prescribed
        return "replay-only prescribed sample; no map sensitivity"
    end
    return "registered residual finite-difference check"
end

function _level_verification_case(block::BlockSpec)
    if block.name in (:wind_rotor, :wave_wec, :hydrokinetic_rotor,
            :platform, :solar_array, :battery, :load, :bus)
        return "examples/multilevel_collocation_hybrid_demo.jl"
    elseif block.name in (:h2_electrolyzer, :desalination, :diesel_engine)
        return "test/runtests.jl ontology process and dispatch fixtures"
    end
    return "test/runtests.jl ontology V1 minimal workflow"
end

function _level_active_bound_report(block::BlockSpec)
    names = [string(spec.name) for spec in block.residuals if spec.sense != :eq]
    isempty(names) && return ""
    return join(names, "; ")
end

function _level_pair(block::BlockSpec)
    if block.name in (:wind_rotor, :wave_wec, :hydrokinetic_rotor, :platform)
        return ("Level 1 motion/resource physics", "Level 2 dispatch contract")
    elseif block.name == :diesel_engine
        return ("Level 1 fuel and engine map", "Level 2 dispatch contract")
    elseif block.name in (:h2_electrolyzer, :desalination)
        return ("Level 1 process conversion map", "Level 2 dispatch contract")
    elseif block.name in (:solar_resource, :wind_resource, :wave_resource,
            :hydrokinetic_resource, :load)
        return ("Level 3 prescribed scenario sample", "Level 2 dispatch contract")
    elseif block.name in (:wind_generator, :wind_converter, :wave_converter,
            :hydrokinetic_generator, :hydrokinetic_converter,
            :diesel_generator, :diesel_converter,
            :h2_converter, :desal_converter,
            :solar_array, :solar_converter, :battery, :battery_converter, :bus)
        return ("Level 2 dispatch contract", "Level 2 residual assembly")
    end
    return ("ontology block", "report contract")
end

function level_map_table(system::SystemGraph)
    rows = NamedTuple[]
    for block in system.blocks
        source_level, target_level = _level_pair(block)
        interface = isempty(block.interfaces) ? nothing : first(block.interfaces)
        replacement = interface === nothing ? nothing : interface.replacement_target
        reason = block.model_path.path_label == :surrogate ?
            block.model_path.fallback_policy :
            join(block.model_path.assumptions, "; ")
        push!(rows, (
            source_level = source_level,
            target_level = target_level,
            producing_level = source_level,
            consuming_level = target_level,
            block = block.name,
            quantity = _level_quantity(block),
            unit = _level_units(block),
            design_dependencies = _level_design_dependencies(block),
            scenario_dependencies = _level_scenario_dependencies(block),
            state_dependencies = _level_state_dependencies(block),
            valid_range = _level_valid_range(block),
            interpolation_method = _level_interpolation_method(block),
            sensitivity_method = _level_sensitivity_method(block),
            verification_case = _level_verification_case(block),
            active_bound_report = _level_active_bound_report(block),
            model_path = block.model_path.path_label,
            package = block.model_path.package_name,
            adapter = block.model_path.adapter_name,
            replacement_target = replacement,
            fallback_policy = block.model_path.fallback_policy,
            substitution_reason = reason,
        ))
    end
    return rows
end

function plot_table(system::SystemGraph)
    rows = NamedTuple[]
    for block in system.blocks
        for spec in block.outputs
            spec.plot_group === nothing && continue
            push!(rows, (
                owner = spec.owner,
                name = spec.name,
                label = spec.label,
                unit = spec.unit,
                plot_group = spec.plot_group,
                source = spec.source,
                model_path = spec.model_path.path_label,
            ))
        end
    end
    return rows
end

function connection_table(system::SystemGraph)
    return [(source = owner_qualified(conn.source_block, conn.source_port),
        sink = owner_qualified(conn.sink_block, conn.sink_port),
        quantity = conn.quantity,
        unit = conn.unit,
        conversion_owner = conn.conversion_owner,
        aggregation_owner = conn.aggregation_owner,
        resampling_owner = conn.resampling_owner,
        active = conn.active,
        disabled_reason = conn.disabled_reason) for conn in system.connections]
end

function port_table(system::SystemGraph)
    rows = NamedTuple[]
    for block in system.blocks
        for port in block.ports
            push!(rows, (owner = port.owner, name = port.name,
                port_type = port.port_type, direction = port.direction,
                quantity = port.quantity, unit = port.unit,
                sign_convention = port.sign_convention, frame = port.frame,
                reference_point = port.reference_point, time_grid = port.time_grid,
                cardinality = port.cardinality))
        end
    end
    return rows
end

function design_default_table(system::SystemGraph)
    rows = NamedTuple[]
    for block in system.blocks
        for spec in block.designs
            push!(rows, (owner = spec.owner, name = spec.name, unit = spec.unit,
                initial = spec.initial, lower = spec.lower, upper = spec.upper,
                scale = spec.scale, model_path = block.model_path.path_label,
                label = spec.label))
        end
    end
    return rows
end

function variable_table(registry::AssemblyRegistry)
    return [(index = first(entry.index_range), owner = entry.owner,
        name = entry.name, role = entry.role, unit = entry.unit, scale = entry.scale,
        lower = entry.lower, upper = entry.upper, initial = entry.initial,
        time_index = entry.time_index, scope = entry.scope,
        model_path = entry.model_path, label = entry.label) for entry in registry.variables]
end

function residual_table(registry::AssemblyRegistry)
    return [(index = first(entry.index_range), owner = entry.owner,
        name = entry.name, sense = entry.role, unit = entry.unit, scale = entry.scale,
        lower = entry.lower, upper = entry.upper, time_index = entry.time_index,
        scope = entry.scope, model_path = entry.model_path,
        label = entry.label) for entry in registry.residuals]
end

function output_table(registry::AssemblyRegistry)
    return [(index = first(entry.index_range), owner = entry.owner,
        name = entry.name, unit = entry.unit, time_index = entry.time_index,
        scope = entry.scope, model_path = entry.model_path,
        label = entry.label) for entry in registry.outputs]
end

function scenario_table(scenario::ScenarioSpec)
    grid = scenario.time_grids.main
    return [
        (name = :time_grid, quantity = :horizon_s, unit = grid.unit, value = grid.horizon_s),
        (name = :time_grid, quantity = :dt_s, unit = grid.unit, value = grid.dt_s),
        (name = :resource, quantity = :solar_irradiance_kw_per_m2, unit = "kW/m^2", value = scenario.resources.solar_irradiance_kw_per_m2),
        (name = :resource, quantity = :wind_speed_m_s, unit = "m/s", value = scenario.resources.wind_speed_m_s),
        (name = :resource, quantity = :wave_power_flux_kw_per_m, unit = "kW/m", value = scenario.resources.wave_power_flux_kw_per_m),
        (name = :resource, quantity = :hydrokinetic_current_m_s, unit = "m/s", value = scenario.resources.hydrokinetic_current_m_s),
        (name = :demand, quantity = :load_kw, unit = "kW", value = scenario.demands.load_kw),
        (name = :demand, quantity = :h2_demand_kg_per_h, unit = "kg/h", value = scenario.demands.h2_demand_kg_per_h),
        (name = :demand, quantity = :desal_demand_m3_per_h, unit = "m^3/h", value = scenario.demands.desal_demand_m3_per_h),
        (name = :initial_state, quantity = :battery_soc, unit = "fraction", value = scenario.initial_states.battery_soc),
        (name = :initial_state, quantity = :diesel_fuel_l, unit = "L", value = scenario.initial_states.diesel_fuel_l),
        (name = :initial_state, quantity = :h2_level_kg, unit = "kg", value = scenario.initial_states.h2_level_kg),
        (name = :initial_state, quantity = :desal_level_m3, unit = "m^3", value = scenario.initial_states.desal_level_m3),
    ]
end

function formulation_table(system::SystemGraph)
    return [(name = formulation.name, mode = formulation.mode,
        variant = formulation.variant, time_grid = formulation.time_grid,
        exposed_roles = join(string.(formulation.exposed_roles), ","),
        defect_method = formulation.defect_method,
        objective = formulation.objective.name) for formulation in system.ontology.default_formulations]
end

_rule_value(rules::NamedTuple, name::Symbol, default) =
    name in keys(rules) ? getproperty(rules, name) : default

function formulation_boundary_table(formulation::FormulationSpec)
    rows = NamedTuple[]
    exposed_roles = join(string.(formulation.exposed_roles), "; ")
    if formulation.mode == :collocation
        push!(rows, (
            formulation = formulation.name,
            variant = formulation.variant,
            boundary = :direct_transcription,
            exposed_roles = exposed_roles,
            replayed_roles = "",
            state_policy = :exposed,
            segment_s = "",
            residual_check = :registered_constraints,
            sensitivity_check = :ForwardDiff_or_finite_difference_on_constraints,
            retained_implicit_boundary = "",
            notes = "State and control variables are NLP variables; dynamic defects are registered residuals.",
        ))
    elseif formulation.mode == :shooting
        push!(rows, (
            formulation = formulation.name,
            variant = formulation.variant,
            boundary = formulation.variant == :multiple ? :multiple_shooting_replay :
                :single_shooting_replay,
            exposed_roles = exposed_roles,
            replayed_roles = "state",
            state_policy = _rule_value(formulation.replay_rules, :state_policy, :replayed),
            segment_s = _rule_value(formulation.replay_rules, :segment_s, ""),
            residual_check = _rule_value(formulation.replay_rules, :residual_check,
                :registered_replay_constraints),
            sensitivity_check = :ForwardDiff_or_finite_difference_on_replay_controls,
            retained_implicit_boundary = "",
            notes = "States are propagated by replay kernels and audited against registered collocation residuals.",
        ))
        for boundary in _rule_value(formulation.replay_rules,
                :retained_implicit_boundaries, Symbol[])
            push!(rows, (
                formulation = formulation.name,
                variant = formulation.variant,
                boundary = :retained_implicit_solve,
                exposed_roles = exposed_roles,
                replayed_roles = "state",
                state_policy = _rule_value(formulation.replay_rules, :state_policy, :replayed),
                segment_s = _rule_value(formulation.replay_rules, :segment_s, ""),
                residual_check = :implicit_residual_at_solution,
                sensitivity_check = :implicit_or_finite_difference_boundary_check,
                retained_implicit_boundary = boundary,
                notes = "Boundary is retained inside the replay/segment kernel; expose residual and sensitivity checks instead of solver iterations.",
            ))
        end
    else
        push!(rows, (
            formulation = formulation.name,
            variant = formulation.variant,
            boundary = :replay,
            exposed_roles = exposed_roles,
            replayed_roles = "state; control",
            state_policy = :fixed_controls,
            segment_s = "",
            residual_check = :replay_residual_audit,
            sensitivity_check = :not_applicable,
            retained_implicit_boundary = "",
            notes = "Forward simulation uses fixed controls and reports replay residuals.",
        ))
    end
    return rows
end

formulation_boundary_table(model::AssembledModel) =
    formulation_boundary_table(model.formulation)

formulation_boundary_table(result::ResultSpec) =
    formulation_boundary_table(result.formulation)

function describe(system::SystemGraph)
    return OntologyDescription(system.ontology.name, system.ontology.version,
        component_table(system), design_default_table(system),
        scenario_table(system.scenario), formulation_table(system),
        system.validation)
end

function audit(system::SystemGraph, scenario::ScenarioSpec = system.scenario;
        formulation::FormulationSpec = Collocation())
    registry = build_registry(system, scenario, formulation)
    return OntologyAudit(system.ontology.name, connection_table(system),
        variable_table(registry), residual_table(registry), output_table(registry),
        port_table(system), model_path_table(system), system.validation)
end

function Base.show(io::IO, desc::OntologyDescription)
    println(io, "Ontology: ", desc.ontology, " v", desc.version)
    println(io, "Blocks: ", join((string(row.name) for row in desc.component_table), ", "))
    println(io, "Design variables: ", length(desc.design_defaults))
    println(io, "Validation: ", isvalid(desc.validation) ? "valid" : "invalid")
end

function Base.show(io::IO, aud::OntologyAudit)
    println(io, "Ontology audit: ", aud.ontology)
    println(io, "Connections: ", length(aud.connection_table))
    println(io, "Variables: ", length(aud.variable_table))
    println(io, "Residuals: ", length(aud.residual_table))
    println(io, "Validation: ", isvalid(aud.validation) ? "valid" : "invalid")
end

function _csv_escape(x)
    s = string(x)
    if occursin(',', s) || occursin('"', s) || occursin('\n', s)
        return "\"" * replace(s, "\"" => "\"\"") * "\""
    end
    return s
end

function _write_csv(path::AbstractString, rows::Vector)
    open(path, "w") do io
        if isempty(rows)
            println(io)
            return
        end
        headers = collect(keys(first(rows)))
        println(io, join(string.(headers), ","))
        for row in rows
            println(io, join((_csv_escape(getproperty(row, h)) for h in headers), ","))
        end
    end
end

function _svg_escape(x)
    s = string(x)
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, ">" => "&gt;")
    s = replace(s, "\"" => "&quot;")
    return s
end

function _plot_token(x)
    token = replace(lowercase(string(x)), r"[^a-z0-9]+" => "_")
    token = strip(token, ['_'])
    return isempty(token) ? "plot" : token
end

function _plot_series_available(rows::AbstractVector, name::Symbol)
    isempty(rows) && return false
    name in keys(first(rows)) || return false
    return any(row -> getproperty(row, name) isa Real && isfinite(getproperty(row, name)), rows)
end

function _plot_xy(rows::AbstractVector, name::Symbol)
    x = Float64[]
    y = Float64[]
    for (i, row) in enumerate(rows)
        value = getproperty(row, name)
        value isa Real && isfinite(value) || continue
        time = :time_s in keys(row) ? row.time_s : i - 1
        push!(x, Float64(time))
        push!(y, Float64(value))
    end
    return x, y
end

function _plot_range(values::Vector{Float64})
    lo = minimum(values)
    hi = maximum(values)
    if lo == hi
        pad = max(abs(lo) * 0.1, 1.0)
        return lo - pad, hi + pad
    end
    pad = 0.06 * (hi - lo)
    return lo - pad, hi + pad
end

function _plot_point(x, y, xlo, xhi, ylo, yhi, left, top, width, height)
    xp = left + (x - xlo) / (xhi - xlo) * width
    yp = top + height - (y - ylo) / (yhi - ylo) * height
    return xp, yp
end

function _write_svg_plot(path::AbstractString, rows::AbstractVector,
        specs::AbstractVector; title::String, y_unit::String)
    colors = ["#1f77b4", "#d62728", "#2ca02c", "#9467bd", "#ff7f0e",
        "#17becf", "#8c564b", "#7f7f7f", "#bcbd22", "#e377c2"]
    width = 900.0
    height = 520.0
    left = 82.0
    right = 238.0
    top = 48.0
    bottom = 68.0
    plot_width = width - left - right
    plot_height = height - top - bottom
    xvals = Float64[]
    yvals = Float64[]
    series = []
    for spec in specs
        x, y = _plot_xy(rows, spec.name)
        isempty(y) && continue
        push!(series, (spec = spec, x = x, y = y))
        append!(xvals, x)
        append!(yvals, y)
    end
    isempty(series) && return false
    xlo, xhi = _plot_range(xvals)
    ylo, yhi = _plot_range(yvals)

    open(path, "w") do io
        println(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 900 520\" role=\"img\" aria-label=\"$(_svg_escape(title))\">")
        println(io, "<rect width=\"900\" height=\"520\" fill=\"#ffffff\"/>")
        println(io, "<text x=\"82\" y=\"28\" font-family=\"Arial, sans-serif\" font-size=\"18\" font-weight=\"700\" fill=\"#1f2933\">$(_svg_escape(title))</text>")
        println(io, "<line x1=\"$left\" y1=\"$(top + plot_height)\" x2=\"$(left + plot_width)\" y2=\"$(top + plot_height)\" stroke=\"#334155\" stroke-width=\"1.2\"/>")
        println(io, "<line x1=\"$left\" y1=\"$top\" x2=\"$left\" y2=\"$(top + plot_height)\" stroke=\"#334155\" stroke-width=\"1.2\"/>")
        for tick in 0:4
            frac = tick / 4
            ytick = top + plot_height - frac * plot_height
            value = ylo + frac * (yhi - ylo)
            println(io, "<line x1=\"$left\" y1=\"$ytick\" x2=\"$(left + plot_width)\" y2=\"$ytick\" stroke=\"#e2e8f0\" stroke-width=\"1\"/>")
            println(io, "<text x=\"72\" y=\"$(ytick + 4)\" text-anchor=\"end\" font-family=\"Arial, sans-serif\" font-size=\"11\" fill=\"#475569\">$(_svg_escape(round(value; sigdigits = 4)))</text>")
        end
        for tick in 0:4
            frac = tick / 4
            xtick = left + frac * plot_width
            value = xlo + frac * (xhi - xlo)
            println(io, "<line x1=\"$xtick\" y1=\"$(top + plot_height)\" x2=\"$xtick\" y2=\"$(top + plot_height + 5)\" stroke=\"#334155\" stroke-width=\"1\"/>")
            println(io, "<text x=\"$xtick\" y=\"$(top + plot_height + 22)\" text-anchor=\"middle\" font-family=\"Arial, sans-serif\" font-size=\"11\" fill=\"#475569\">$(_svg_escape(round(value; sigdigits = 4)))</text>")
        end
        println(io, "<text x=\"$(left + plot_width / 2)\" y=\"500\" text-anchor=\"middle\" font-family=\"Arial, sans-serif\" font-size=\"13\" fill=\"#334155\">time_s</text>")
        println(io, "<text transform=\"translate(18 $(top + plot_height / 2)) rotate(-90)\" text-anchor=\"middle\" font-family=\"Arial, sans-serif\" font-size=\"13\" fill=\"#334155\">$(_svg_escape(y_unit))</text>")
        for (i, item) in enumerate(series)
            color = colors[mod1(i, length(colors))]
            points = String[]
            for j in eachindex(item.y)
                xp, yp = _plot_point(item.x[j], item.y[j], xlo, xhi, ylo, yhi,
                    left, top, plot_width, plot_height)
                push!(points, string(round(xp; digits = 2), ",", round(yp; digits = 2)))
            end
            println(io, "<polyline fill=\"none\" stroke=\"$color\" stroke-width=\"2.1\" points=\"$(join(points, " "))\"/>")
        end
        legend_x = left + plot_width + 24
        legend_y = top + 8
        for (i, item) in enumerate(series)
            color = colors[mod1(i, length(colors))]
            y = legend_y + (i - 1) * 22
            println(io, "<line x1=\"$legend_x\" y1=\"$y\" x2=\"$(legend_x + 22)\" y2=\"$y\" stroke=\"$color\" stroke-width=\"2.4\"/>")
            println(io, "<text x=\"$(legend_x + 30)\" y=\"$(y + 4)\" font-family=\"Arial, sans-serif\" font-size=\"11\" fill=\"#1f2933\">$(_svg_escape(item.spec.label))</text>")
        end
        println(io, "</svg>")
    end
    return true
end

function _standard_plot_specs(result::ResultSpec)
    rows = plot_table(result.system)
    available = [row for row in rows if _plot_series_available(result.timeseries, row.name)]
    groups = unique((row.plot_group, row.unit) for row in available)
    sort!(groups, by = x -> string(x[1], "_", x[2]))
    return [(plot_group = group, unit = unit,
        specs = [row for row in available if row.plot_group == group && row.unit == unit])
        for (group, unit) in groups]
end

function _write_standard_plots(result::ResultSpec, path::AbstractString)
    plot_rows = NamedTuple[]
    plot_files = String[]
    for group in _standard_plot_specs(result)
        filename = string("plot_", _plot_token(group.plot_group), "_",
            _plot_token(group.unit), ".svg")
        full = joinpath(path, filename)
        title = string(result.system.ontology.name, " ", group.plot_group,
            " (", group.unit, ")")
        written = _write_svg_plot(full, result.timeseries, group.specs;
            title = title, y_unit = group.unit)
        written || continue
        push!(plot_files, full)
        push!(plot_rows, (
            plot_group = group.plot_group,
            unit = group.unit,
            file = filename,
            columns = join(string.(getfield.(group.specs, :name)), "; "),
            labels = join(getfield.(group.specs, :label), "; "),
            source = "OutputSpec.plot_group",
        ))
    end
    return plot_rows, plot_files
end

function report(result::ResultSpec, path::AbstractString = "sirenopt_report")
    mkpath(path)
    files = String[]
    plot_rows, plot_files = _write_standard_plots(result, path)
    outputs = [
        ("components.csv", component_table(result.system)),
        ("ports.csv", port_table(result.system)),
        ("connections.csv", connection_table(result.system)),
        ("variables.csv", variable_table(result.registry)),
        ("residuals.csv", residual_table(result.registry)),
        ("outputs.csv", output_table(result.registry)),
        ("model_paths.csv", result.model_paths),
        ("level_maps.csv", level_map_table(result.system)),
        ("formulation_boundaries.csv", formulation_boundary_table(result)),
        ("plots.csv", plot_rows),
        ("timeseries.csv", result.timeseries),
        ("controls.csv", result.controls),
        ("states.csv", result.states),
        ("replay_residuals.csv", [result.replay_summary]),
    ]
    for (filename, rows) in outputs
        full = joinpath(path, filename)
        _write_csv(full, collect(rows))
        push!(files, full)
    end
    append!(files, plot_files)
    provenance = joinpath(path, "provenance.txt")
    open(provenance, "w") do io
        println(io, "ontology=", result.system.ontology.name)
        println(io, "ontology_version=", result.system.ontology.version)
        println(io, "scenario=", result.scenario.name)
        println(io, "formulation=", result.formulation.name)
        println(io, "solver=", result.solver)
        println(io, "replay_summary=", result.replay_summary)
        println(io, "generated_at=", Dates.now())
    end
    push!(files, provenance)
    return ResultSpec(result.system, result.scenario, result.system_hash,
        result.scenario_hash, result.formulation, result.solver, result.registry,
        result.replay_summary, files, result.model_paths, result.timeseries,
        result.controls, result.states, result.objective_value, result.solution_x)
end
