_promoted_real_type(values...) = promote_type(map(typeof, values)...)

function _convert_design(design::SolarDesign, ::Type{T}) where {T<:Real}
    return SolarDesign{T}(
        area = convert(T, design.area),
        efficiency = convert(T, design.efficiency),
        mass_per_area = convert(T, design.mass_per_area),
        volume_per_area = convert(T, design.volume_per_area),
        cost_per_area = convert(T, design.cost_per_area),
        pv_model = design.pv_model,
    )
end

function _convert_design(design::WindDesign, ::Type{T}) where {T<:Real}
    return WindDesign{T}(
        rotor_diameter = convert(T, design.rotor_diameter),
        cp = convert(T, design.cp),
        cut_in = convert(T, design.cut_in),
        cut_out = convert(T, design.cut_out),
        rated_speed = convert(T, design.rated_speed),
        rated_power = convert(T, design.rated_power),
        mass = convert(T, design.mass),
        volume = convert(T, design.volume),
        cost = convert(T, design.cost),
        rotor_model = design.rotor_model,
    )
end

function _convert_design(design::WaveDesign, ::Type{T}) where {T<:Real}
    return WaveDesign{T}(
        capture_width = convert(T, design.capture_width),
        rated_power = convert(T, design.rated_power),
        mass = convert(T, design.mass),
        volume = convert(T, design.volume),
        cost = convert(T, design.cost),
    )
end

function _convert_design(design::HydrokineticDesign, ::Type{T}) where {T<:Real}
    return HydrokineticDesign{T}(
        rotor_diameter = convert(T, design.rotor_diameter),
        cp = convert(T, design.cp),
        cut_in = convert(T, design.cut_in),
        cut_out = convert(T, design.cut_out),
        rated_speed = convert(T, design.rated_speed),
        rated_power = convert(T, design.rated_power),
        mass = convert(T, design.mass),
        volume = convert(T, design.volume),
        cost = convert(T, design.cost),
        rotor_model = design.rotor_model,
    )
end

function _convert_design(design::DieselDesign, ::Type{T}) where {T<:Real}
    return DieselDesign{T}(
        rated_power = convert(T, design.rated_power),
        min_power = convert(T, design.min_power),
        efficiency = convert(T, design.efficiency),
        fuel_per_kwh = convert(T, design.fuel_per_kwh),
        fuel_tank_capacity = convert(T, design.fuel_tank_capacity),
        fill_period_hours = convert(T, design.fill_period_hours),
        mass = convert(T, design.mass),
        volume = convert(T, design.volume),
        cost = convert(T, design.cost),
        engine_model = design.engine_model,
    )
end

function _convert_design(design::GeneratorDesign, ::Type{T}) where {T<:Real}
    return GeneratorDesign{T}(
        rated_power = convert(T, design.rated_power),
        efficiency = convert(T, design.efficiency),
        mass = convert(T, design.mass),
        volume = convert(T, design.volume),
        cost = convert(T, design.cost),
        generator_model = design.generator_model,
    )
end

function _convert_design(design::ConverterDesign, ::Type{T}) where {T<:Real}
    return ConverterDesign{T}(
        rated_power = convert(T, design.rated_power),
        efficiency = convert(T, design.efficiency),
        bi_directional = design.bi_directional,
        mass = convert(T, design.mass),
        volume = convert(T, design.volume),
        cost = convert(T, design.cost),
        converter_model = design.converter_model,
    )
end

function _convert_design(design::BatteryDesign, ::Type{T}) where {T<:Real}
    return BatteryDesign{T}(
        capacity_kwh = convert(T, design.capacity_kwh),
        max_charge_kw = convert(T, design.max_charge_kw),
        max_discharge_kw = convert(T, design.max_discharge_kw),
        charge_efficiency = convert(T, design.charge_efficiency),
        discharge_efficiency = convert(T, design.discharge_efficiency),
        reserve_soc = convert(T, design.reserve_soc),
        mass = convert(T, design.mass),
        volume = convert(T, design.volume),
        cost = convert(T, design.cost),
        storage_model = design.storage_model,
    )
