Base.@kwdef struct TimeSeries{T,TT<:AbstractVector{<:Real},TV<:AbstractVector{T}}
    t::TT
    values::TV
end

Base.length(ts::TimeSeries) = length(ts.t)

# -------------------------
# SIRENO-Lite-aligned defaults (mapped to SIRENOpt units)
# -------------------------

const SIRENOLITE_DEFAULT_SOLAR_EFFICIENCY = 0.2
const SIRENOLITE_DEFAULT_SOLAR_AREA = 250.0
const SIRENOLITE_DEFAULT_SOLAR_MASS_PER_AREA = 14.0
const SIRENOLITE_DEFAULT_SOLAR_COST_PER_AREA = 334.0

const SIRENOLITE_DEFAULT_WIND_ROTOR_DIAMETER = 20.0
const SIRENOLITE_DEFAULT_WIND_CP = 0.45
const SIRENOLITE_DEFAULT_WIND_CUT_IN = 3.0
const SIRENOLITE_DEFAULT_WIND_CUT_OUT = 25.0
const SIRENOLITE_DEFAULT_WIND_RATED_SPEED = 12.0
const SIRENOLITE_DEFAULT_WIND_RATED_POWER = 50.0
const SIRENOLITE_DEFAULT_WIND_MASS = 1500.0
const SIRENOLITE_DEFAULT_WIND_COST = 200000.0

const SIRENOLITE_DEFAULT_HYDROKINETIC_ROTOR_DIAMETER = 5.0
const SIRENOLITE_DEFAULT_HYDROKINETIC_CP = 0.4
const SIRENOLITE_DEFAULT_HYDROKINETIC_CUT_IN = 0.5
const SIRENOLITE_DEFAULT_HYDROKINETIC_CUT_OUT = 4.0
const SIRENOLITE_DEFAULT_HYDROKINETIC_RATED_SPEED = 2.0
const SIRENOLITE_DEFAULT_HYDROKINETIC_RATED_POWER = 0.0
const SIRENOLITE_DEFAULT_HYDROKINETIC_MASS = 0.0
const SIRENOLITE_DEFAULT_HYDROKINETIC_COST = 0.0

const SIRENOLITE_DEFAULT_WAVE_CAPTURE_WIDTH = 50.0
const SIRENOLITE_DEFAULT_WAVE_RATED_POWER = 50.0
const SIRENOLITE_DEFAULT_WAVE_MASS = 4000.0
const SIRENOLITE_DEFAULT_WAVE_COST = 100000.0

const SIRENOLITE_DEFAULT_DIESEL_RATED_POWER = 50.0
const SIRENOLITE_DEFAULT_DIESEL_EFFICIENCY = 1.0
const SIRENOLITE_DEFAULT_DIESEL_FUEL_PER_KWH = 1.0 / (44.0 * 0.2)
const SIRENOLITE_DEFAULT_DIESEL_TANK_CAPACITY = 50.0
const SIRENOLITE_DEFAULT_DIESEL_FILL_PERIOD_HOURS = 24.0
const SIRENOLITE_DEFAULT_DIESEL_MASS = 1500.0
const SIRENOLITE_DEFAULT_DIESEL_COST = 20000.0

const SIRENOLITE_DEFAULT_GEN_RATED_POWER = 50.0
const SIRENOLITE_DEFAULT_GEN_EFFICIENCY = 1.0

const SIRENOLITE_DEFAULT_CONV_RATED_POWER = 50.0
const SIRENOLITE_DEFAULT_CONV_EFFICIENCY = 1.0

const SIRENOLITE_DEFAULT_BATT_CAPACITY_KWH = 1.44
const SIRENOLITE_DEFAULT_BATT_EFFICIENCY = sqrt(0.9)
const SIRENOLITE_DEFAULT_BATT_MASS = 11520.0
const SIRENOLITE_DEFAULT_BATT_COST = 230.4

const SIRENOLITE_DEFAULT_H2_ELECTROLYZER_POWER = 2.5
const SIRENOLITE_DEFAULT_H2_TANK_CAPACITY = 100.0
const SIRENOLITE_DEFAULT_H2_SPECIFIC_ENERGY = 65.0
const SIRENOLITE_DEFAULT_H2_MASS = 1000.0
const SIRENOLITE_DEFAULT_H2_COST = 100000.0

const SIRENOLITE_DEFAULT_DESAL_POWER = 1.0
const SIRENOLITE_DEFAULT_DESAL_TANK_CAPACITY = 100.0
const SIRENOLITE_DEFAULT_DESAL_SPECIFIC_ENERGY = 4.5
const SIRENOLITE_DEFAULT_DESAL_MASS = 5000.0
const SIRENOLITE_DEFAULT_DESAL_COST = 50000.0

