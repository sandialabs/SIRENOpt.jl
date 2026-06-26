"""Aggregate mass, volume, and cost across the system design."""
function aggregate_mass_cost_volume(design::SystemDesign; include_platform::Bool = true)
    mass = zero(design.battery.mass)
    volume = zero(design.battery.volume)
    cost = zero(design.battery.cost)

    solar_mass = design.solar.area * design.solar.mass_per_area
    solar_volume = design.solar.area * design.solar.volume_per_area
    solar_cost = design.solar.area * design.solar.cost_per_area

    mass += solar_mass + design.solar_gen.mass + design.solar_conv.mass
    volume += solar_volume + design.solar_gen.volume + design.solar_conv.volume
    cost += solar_cost + design.solar_gen.cost + design.solar_conv.cost

    mass += design.wind.mass + design.wind_gen.mass + design.wind_conv.mass
    volume += design.wind.volume + design.wind_gen.volume + design.wind_conv.volume
    cost += design.wind.cost + design.wind_gen.cost + design.wind_conv.cost

    mass += design.wave.mass + design.wave_gen.mass + design.wave_conv.mass
    volume += design.wave.volume + design.wave_gen.volume + design.wave_conv.volume
    cost += design.wave.cost + design.wave_gen.cost + design.wave_conv.cost

    mass += design.hydrokinetic.mass + design.hydrokinetic_gen.mass + design.hydrokinetic_conv.mass
    volume += design.hydrokinetic.volume + design.hydrokinetic_gen.volume + design.hydrokinetic_conv.volume
    cost += design.hydrokinetic.cost + design.hydrokinetic_gen.cost + design.hydrokinetic_conv.cost

    mass += design.diesel.mass + design.diesel_gen.mass + design.diesel_conv.mass
    volume += design.diesel.volume + design.diesel_gen.volume + design.diesel_conv.volume
    cost += design.diesel.cost + design.diesel_gen.cost + design.diesel_conv.cost

    mass += design.battery.mass + design.battery_conv.mass
    volume += design.battery.volume + design.battery_conv.volume
    cost += design.battery.cost + design.battery_conv.cost

    mass += design.h2.mass + design.h2_conv.mass
    volume += design.h2.volume + design.h2_conv.volume
    cost += design.h2.cost + design.h2_conv.cost

    mass += design.desal.mass + design.desal_conv.mass
    volume += design.desal.volume + design.desal_conv.volume
    cost += design.desal.cost + design.desal_conv.cost

    mass += design.load.mass + design.load_conv.mass
    volume += design.load.volume + design.load_conv.volume
    cost += design.load.cost + design.load_conv.cost

    if include_platform
        mass += design.platform.base_mass + design.platform.mass_margin + mooring_mass_kg(design.platform.mooring_model)
        volume += design.platform.base_volume + design.platform.volume_margin
        cost += design.platform.cost
    end

    return (mass = mass, volume = volume, cost = cost)
end

"""Update platform payload mass/volume based on current component design."""
function update_platform(design::SystemDesign)
    agg = aggregate_mass_cost_volume(design; include_platform = false)
    platform = design.platform
    return PlatformDesign(
        base_mass = platform.base_mass,
        base_volume = platform.base_volume,
        payload_mass = agg.mass,
        payload_volume = agg.volume,
        mass_margin = platform.mass_margin,
        volume_margin = platform.volume_margin,
        waterplane_area = platform.waterplane_area,
        damping = platform.damping,
        cost = platform.cost,
        hydrodynamic_model = platform.hydrodynamic_model,
        mooring_model = platform.mooring_model,
    )
end

"""
Build a platform design using a mass ratio relative to supported mass.

This mirrors the SIRENO-Lite convention: platform structure mass is
`mass_ratio * supported_mass`, with cost computed from `cost_per_kg`.
"""
function platform_from_supported_mass(design::SystemDesign;
    mass_ratio::Real = 0.3,
    cost_per_kg::Real = 30.0)

    agg = aggregate_mass_cost_volume(design; include_platform = false)
    platform_mass = agg.mass * mass_ratio
    platform_cost = platform_mass * cost_per_kg
    platform = design.platform

    return PlatformDesign(
        base_mass = platform_mass,
        base_volume = platform.base_volume,
        payload_mass = agg.mass,
        payload_volume = agg.volume,
        mass_margin = platform.mass_margin,
        volume_margin = platform.volume_margin,
        waterplane_area = platform.waterplane_area,
        damping = platform.damping,
        cost = platform_cost,
        hydrodynamic_model = platform.hydrodynamic_model,
        mooring_model = platform.mooring_model,
    )
end