end

function _convert_design(design::H2Design, ::Type{T}) where {T<:Real}
    return H2Design{T}(
        electrolyzer_power_kw = convert(T, design.electrolyzer_power_kw),
        tank_capacity_kg = convert(T, design.tank_capacity_kg),
        specific_energy_kwh_per_kg = convert(T, design.specific_energy_kwh_per_kg),
        mass = convert(T, design.mass),
        volume = convert(T, design.volume),
        cost = convert(T, design.cost),
        h2_model = design.h2_model,
    )
end

function _convert_design(design::DesalDesign, ::Type{T}) where {T<:Real}
    return DesalDesign{T}(
        plant_power_kw = convert(T, design.plant_power_kw),
        tank_capacity_m3 = convert(T, design.tank_capacity_m3),
        specific_energy_kwh_per_m3 = convert(T, design.specific_energy_kwh_per_m3),
        mass = convert(T, design.mass),
        volume = convert(T, design.volume),
        cost = convert(T, design.cost),
        desal_model = design.desal_model,
    )
end

function _convert_design(design::LoadDesign, ::Type{T}) where {T<:Real}
    return LoadDesign{T}(
        critical_fraction = convert(T, design.critical_fraction),
        mass = convert(T, design.mass),
        volume = convert(T, design.volume),
        cost = convert(T, design.cost),
    )
end

function _convert_design(design::BusDesign, ::Type{T}) where {T<:Real}
    return BusDesign{T}(
        voltage_nominal = convert(T, design.voltage_nominal),
        voltage_min = convert(T, design.voltage_min),
        voltage_max = convert(T, design.voltage_max),
        droop_gain = convert(T, design.droop_gain),
    )
end

function _convert_design(design::PlatformDesign, ::Type{T}) where {T<:Real}
    return PlatformDesign{T}(
        base_mass = convert(T, design.base_mass),
        base_volume = convert(T, design.base_volume),
        payload_mass = convert(T, design.payload_mass),
        payload_volume = convert(T, design.payload_volume),
        mass_margin = convert(T, design.mass_margin),
        volume_margin = convert(T, design.volume_margin),
        waterplane_area = convert(T, design.waterplane_area),
        damping = convert(T, design.damping),
        cost = convert(T, design.cost),
        hydrodynamic_model = design.hydrodynamic_model,
        mooring_model = design.mooring_model,
    )
end

function _convert_design(design::ControllerDesign, ::Type{T}) where {T<:Real}
    return ControllerDesign{T}(
        voltage_deadband = convert(T, design.voltage_deadband),
        battery_reserve_soc = convert(T, design.battery_reserve_soc),
        prediction_window_hours = convert(T, design.prediction_window_hours),
        conservative_fraction = convert(T, design.conservative_fraction),
        diesel_ration_hours = convert(T, design.diesel_ration_hours),
    )
end

