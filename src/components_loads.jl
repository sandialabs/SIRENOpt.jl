"""Electrical load demand (kW) at index k."""
function load_demand(design::LoadDesign, op::LoadOp, k::Int;
    critical_only::Bool = false, optional_only::Bool = false)

    demand = value_at(op.demand, k)
    if critical_only
        return demand * design.critical_fraction
    elseif optional_only
        return demand * (one(demand) - design.critical_fraction)
    end
    return demand
end

"""Battery state update with a power command (kW, positive = discharge to bus)."""
function battery_step(design::BatteryDesign, op::BatteryOp, soc, power_command_kw, dt_hours)
    if design.storage_model !== nothing
        return generic_storage_step(design, soc, power_command_kw, dt_hours)
    end

    capacity = design.capacity_kwh
    discharge_request = smooth_max(power_command_kw, zero(power_command_kw))
    charge_request = smooth_max(-power_command_kw, zero(power_command_kw))

    max_discharge_from_soc = soc * capacity * design.discharge_efficiency / dt_hours
    max_charge_from_soc = (one(soc) - soc) * capacity / design.charge_efficiency / dt_hours

    p_discharge = smooth_min(smooth_min(discharge_request, design.max_discharge_kw), max_discharge_from_soc)
    p_charge = smooth_min(smooth_min(charge_request, design.max_charge_kw), max_charge_from_soc)

    p = p_discharge - p_charge
    soc_new = soc - (p_discharge * dt_hours) / capacity / design.discharge_efficiency +
        (p_charge * dt_hours) / capacity * design.charge_efficiency
    soc_new = _plain_float(soc_new) ? clamp(soc_new, zero(soc_new), one(soc_new)) :
        smooth_clamp(soc_new, zero(soc_new), one(soc_new))
    return soc_new, p
end

"""Hydrogen production/storage update (kW). Returns new tank level and power used."""
function h2_step(design::H2Design, op::H2Op, tank_level_kg, power_alloc_kw, dt_hours, k::Int)
    design.h2_model !== nothing && return h2gen_step(
        design, op, tank_level_kg, power_alloc_kw, dt_hours, k)

    demand_rate = value_at(op.demand, k)
    demand = demand_rate * dt_hours
    if _plain_float(power_alloc_kw)
        power_cap = min(max(power_alloc_kw, zero(power_alloc_kw)), design.electrolyzer_power_kw)
        requested_production = power_cap * dt_hours / design.specific_energy_kwh_per_kg
        available_storage = max(design.tank_capacity_kg - tank_level_kg + demand, zero(tank_level_kg))
        production = min(requested_production, available_storage)
        power_cap = production * design.specific_energy_kwh_per_kg / dt_hours
        raw_level = tank_level_kg + production - demand
        new_level = clamp(raw_level, zero(tank_level_kg), design.tank_capacity_kg)
        return new_level, power_cap
    end

    power_cap = smooth_min(smooth_max(power_alloc_kw, zero(power_alloc_kw)), design.electrolyzer_power_kw)
    requested_production = power_cap * dt_hours / design.specific_energy_kwh_per_kg
    available_storage = smooth_max(design.tank_capacity_kg - tank_level_kg + demand, zero(tank_level_kg))
    production = smooth_min(requested_production, available_storage)
    power_cap = production * design.specific_energy_kwh_per_kg / dt_hours
    raw_level = tank_level_kg + production - demand
    new_level = smooth_clamp(raw_level, zero(tank_level_kg), design.tank_capacity_kg)
    return new_level, power_cap
end

"""Desalination production/storage update (kW). Returns new tank level and power used."""
function desal_step(design::DesalDesign, op::DesalOp, tank_level_m3, power_alloc_kw, dt_hours, k::Int)
    design.desal_model !== nothing && return desalination_step(
        design, op, tank_level_m3, power_alloc_kw, dt_hours, k)

    demand_rate = value_at(op.demand, k)
    demand = demand_rate * dt_hours
    if _plain_float(power_alloc_kw)
        power_cap = min(max(power_alloc_kw, zero(power_alloc_kw)), design.plant_power_kw)
        requested_production = power_cap * dt_hours / design.specific_energy_kwh_per_m3
        available_storage = max(design.tank_capacity_m3 - tank_level_m3 + demand, zero(tank_level_m3))
        production = min(requested_production, available_storage)
        power_cap = production * design.specific_energy_kwh_per_m3 / dt_hours
        raw_level = tank_level_m3 + production - demand
        new_level = clamp(raw_level, zero(tank_level_m3), design.tank_capacity_m3)
        return new_level, power_cap
    end

    power_cap = smooth_min(smooth_max(power_alloc_kw, zero(power_alloc_kw)), design.plant_power_kw)
    requested_production = power_cap * dt_hours / design.specific_energy_kwh_per_m3
    available_storage = smooth_max(design.tank_capacity_m3 - tank_level_m3 + demand, zero(tank_level_m3))
    production = smooth_min(requested_production, available_storage)
    power_cap = production * design.specific_energy_kwh_per_m3 / dt_hours
    raw_level = tank_level_m3 + production - demand
    new_level = smooth_clamp(raw_level, zero(tank_level_m3), design.tank_capacity_m3)
    return new_level, power_cap
end
