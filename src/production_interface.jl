_plain_float(x) = x isa AbstractFloat

function h2gen_design(design::H2Design)
    template = design.h2_model
    efficiency = template isa H2Gen.DesignStruct ?
        template.efficiency :
        smooth_clamp(33.33 / design.specific_energy_kwh_per_kg, zero(design.specific_energy_kwh_per_kg), one(design.specific_energy_kwh_per_kg))
    min_load = template isa H2Gen.DesignStruct ? template.min_load : 0.0
    max_load = template isa H2Gen.DesignStruct ? template.max_load : 1.0

    return H2Gen.DesignStruct(
        name = "SIRENOpt electrolyzer",
        capacity_mw = design.electrolyzer_power_kw / _W_PER_KW,
        efficiency = efficiency,
        min_load = min_load,
        max_load = max_load,
    )
end

function h2gen_step(design::H2Design, op::H2Op, tank_level_kg, power_alloc_kw, dt_hours, k::Int)
    model = h2gen_design(design)
    operation = H2Gen.OperationStruct(
        static = true,
        power_input_mw = power_alloc_kw / _W_PER_KW,
        duration_hours = dt_hours,
    )
    out = H2Gen.H2Gen(model, operation)

    demand_rate = value_at(op.demand, k)
    demand = demand_rate * dt_hours
    requested_production = max(out.power_used_mwh, zero(out.power_used_mwh)) * _W_PER_KW / design.specific_energy_kwh_per_kg
    available_storage = max(design.tank_capacity_kg - tank_level_kg + demand, zero(tank_level_kg))
    production = min(requested_production, available_storage)
    power_used_kw = production * design.specific_energy_kwh_per_kg / dt_hours
    new_level = clamp(tank_level_kg + production - demand, zero(tank_level_kg), design.tank_capacity_kg)
    return new_level, power_used_kw
end

function desalination_design(design::DesalDesign)
    template = design.desal_model
    capacity_m3_per_h = design.plant_power_kw / design.specific_energy_kwh_per_m3

    return Desal.DesignStruct(
        name = "SIRENOpt desalination",
        capacity_m3_per_h = capacity_m3_per_h,
        specific_energy_nominal_kwh_per_m3 = design.specific_energy_kwh_per_m3,
        recovery_ratio_nominal = template isa Desal.DesignStruct ? template.recovery_ratio_nominal : 0.45,
        min_load = template isa Desal.DesignStruct ? template.min_load : 0.0,
        max_load = template isa Desal.DesignStruct ? template.max_load : 1.0,
        ramp_rate_fraction_per_hour = template isa Desal.DesignStruct ? template.ramp_rate_fraction_per_hour : 1.0,
        response_time_hours = template isa Desal.DesignStruct ? template.response_time_hours : 0.0,
        feed_salinity_g_per_l = template isa Desal.DesignStruct ? template.feed_salinity_g_per_l : 35.0,
        nominal_salinity_g_per_l = template isa Desal.DesignStruct ? template.nominal_salinity_g_per_l : 35.0,
        feed_temperature_c = template isa Desal.DesignStruct ? template.feed_temperature_c : 25.0,
        nominal_temperature_c = template isa Desal.DesignStruct ? template.nominal_temperature_c : 25.0,
        part_load_penalty = template isa Desal.DesignStruct ? template.part_load_penalty : 0.0,
        recovery_part_load_sensitivity = template isa Desal.DesignStruct ? template.recovery_part_load_sensitivity : 0.0,
        min_recovery_ratio = template isa Desal.DesignStruct ? template.min_recovery_ratio : 0.1,
        max_recovery_ratio = template isa Desal.DesignStruct ? template.max_recovery_ratio : 0.65,
    )
end

function desalination_step(design::DesalDesign, op::DesalOp, tank_level_m3, power_alloc_kw, dt_hours, k::Int)
    model = desalination_design(design)
    operation = Desal.OperationStruct(
        static = true,
        power_input_mw = power_alloc_kw / _W_PER_KW,
        duration_hours = dt_hours,
    )
    out = Desal.Desalinate(model, operation)

    demand_rate = value_at(op.demand, k)
    demand = demand_rate * dt_hours
    available_storage = max(design.tank_capacity_m3 - tank_level_m3 + demand, zero(tank_level_m3))
    requested_production = max(out.water_output_m3, zero(out.water_output_m3))
    production = min(requested_production, available_storage)
    power_used_kw = production * design.specific_energy_kwh_per_m3 / dt_hours
    new_level = clamp(tank_level_m3 + production - demand, zero(tank_level_m3), design.tank_capacity_m3)
    return new_level, power_used_kw
end