"""Return a copy of the design with selected component fields updated."""
function with(design::SystemDesign;
    solar = design.solar,
    wind = design.wind,
    wave = design.wave,
    hydrokinetic = design.hydrokinetic,
    diesel = design.diesel,
    solar_gen = design.solar_gen,
    wind_gen = design.wind_gen,
    wave_gen = design.wave_gen,
    hydrokinetic_gen = design.hydrokinetic_gen,
    diesel_gen = design.diesel_gen,
    solar_conv = design.solar_conv,
    wind_conv = design.wind_conv,
    wave_conv = design.wave_conv,
    hydrokinetic_conv = design.hydrokinetic_conv,
    diesel_conv = design.diesel_conv,
    battery = design.battery,
    battery_conv = design.battery_conv,
    h2 = design.h2,
    h2_conv = design.h2_conv,
    desal = design.desal,
    desal_conv = design.desal_conv,
    load = design.load,
    load_conv = design.load_conv,
    bus = design.bus,
    platform = design.platform,
    controller = design.controller)

    T = _promoted_real_type(
        solar.area,
        wind.rotor_diameter,
        wave.capture_width,
        hydrokinetic.rotor_diameter,
        diesel.rated_power,
        solar_gen.rated_power,
        wind_gen.rated_power,
        wave_gen.rated_power,
        hydrokinetic_gen.rated_power,
        diesel_gen.rated_power,
        solar_conv.rated_power,
        wind_conv.rated_power,
        wave_conv.rated_power,
        hydrokinetic_conv.rated_power,
        diesel_conv.rated_power,
        battery.capacity_kwh,
        battery_conv.rated_power,
        h2.electrolyzer_power_kw,
        h2_conv.rated_power,
        desal.plant_power_kw,
        desal_conv.rated_power,
        load.critical_fraction,
        load_conv.rated_power,
        bus.voltage_nominal,
        platform.base_mass,
        controller.voltage_deadband,
    )

    return SystemDesign{T}(
        solar = _convert_design(solar, T),
        wind = _convert_design(wind, T),
        wave = _convert_design(wave, T),
        hydrokinetic = _convert_design(hydrokinetic, T),
        diesel = _convert_design(diesel, T),
        solar_gen = _convert_design(solar_gen, T),
        wind_gen = _convert_design(wind_gen, T),
        wave_gen = _convert_design(wave_gen, T),
        hydrokinetic_gen = _convert_design(hydrokinetic_gen, T),
        diesel_gen = _convert_design(diesel_gen, T),
        solar_conv = _convert_design(solar_conv, T),
        wind_conv = _convert_design(wind_conv, T),
        wave_conv = _convert_design(wave_conv, T),
        hydrokinetic_conv = _convert_design(hydrokinetic_conv, T),
        diesel_conv = _convert_design(diesel_conv, T),
        battery = _convert_design(battery, T),
        battery_conv = _convert_design(battery_conv, T),
        h2 = _convert_design(h2, T),
        h2_conv = _convert_design(h2_conv, T),
        desal = _convert_design(desal, T),
        desal_conv = _convert_design(desal_conv, T),
        load = _convert_design(load, T),
        load_conv = _convert_design(load_conv, T),
        bus = _convert_design(bus, T),
        platform = _convert_design(platform, T),
        controller = _convert_design(controller, T),
    )
end

"""Update a SolarDesign field while preserving other values."""
function with(design::SolarDesign;
    area = design.area,
    efficiency = design.efficiency,
    mass_per_area = design.mass_per_area,
    volume_per_area = design.volume_per_area,
    cost_per_area = design.cost_per_area,
    pv_model = design.pv_model)

    T = _promoted_real_type(area, efficiency, mass_per_area, volume_per_area, cost_per_area)
    return SolarDesign{T}(
        area = convert(T, area),
        efficiency = convert(T, efficiency),
        mass_per_area = convert(T, mass_per_area),
        volume_per_area = convert(T, volume_per_area),
        cost_per_area = convert(T, cost_per_area),
        pv_model = pv_model,
    )
end

"""Update a WindDesign field while preserving other values."""
function with(design::WindDesign;
    rotor_diameter = design.rotor_diameter,
    cp = design.cp,
    cut_in = design.cut_in,
    cut_out = design.cut_out,
    rated_speed = design.rated_speed,
    rated_power = design.rated_power,
    mass = design.mass,
    volume = design.volume,
    cost = design.cost,
    rotor_model = design.rotor_model)

    T = _promoted_real_type(rotor_diameter, cp, cut_in, cut_out, rated_speed, rated_power, mass, volume, cost)
    return WindDesign{T}(
        rotor_diameter = convert(T, rotor_diameter),
        cp = convert(T, cp),
        cut_in = convert(T, cut_in),
        cut_out = convert(T, cut_out),
        rated_speed = convert(T, rated_speed),
        rated_power = convert(T, rated_power),
        mass = convert(T, mass),
        volume = convert(T, volume),
        cost = convert(T, cost),
        rotor_model = rotor_model,
    )
