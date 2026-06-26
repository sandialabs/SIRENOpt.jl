"""
    diesel_engine_design(design::DieselDesign)

Build a DieselGen engine model from SIRENOpt diesel design fields. If
`design.engine_model` stores a DieselGen.EngineDesign, it is used as a template
for map, fuel, ramp, and mass assumptions while the current SIRENOpt sizing
fields provide rated and idle power.
"""
function diesel_engine_design(design::DieselDesign)
    template = design.engine_model
    if template isa DieselGen.EngineDesign
        return DieselGen.EngineDesign(
            max_power_kw = design.rated_power,
            idle_power_kw = design.min_power,
            ramp_time_s = template.ramp_time_s,
            base_mass_kg = template.base_mass_kg,
            power_density_kw_per_kg = template.power_density_kw_per_kg,
            comp_mass_multiplier = template.comp_mass_multiplier,
            eff_map = template.eff_map,
            fuel = template.fuel,
        )
    end

    return DieselGen.EngineDesign(
        max_power_kw = design.rated_power,
        idle_power_kw = design.min_power,
        eff_map = DieselGen.default_diesel_map(),
        fuel = DieselGen.default_diesel_fuel(),
    )
end

"""
    diesel_fuel_used(engine, power_out_kw, dt_hours)

Fuel volume used over the step, in liters. DieselGen uses SI rates internally;
SIRENOpt passes power in kW and time in hours.
"""
function diesel_fuel_used(engine::DieselGen.EngineDesign, power_out_kw, dt_hours)
    fuel_power = DieselGen.fuel_power_kw(engine, power_out_kw)
    mass_flow = DieselGen.fuel_mass_flow_kg_s(engine, fuel_power)
    volume_flow = DieselGen.fuel_volume_flow_l_s(engine, mass_flow)
    return volume_flow * dt_hours * 3600
end
