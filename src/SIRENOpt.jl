module SIRENOpt

using LinearAlgebra
using SparseArrays
using Statistics
using Dates
import UnsteadyKineticRotorDynamics
import Desal
import DimensionfulAngles
import DieselGen
import GeneratorSE
import H2Gen
import Hydrodynamics
import AgnosticStorageDynamics
import Mooring
import PVlib
import PowerConverterDynamics
import Unitful
import WaveSpectra

include("smooth.jl")
include("types.jl")
include("ccblade_interface.jl")
include("dieselgen_interface.jl")
include("electrical_interface.jl")
include("pvlib_interface.jl")
include("storage_interface.jl")
include("production_interface.jl")
include("hydrodynamics_interface.jl")
include("mooring_interface.jl")
include("hydrodynamics6dof_interface.jl")
include("wave_resource_interface.jl")
include("components_power.jl")
include("components_loads.jl")
include("controller.jl")
include("dynamics.jl")
include("system.jl")
include("simulate.jl")
include("ontology.jl")
include("optimization.jl")
include("snow_interface.jl")
include("latin_hypercube.jl")
include("resources.jl")

export TimeSeries, value_at, time_index
export SolarDesign, SolarOp, WindDesign, WindOp, WaveDesign, WaveOp
export HydrokineticDesign, HydrokineticOp
export CCBladeRotorModel, simple_ccblade_rotor_model, ccblade_rotor_power_kw
export diesel_engine_design, diesel_fuel_used
export GeneratorSEModel, generatorse_pmsg_arms_model, generatorse_output_kw
export PowerConverterModel, powerconverter_model, powerconverter_efficiency, powerconverter_output_kw
export PvlibSolarModel, pvlib_solar_model, pvlib_solar_dc_power_kw, pvlib_solar_ac_power_kw
export generic_storage_params, generic_storage_step
export h2gen_design, h2gen_step, desalination_design, desalination_step
export HydrodynamicPlatformModel, hydrodynamic_platform_model, hydrodynamic_platform_acceleration, hydrodynamic_dynamics_step
export MooringSystemModel, mooring_parameter_handler, mooring_system_model
export mooring_mass_kg, mooring_heave_stiffness_n_per_m, mooring_restoring_force
export mooring_setup_lines, mooring_quasistatic_solution
export wave_power_flux_kw_per_m, wave_spectrum_power_flux_kw_per_m, wave_resource_timeseries
export DieselDesign, DieselOp, GeneratorDesign, GeneratorOp
export ConverterDesign, ConverterOp, BatteryDesign, BatteryOp
export H2Design, H2Op, DesalDesign, DesalOp, LoadDesign, LoadOp
export BusDesign, PlatformDesign, PlatformOp, PlatformState
export Hydrodynamic6DOFPlatformModel, PlatformState6DOF
export hydrodynamics6dof_platform_model, hydrodynamics_wave_components, platform_state6dof
export ControllerDesign, ControllerState, ControlSetpoints
export SystemDesign, SystemOperation, SystemState, SystemOutputs
export ConstraintSpec
export DesignVar, DesignVarSpec, SnowProblem
export default_design_varspec, varspec_x0, varspec_bounds
export design_from_x, constraint_values!, constraint_count, snow_objective!
export smooth_abs, smooth_min, smooth_max, smooth_clamp, smooth_step, smooth_clamp_index
export DEFAULT_ABS_DELTA, DEFAULT_KS_HARDNESS
export power_available_solar, power_available_wind, power_available_wave
export power_available_hydrokinetic
export solar_power, wind_power, wave_power, hydrokinetic_power, diesel_power
export generator_output, converter_output
export load_demand, battery_step, h2_step, desal_step
export controller_step, smooth_controller_step
export platform_force, platform_wrench, force_residual, dynamics_step
export aggregate_mass_cost_volume, update_platform, platform_from_supported_mass
export plant_step, simulate_step, simulate, simulate!
export objective_single_point, objective_dynamic
export check_constraints
export latin_hypercube, lhyper
export read_sirenolite_resource_csv, short_horizon_profiles
export ModelPathSpec, ObjectiveSpec, ValidationReport, BlockRole, InterfaceSpec
export ReportSpec, VariableSpec, ResidualSpec, OutputSpec, PortSpec, ConnectionSpec
export BlockMetadata, BlockSpec, OntologyTemplate, TimeGrid, ScenarioSpec
export FormulationSpec, SystemGraph, AssemblyRegistry, RegistryEntry
export AssembledModel, ResultSpec, OntologyDescription, OntologyAudit
export AbstractSIRENBlock, BusBalanceBlock, block_name, design_variables
export state_variables, control_variables, ports, outputs, residuals
export evaluate!, residual!, record!
export Design, ShortHorizonScenario, Simulation, Collocation, Shooting
export RuleBasedController, MinimizeTotalCost, MinimizeCostPerWatt
export MinimalEnergyOntology, PackageBackedHybridOntology
export DynamicMultilevelHybridOntology, SIRENOLiteOntology, FullSIRENOptOntology
export validate_system, build_registry, assemble, solve, optimize, replay, report
export describe, audit, component_table, connection_table, port_table
export variable_table, residual_table, output_table, model_path_table
export level_map_table, plot_table, scenario_table, formulation_table
export formulation_boundary_table, objective_value
export evaluate_constraints

end