end

"""Update a WaveDesign field while preserving other values."""
function with(design::WaveDesign;
    capture_width = design.capture_width,
    rated_power = design.rated_power,
    mass = design.mass,
    volume = design.volume,
    cost = design.cost)

    T = _promoted_real_type(capture_width, rated_power, mass, volume, cost)
    return WaveDesign{T}(
        capture_width = convert(T, capture_width),
        rated_power = convert(T, rated_power),
        mass = convert(T, mass),
        volume = convert(T, volume),
        cost = convert(T, cost),
    )
end

"""Update a HydrokineticDesign field while preserving other values."""
function with(design::HydrokineticDesign;
    rotor_diameter = design.rotor_diameter,
    cp = design.cp,
    cut_in = design.cut_in,
    cut_out = design.cut_out,
    rated_speed = design.rated_speed,
    rated_power = design.rated_power,
    mass = design.mass,
    volume = design.volume,
    cost = design.cost,
    rotor_model = design.rotor_model)

    T = _promoted_real_type(rotor_diameter, cp, cut_in, cut_out, rated_speed, rated_power, mass, volume, cost)
    return HydrokineticDesign{T}(
        rotor_diameter = convert(T, rotor_diameter),
        cp = convert(T, cp),
        cut_in = convert(T, cut_in),
        cut_out = convert(T, cut_out),
        rated_speed = convert(T, rated_speed),
        rated_power = convert(T, rated_power),
        mass = convert(T, mass),
        volume = convert(T, volume),
        cost = convert(T, cost),
        rotor_model = rotor_model,
    )
end

"""Update a DieselDesign field while preserving other values."""
function with(design::DieselDesign;
    rated_power = design.rated_power,
    min_power = design.min_power,
    efficiency = design.efficiency,
    fuel_per_kwh = design.fuel_per_kwh,
    fuel_tank_capacity = design.fuel_tank_capacity,
    fill_period_hours = design.fill_period_hours,
    mass = design.mass,
    volume = design.volume,
    cost = design.cost,
    engine_model = design.engine_model)

    T = _promoted_real_type(rated_power, min_power, efficiency, fuel_per_kwh, fuel_tank_capacity,
        fill_period_hours, mass, volume, cost)
    return DieselDesign{T}(
        rated_power = convert(T, rated_power),
        min_power = convert(T, min_power),
        efficiency = convert(T, efficiency),
        fuel_per_kwh = convert(T, fuel_per_kwh),
        fuel_tank_capacity = convert(T, fuel_tank_capacity),
        fill_period_hours = convert(T, fill_period_hours),
        mass = convert(T, mass),
        volume = convert(T, volume),
        cost = convert(T, cost),
        engine_model = engine_model,
    )
end

"""Update a GeneratorDesign field while preserving other values."""
function with(design::GeneratorDesign;
    rated_power = design.rated_power,
    efficiency = design.efficiency,
    mass = design.mass,
    volume = design.volume,
    cost = design.cost,
    generator_model = design.generator_model)

    T = _promoted_real_type(rated_power, efficiency, mass, volume, cost)
    return GeneratorDesign{T}(
        rated_power = convert(T, rated_power),
        efficiency = convert(T, efficiency),
        mass = convert(T, mass),
        volume = convert(T, volume),
        cost = convert(T, cost),
        generator_model = generator_model,
    )
end

"""Update a ConverterDesign field while preserving other values."""
function with(design::ConverterDesign;
    rated_power = design.rated_power,
    efficiency = design.efficiency,
    bi_directional = design.bi_directional,
    mass = design.mass,
    volume = design.volume,
    cost = design.cost,
    converter_model = design.converter_model)

    T = _promoted_real_type(rated_power, efficiency, mass, volume, cost)
    return ConverterDesign{T}(
        rated_power = convert(T, rated_power),
        efficiency = convert(T, efficiency),
        bi_directional = bi_directional,
        mass = convert(T, mass),
        volume = convert(T, volume),
        cost = convert(T, cost),
        converter_model = converter_model,
    )