const SIRENOLITE_DEFAULT_PLATFORM_BASE_MASS = 8406.0
const SIRENOLITE_DEFAULT_PLATFORM_COST = 252180.0

"""Return index k such that ts.t[k] <= t < ts.t[k+1] (clamped)."""
function time_index(ts::TimeSeries, t::Real)
    k = searchsortedlast(ts.t, t)
    return smooth_clamp_index(k, 1, length(ts.values))
end

"""Return the value at index k (1-based, clamped to bounds)."""
function value_at(ts::TimeSeries, k::Int)
    k_clamped = smooth_clamp_index(k, 1, length(ts.values))
    return ts.values[k_clamped]
end

Base.@kwdef struct SolarDesign{T<:Real}
    area::T = T(SIRENOLITE_DEFAULT_SOLAR_AREA)
    efficiency::T = T(SIRENOLITE_DEFAULT_SOLAR_EFFICIENCY)
    mass_per_area::T = T(SIRENOLITE_DEFAULT_SOLAR_MASS_PER_AREA)
    volume_per_area::T = zero(T)
    cost_per_area::T = T(SIRENOLITE_DEFAULT_SOLAR_COST_PER_AREA)
    pv_model::Any = nothing
end

Base.@kwdef struct SolarOp{T<:Real}
    resource::TimeSeries = TimeSeries([zero(T)], [zero(T)])
    curtailment::T = zero(T)
    pv_weather::Any = nothing
    pv_solar_position::Any = nothing
end

Base.@kwdef struct WindDesign{T<:Real}
    rotor_diameter::T = T(SIRENOLITE_DEFAULT_WIND_ROTOR_DIAMETER)
    cp::T = T(SIRENOLITE_DEFAULT_WIND_CP)
    cut_in::T = T(SIRENOLITE_DEFAULT_WIND_CUT_IN)
    cut_out::T = T(SIRENOLITE_DEFAULT_WIND_CUT_OUT)
    rated_speed::T = T(SIRENOLITE_DEFAULT_WIND_RATED_SPEED)
    rated_power::T = T(SIRENOLITE_DEFAULT_WIND_RATED_POWER)
    mass::T = T(SIRENOLITE_DEFAULT_WIND_MASS)
    volume::T = zero(T)
    cost::T = T(SIRENOLITE_DEFAULT_WIND_COST)
    rotor_model::Any = nothing
end

Base.@kwdef struct WindOp{T<:Real}
    resource::TimeSeries = TimeSeries([zero(T)], [zero(T)])
    air_density::T = one(T)
    curtailment::T = zero(T)
end

Base.@kwdef struct WaveDesign{T<:Real}
    capture_width::T = T(SIRENOLITE_DEFAULT_WAVE_CAPTURE_WIDTH)
    rated_power::T = T(SIRENOLITE_DEFAULT_WAVE_RATED_POWER)
    mass::T = T(SIRENOLITE_DEFAULT_WAVE_MASS)
    volume::T = zero(T)
    cost::T = T(SIRENOLITE_DEFAULT_WAVE_COST)
end

Base.@kwdef struct WaveOp{T<:Real}
    resource::TimeSeries = TimeSeries([zero(T)], [zero(T)])
    curtailment::T = zero(T)
end

Base.@kwdef struct HydrokineticDesign{T<:Real}
    rotor_diameter::T = T(SIRENOLITE_DEFAULT_HYDROKINETIC_ROTOR_DIAMETER)
    cp::T = T(SIRENOLITE_DEFAULT_HYDROKINETIC_CP)
    cut_in::T = T(SIRENOLITE_DEFAULT_HYDROKINETIC_CUT_IN)
    cut_out::T = T(SIRENOLITE_DEFAULT_HYDROKINETIC_CUT_OUT)
    rated_speed::T = T(SIRENOLITE_DEFAULT_HYDROKINETIC_RATED_SPEED)
    rated_power::T = T(SIRENOLITE_DEFAULT_HYDROKINETIC_RATED_POWER)
    mass::T = T(SIRENOLITE_DEFAULT_HYDROKINETIC_MASS)
    volume::T = zero(T)
    cost::T = T(SIRENOLITE_DEFAULT_HYDROKINETIC_COST)
    rotor_model::Any = nothing
end

Base.@kwdef struct HydrokineticOp{T<:Real}
    resource::TimeSeries = TimeSeries([zero(T)], [zero(T)])
    fluid_density::T = T(1025)
    curtailment::T = zero(T)
end

Base.@kwdef struct DieselDesign{T<:Real}
    rated_power::T = T(SIRENOLITE_DEFAULT_DIESEL_RATED_POWER)
    min_power::T = zero(T)
    efficiency::T = T(SIRENOLITE_DEFAULT_DIESEL_EFFICIENCY)
    fuel_per_kwh::T = T(SIRENOLITE_DEFAULT_DIESEL_FUEL_PER_KWH)
    fuel_tank_capacity::T = T(SIRENOLITE_DEFAULT_DIESEL_TANK_CAPACITY)
    fill_period_hours::T = T(SIRENOLITE_DEFAULT_DIESEL_FILL_PERIOD_HOURS)
    mass::T = T(SIRENOLITE_DEFAULT_DIESEL_MASS)
    volume::T = zero(T)
    cost::T = T(SIRENOLITE_DEFAULT_DIESEL_COST)
    engine_model::Any = nothing
end

Base.@kwdef struct DieselOp{T<:Real}
    fuel_level::T = one(T)
    availability::T = one(T)
end

Base.@kwdef struct GeneratorDesign{T<:Real}
    rated_power::T = T(SIRENOLITE_DEFAULT_GEN_RATED_POWER)
    efficiency::T = T(SIRENOLITE_DEFAULT_GEN_EFFICIENCY)
    mass::T = zero(T)
    volume::T = zero(T)
    cost::T = zero(T)
    generator_model::Any = nothing
end

Base.@kwdef struct GeneratorOp{T<:Real}
    availability::T = one(T)
end

Base.@kwdef struct ConverterDesign{T<:Real}
    rated_power::T = T(SIRENOLITE_DEFAULT_CONV_RATED_POWER)
    efficiency::T = T(SIRENOLITE_DEFAULT_CONV_EFFICIENCY)
    bi_directional::Bool = false
    mass::T = zero(T)
    volume::T = zero(T)
    cost::T = zero(T)
    converter_model::Any = nothing
end

Base.@kwdef struct ConverterOp{T<:Real}
    availability::T = one(T)
end

Base.@kwdef struct BatteryDesign{T<:Real}
    capacity_kwh::T = T(SIRENOLITE_DEFAULT_BATT_CAPACITY_KWH)
    max_charge_kw::T = T(SIRENOLITE_DEFAULT_BATT_CAPACITY_KWH)
    max_discharge_kw::T = T(SIRENOLITE_DEFAULT_BATT_CAPACITY_KWH)
    charge_efficiency::T = T(SIRENOLITE_DEFAULT_BATT_EFFICIENCY)
    discharge_efficiency::T = T(SIRENOLITE_DEFAULT_BATT_EFFICIENCY)
    reserve_soc::T = zero(T)
    mass::T = T(SIRENOLITE_DEFAULT_BATT_MASS)
    volume::T = zero(T)
    cost::T = T(SIRENOLITE_DEFAULT_BATT_COST)
    storage_model::Any = nothing
end

Base.@kwdef struct BatteryOp{T<:Real}
    soc_init::T = one(T)
end

Base.@kwdef struct H2Design{T<:Real}
    electrolyzer_power_kw::T = T(SIRENOLITE_DEFAULT_H2_ELECTROLYZER_POWER)
    tank_capacity_kg::T = T(SIRENOLITE_DEFAULT_H2_TANK_CAPACITY)
    specific_energy_kwh_per_kg::T = T(SIRENOLITE_DEFAULT_H2_SPECIFIC_ENERGY)
    mass::T = T(SIRENOLITE_DEFAULT_H2_MASS)
    volume::T = zero(T)
    cost::T = T(SIRENOLITE_DEFAULT_H2_COST)
    h2_model::Any = nothing
end

Base.@kwdef struct H2Op{T<:Real}
    tank_level_kg::T = zero(T)
    demand::TimeSeries = TimeSeries([zero(T)], [zero(T)])
end

Base.@kwdef struct DesalDesign{T<:Real}
    plant_power_kw::T = T(SIRENOLITE_DEFAULT_DESAL_POWER)
    tank_capacity_m3::T = T(SIRENOLITE_DEFAULT_DESAL_TANK_CAPACITY)
    specific_energy_kwh_per_m3::T = T(SIRENOLITE_DEFAULT_DESAL_SPECIFIC_ENERGY)
    mass::T = T(SIRENOLITE_DEFAULT_DESAL_MASS)
    volume::T = zero(T)
    cost::T = T(SIRENOLITE_DEFAULT_DESAL_COST)
    desal_model::Any = nothing
end