end

"""Update a BatteryDesign field while preserving other values."""
function with(design::BatteryDesign;
    capacity_kwh = design.capacity_kwh,
    max_charge_kw = design.max_charge_kw,
    max_discharge_kw = design.max_discharge_kw,
    charge_efficiency = design.charge_efficiency,
    discharge_efficiency = design.discharge_efficiency,
    reserve_soc = design.reserve_soc,
    mass = design.mass,
    volume = design.volume,
    cost = design.cost,
    storage_model = design.storage_model)

    T = _promoted_real_type(capacity_kwh, max_charge_kw, max_discharge_kw, charge_efficiency,
        discharge_efficiency, reserve_soc, mass, volume, cost)
    return BatteryDesign{T}(
        capacity_kwh = convert(T, capacity_kwh),
        max_charge_kw = convert(T, max_charge_kw),
        max_discharge_kw = convert(T, max_discharge_kw),
        charge_efficiency = convert(T, charge_efficiency),
        discharge_efficiency = convert(T, discharge_efficiency),
        reserve_soc = convert(T, reserve_soc),
        mass = convert(T, mass),
        volume = convert(T, volume),
        cost = convert(T, cost),
        storage_model = storage_model,
    )
end

"""Update an H2Design field while preserving other values."""
function with(design::H2Design;
    electrolyzer_power_kw = design.electrolyzer_power_kw,
    tank_capacity_kg = design.tank_capacity_kg,
    specific_energy_kwh_per_kg = design.specific_energy_kwh_per_kg,
    mass = design.mass,
    volume = design.volume,
    cost = design.cost,
    h2_model = design.h2_model)

    T = _promoted_real_type(electrolyzer_power_kw, tank_capacity_kg, specific_energy_kwh_per_kg, mass, volume, cost)
    return H2Design{T}(
        electrolyzer_power_kw = convert(T, electrolyzer_power_kw),
        tank_capacity_kg = convert(T, tank_capacity_kg),
        specific_energy_kwh_per_kg = convert(T, specific_energy_kwh_per_kg),
        mass = convert(T, mass),
        volume = convert(T, volume),
        cost = convert(T, cost),
        h2_model = h2_model,
    )
end

"""Update a DesalDesign field while preserving other values."""
function with(design::DesalDesign;
    plant_power_kw = design.plant_power_kw,
    tank_capacity_m3 = design.tank_capacity_m3,
    specific_energy_kwh_per_m3 = design.specific_energy_kwh_per_m3,
    mass = design.mass,
    volume = design.volume,
    cost = design.cost,
    desal_model = design.desal_model)

    T = _promoted_real_type(plant_power_kw, tank_capacity_m3, specific_energy_kwh_per_m3, mass, volume, cost)
    return DesalDesign{T}(
        plant_power_kw = convert(T, plant_power_kw),
        tank_capacity_m3 = convert(T, tank_capacity_m3),
        specific_energy_kwh_per_m3 = convert(T, specific_energy_kwh_per_m3),
        mass = convert(T, mass),
        volume = convert(T, volume),
        cost = convert(T, cost),
        desal_model = desal_model,
    )
end

"""Update a ControllerDesign field while preserving other values."""
function with(design::ControllerDesign;
    voltage_deadband = design.voltage_deadband,
    battery_reserve_soc = design.battery_reserve_soc,
    prediction_window_hours = design.prediction_window_hours,
    conservative_fraction = design.conservative_fraction,
    diesel_ration_hours = design.diesel_ration_hours)

    T = _promoted_real_type(voltage_deadband, battery_reserve_soc, prediction_window_hours,
        conservative_fraction, diesel_ration_hours)
    return ControllerDesign{T}(
        voltage_deadband = convert(T, voltage_deadband),
        battery_reserve_soc = convert(T, battery_reserve_soc),
        prediction_window_hours = convert(T, prediction_window_hours),
        conservative_fraction = convert(T, conservative_fraction),
        diesel_ration_hours = convert(T, diesel_ration_hours),
    )