Base.@kwdef struct DesalOp{T<:Real}
    tank_level_m3::T = zero(T)
    demand::TimeSeries = TimeSeries([zero(T)], [zero(T)])
end

Base.@kwdef struct LoadDesign{T<:Real}
    critical_fraction::T = one(T)
    mass::T = zero(T)
    volume::T = zero(T)
    cost::T = zero(T)
end

Base.@kwdef struct LoadOp{T<:Real}
    demand::TimeSeries = TimeSeries([zero(T)], [zero(T)])
end

Base.@kwdef struct BusDesign{T<:Real}
    voltage_nominal::T = one(T)
    voltage_min::T = zero(T)
    voltage_max::T = one(T)
    droop_gain::T = zero(T)
end

Base.@kwdef struct PlatformDesign{T<:Real}
    base_mass::T = T(SIRENOLITE_DEFAULT_PLATFORM_BASE_MASS)
    base_volume::T = zero(T)
    payload_mass::T = zero(T)
    payload_volume::T = zero(T)
    mass_margin::T = zero(T)
    volume_margin::T = zero(T)
    waterplane_area::T = one(T)
    damping::T = one(T)
    cost::T = T(SIRENOLITE_DEFAULT_PLATFORM_COST)
    hydrodynamic_model::Any = nothing
    mooring_model::Any = nothing
end

Base.@kwdef struct PlatformOp{T<:Real}
    external_force::TimeSeries = TimeSeries([zero(T)], [zero(T)])
    external_wrench::Any = nothing
    wave_components::Any = nothing
    direction_mode::Symbol = :exact
    validate_hydrodynamic_coefficients::Bool = false
    max_relative_hydrodynamic_coefficient_change::T = T(Inf)
    coefficient_diagnostic_callback::Any = nothing
    throw_on_hydrodynamic_coefficient_diagnostic::Bool = false
end

Base.@kwdef struct PlatformState{T<:Real}
    position::T = zero(T)
    velocity::T = zero(T)
    acceleration::T = zero(T)
end

Base.@kwdef struct ControllerDesign{T<:Real}
    voltage_deadband::T = zero(T)
    battery_reserve_soc::T = T(0.5)
    prediction_window_hours::T = T(24)
    conservative_fraction::T = T(0.7)
    diesel_ration_hours::T = T(24)
end

Base.@kwdef struct ControllerState{T<:Real}
    diesel_fuel_used_in_period::T = zero(T)
end

Base.@kwdef struct ControlSetpoints{T<:Real}
    solar_curtailment::T = 0.0
    wind_curtailment::T = 0.0
    wave_curtailment::T = 0.0
    hydrokinetic_curtailment::T = 0.0
    load_served_fraction::T = 1.0
    diesel_power_kw::T = 0.0
    battery_power_kw::T = 0.0
    h2_power_kw::T = 0.0
    desal_power_kw::T = 0.0
end

Base.@kwdef struct SystemDesign{T<:Real}
    solar::SolarDesign{T} = SolarDesign{T}()
    wind::WindDesign{T} = WindDesign{T}()
    wave::WaveDesign{T} = WaveDesign{T}()
    hydrokinetic::HydrokineticDesign{T} = HydrokineticDesign{T}()
    diesel::DieselDesign{T} = DieselDesign{T}()
    solar_gen::GeneratorDesign{T} = GeneratorDesign{T}()
    wind_gen::GeneratorDesign{T} = GeneratorDesign{T}()
    wave_gen::GeneratorDesign{T} = GeneratorDesign{T}()
    hydrokinetic_gen::GeneratorDesign{T} = GeneratorDesign{T}(; rated_power = zero(T))
    diesel_gen::GeneratorDesign{T} = GeneratorDesign{T}()
    solar_conv::ConverterDesign{T} = ConverterDesign{T}()
    wind_conv::ConverterDesign{T} = ConverterDesign{T}()
    wave_conv::ConverterDesign{T} = ConverterDesign{T}()
    hydrokinetic_conv::ConverterDesign{T} = ConverterDesign{T}(; rated_power = zero(T))
    diesel_conv::ConverterDesign{T} = ConverterDesign{T}()
    battery::BatteryDesign{T} = BatteryDesign{T}()
    battery_conv::ConverterDesign{T} = ConverterDesign{T}(; bi_directional=true)
    h2::H2Design{T} = H2Design{T}()
    h2_conv::ConverterDesign{T} = ConverterDesign{T}()
    desal::DesalDesign{T} = DesalDesign{T}()
    desal_conv::ConverterDesign{T} = ConverterDesign{T}()
    load::LoadDesign{T} = LoadDesign{T}()
    load_conv::ConverterDesign{T} = ConverterDesign{T}()
    bus::BusDesign{T} = BusDesign{T}()
    platform::PlatformDesign{T} = PlatformDesign{T}()
    controller::ControllerDesign{T} = ControllerDesign{T}()