end

"""Update a PlatformDesign field while preserving other values."""
function with(design::PlatformDesign;
    base_mass = design.base_mass,
    base_volume = design.base_volume,
    payload_mass = design.payload_mass,
    payload_volume = design.payload_volume,
    mass_margin = design.mass_margin,
    volume_margin = design.volume_margin,
    waterplane_area = design.waterplane_area,
    damping = design.damping,
    cost = design.cost,
    hydrodynamic_model = design.hydrodynamic_model,
    mooring_model = design.mooring_model)

    T = _promoted_real_type(base_mass, base_volume, payload_mass, payload_volume, mass_margin,
        volume_margin, waterplane_area, damping, cost)
    return PlatformDesign{T}(
        base_mass = convert(T, base_mass),
        base_volume = convert(T, base_volume),
        payload_mass = convert(T, payload_mass),
        payload_volume = convert(T, payload_volume),
        mass_margin = convert(T, mass_margin),
        volume_margin = convert(T, volume_margin),
        waterplane_area = convert(T, waterplane_area),
        damping = convert(T, damping),
        cost = convert(T, cost),
        hydrodynamic_model = hydrodynamic_model,
        mooring_model = mooring_model,
    )
end

"""Create a default design-variable specification (ordered) from an existing design."""
function default_design_varspec(design::SystemDesign)
    T = typeof(design.battery.capacity_kwh)
    vars = DesignVar{T}[
        DesignVar{T}(name = :solar_area, initial = design.solar.area, lower = zero(T)),
        DesignVar{T}(name = :wind_rotor_diameter, initial = design.wind.rotor_diameter, lower = zero(T)),
        DesignVar{T}(name = :wind_rated_power, initial = design.wind.rated_power, lower = zero(T)),
        DesignVar{T}(name = :wave_capture_width, initial = design.wave.capture_width, lower = zero(T)),
        DesignVar{T}(name = :wave_rated_power, initial = design.wave.rated_power, lower = zero(T)),
        DesignVar{T}(name = :hydrokinetic_rotor_diameter, initial = design.hydrokinetic.rotor_diameter, lower = zero(T)),
        DesignVar{T}(name = :hydrokinetic_rated_power, initial = design.hydrokinetic.rated_power, lower = zero(T)),
        DesignVar{T}(name = :diesel_rated_power, initial = design.diesel.rated_power, lower = zero(T)),
        DesignVar{T}(name = :battery_capacity_kwh, initial = design.battery.capacity_kwh, lower = zero(T)),
        DesignVar{T}(name = :h2_electrolyzer_power_kw, initial = design.h2.electrolyzer_power_kw, lower = zero(T)),
        DesignVar{T}(name = :h2_tank_capacity_kg, initial = design.h2.tank_capacity_kg, lower = zero(T)),
        DesignVar{T}(name = :desal_plant_power_kw, initial = design.desal.plant_power_kw, lower = zero(T)),
        DesignVar{T}(name = :desal_tank_capacity_m3, initial = design.desal.tank_capacity_m3, lower = zero(T)),
    ]
    return DesignVarSpec(vars)
end

"""Return the initial design vector for a variable specification."""
function varspec_x0(varspec::DesignVarSpec)
    return [v.initial for v in varspec.vars]
end

"""Return lower/upper bounds for a variable specification."""
function varspec_bounds(varspec::DesignVarSpec)
    lower = [v.lower for v in varspec.vars]
    upper = [v.upper for v in varspec.vars]
    return lower, upper
end