end

Base.@kwdef struct SystemOperation{T<:Real}
    solar::SolarOp{T} = SolarOp{T}()
    wind::WindOp{T} = WindOp{T}()
    wave::WaveOp{T} = WaveOp{T}()
    hydrokinetic::HydrokineticOp{T} = HydrokineticOp{T}()
    diesel::DieselOp{T} = DieselOp{T}()
    solar_gen::GeneratorOp{T} = GeneratorOp{T}()
    wind_gen::GeneratorOp{T} = GeneratorOp{T}()
    wave_gen::GeneratorOp{T} = GeneratorOp{T}()
    hydrokinetic_gen::GeneratorOp{T} = GeneratorOp{T}()
    diesel_gen::GeneratorOp{T} = GeneratorOp{T}()
    solar_conv::ConverterOp{T} = ConverterOp{T}()
    wind_conv::ConverterOp{T} = ConverterOp{T}()
    wave_conv::ConverterOp{T} = ConverterOp{T}()
    hydrokinetic_conv::ConverterOp{T} = ConverterOp{T}()
    diesel_conv::ConverterOp{T} = ConverterOp{T}()
    battery::BatteryOp{T} = BatteryOp{T}()
    battery_conv::ConverterOp{T} = ConverterOp{T}()
    h2::H2Op{T} = H2Op{T}()
    h2_conv::ConverterOp{T} = ConverterOp{T}()
    desal::DesalOp{T} = DesalOp{T}()
    desal_conv::ConverterOp{T} = ConverterOp{T}()
    load::LoadOp{T} = LoadOp{T}()
    load_conv::ConverterOp{T} = ConverterOp{T}()
    platform::PlatformOp{T} = PlatformOp{T}()
end

Base.@kwdef struct SystemState{T<:Real}
    time::T = zero(T)
    bus_voltage::T = one(T)
    battery_soc::T = one(T)
    diesel_fuel_level::T = one(T)
    h2_level_kg::T = zero(T)
    desal_level_m3::T = zero(T)
    controller::ControllerState{T} = ControllerState{T}()
    platform::Any = PlatformState{T}()
end

Base.@kwdef struct SystemOutputs{T<:Real}
    solar_power_kw::T = zero(T)
    wind_power_kw::T = zero(T)
    wave_power_kw::T = zero(T)
    hydrokinetic_power_kw::T = zero(T)
    diesel_power_kw::T = zero(T)
    battery_power_kw::T = zero(T)
    load_power_kw::T = zero(T)
    h2_power_kw::T = zero(T)
    desal_power_kw::T = zero(T)
    net_bus_power_kw::T = zero(T)
    bus_voltage::T = zero(T)
    diesel_fuel_used::T = zero(T)
    bus_balance_residual_kw::T = zero(T)
    battery_inventory_residual_kwh::T = zero(T)
    diesel_fuel_inventory_residual::T = zero(T)
    h2_inventory_residual_kg::T = zero(T)
    desal_inventory_residual_m3::T = zero(T)
end

Base.@kwdef struct ConstraintSpec{T<:Real}
    battery_only_hours::T = zero(T)
    battery_plus_renewables_hours::T = zero(T)
    full_system_hours::T = zero(T)
end

"""
Design variable descriptor used to map optimization vectors into the system design.
`name` uses a simple symbolic path (e.g. `:solar_area`, `:battery_capacity_kwh`).
"""
Base.@kwdef struct DesignVar{T<:Real}
    name::Symbol
    initial::T = zero(T)
    lower::T = -T(Inf)
    upper::T = T(Inf)
end

"""Container for ordered design variables and bounds."""
Base.@kwdef struct DesignVarSpec{T<:Real}
    vars::Vector{DesignVar{T}} = DesignVar{T}[]
end

"""Problem definition for SNOW-style objective/constraint callbacks."""
Base.@kwdef struct SnowProblem{T<:Real}
    base_design::SystemDesign{T} = SystemDesign{T}()
    operation::SystemOperation{T} = SystemOperation{T}()
    dt_hours::T = one(T)
    constraint_spec::ConstraintSpec{T} = ConstraintSpec{T}()
    objective_mode::Symbol = :dynamic
    single_point_index::Int = 1
    varspec::DesignVarSpec{T} = DesignVarSpec{T}()
end