"""Apply a single design variable to the system design."""
function set_design_var(design::SystemDesign, name::Symbol, value)
    if name == :solar_area
        solar = with(design.solar; area = value)
        return with(design; solar = solar)
    elseif name == :wind_rotor_diameter
        wind = with(design.wind; rotor_diameter = value)
        return with(design; wind = wind)
    elseif name == :wind_rated_power
        wind = with(design.wind; rated_power = value)
        return with(design; wind = wind)
    elseif name == :wave_capture_width
        wave = with(design.wave; capture_width = value)
        return with(design; wave = wave)
    elseif name == :wave_rated_power
        wave = with(design.wave; rated_power = value)
        return with(design; wave = wave)
    elseif name == :hydrokinetic_rotor_diameter
        hydrokinetic = with(design.hydrokinetic; rotor_diameter = value)
        return with(design; hydrokinetic = hydrokinetic)
    elseif name == :hydrokinetic_rated_power
        hydrokinetic = with(design.hydrokinetic; rated_power = value)
        hydrokinetic_gen = with(design.hydrokinetic_gen; rated_power = value)
        hydrokinetic_conv = with(design.hydrokinetic_conv; rated_power = value)
        return with(design;
            hydrokinetic = hydrokinetic,
            hydrokinetic_gen = hydrokinetic_gen,
            hydrokinetic_conv = hydrokinetic_conv,
        )
    elseif name == :diesel_rated_power
        diesel = with(design.diesel; rated_power = value)
        return with(design; diesel = diesel)
    elseif name == :battery_capacity_kwh
        battery = with(design.battery; capacity_kwh = value)
        return with(design; battery = battery)
    elseif name == :h2_electrolyzer_power_kw
        h2 = with(design.h2; electrolyzer_power_kw = value)
        return with(design; h2 = h2)
    elseif name == :h2_tank_capacity_kg
        h2 = with(design.h2; tank_capacity_kg = value)
        return with(design; h2 = h2)
    elseif name == :desal_plant_power_kw
        desal = with(design.desal; plant_power_kw = value)
        return with(design; desal = desal)
    elseif name == :desal_tank_capacity_m3
        desal = with(design.desal; tank_capacity_m3 = value)
        return with(design; desal = desal)
    else
        error("Unknown design variable: $(name)")
    end
end

"""Build a new SystemDesign by applying the variable vector in order."""
function design_from_x(design::SystemDesign, varspec::DesignVarSpec, x::AbstractVector)
    if length(x) != length(varspec.vars)
        error("Expected $(length(varspec.vars)) design variables, got $(length(x)).")
    end
    new_design = design
    for (i, var) in enumerate(varspec.vars)
        new_design = set_design_var(new_design, var.name, x[i])
    end
    # Keep platform payload in sync with current component sizes.
    platform = update_platform(new_design)
    return with(new_design; platform = platform)
end

"""Number of constraint values produced by `constraint_values!`."""
constraint_count(::SnowProblem) = 3

"""Fill the constraint vector with margins (positive means satisfied)."""
function constraint_values!(g::AbstractVector, design::SystemDesign,
    op::SystemOperation, spec::ConstraintSpec, dt_hours)

    if length(g) < 3
        error("Expected at least 3 constraint entries, got $(length(g)).")
    end
    cons = check_constraints(design, op, spec, dt_hours)
    g[1] = cons.battery_only_margin
    g[2] = cons.battery_plus_margin
    g[3] = cons.full_system_margin
    return g
end

"""
SNOW-style objective/constraint callback.

- `g` is the in-place constraint vector (SNOW will read its Jacobian via AD).
- `x` is the design variable vector defined by `problem.varspec`.

Returns the objective value as required by SNOW.
"""
function snow_objective!(g::AbstractVector, x::AbstractVector, problem::SnowProblem)
    design = design_from_x(problem.base_design, problem.varspec, x)

    f = if problem.objective_mode == :dynamic
        objective_dynamic(design, problem.operation, problem.dt_hours)
    else
        objective_single_point(design, problem.operation; k = problem.single_point_index)
    end

    constraint_values!(g, design, problem.operation, problem.constraint_spec, problem.dt_hours)
    return f
end
