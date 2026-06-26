"""Compute raw solar resource power (kW) at index k."""
function power_available_solar(design::SolarDesign, op::SolarOp, k::Int)
    if design.pv_model !== nothing && op.pv_weather !== nothing && op.pv_solar_position !== nothing
        p_raw = if design.pv_model.use_inverter_ac
            pvlib_solar_ac_power_kw(design.pv_model, design.area, op.pv_weather[k], op.pv_solar_position[k])
        else
            pvlib_solar_dc_power_kw(design.pv_model, design.area, op.pv_weather[k], op.pv_solar_position[k])
        end
        return p_raw * (one(p_raw) - op.curtailment)
    end
    irradiance = value_at(op.resource, k)
    return irradiance * design.area * design.efficiency * (one(irradiance) - op.curtailment)
end

"""Compute raw wind resource power (kW) at index k."""
function power_available_wind(design::WindDesign, op::WindOp, k::Int)
    v = value_at(op.resource, k)
    if design.rotor_model !== nothing
        availability = smooth_step(v - design.cut_in) * smooth_step(design.cut_out - v)
        p = if _plain_float(v) && _plain_float(op.air_density)
            ccblade_rotor_power_kw(design.rotor_model, v, op.air_density)
        else
            # The current unsteady rotor package state is Float64-typed. Keep
            # the primal package path, but use the same smooth actuator-disk
            # envelope for AD sensitivity when resource or motion is dual-valued.
            v_eff = smooth_max(v, zero(v))
            area = pi * (design.rotor_diameter / 2)^2
            0.5 * op.air_density * area * v_eff^3 * design.cp / 1000
        end
        return smooth_min(p, design.rated_power) * availability * (one(v) - op.curtailment)
    end
    availability = smooth_step(v - design.cut_in) * smooth_step(design.cut_out - v)
    v_eff = smooth_max(v, zero(v))
    area = pi * (design.rotor_diameter / 2)^2
    # Convert W -> kW to keep power units consistent with the rest of the model.
    p = 0.5 * op.air_density * area * v_eff^3 * design.cp / 1000
    return smooth_min(p, design.rated_power) * availability * (one(v) - op.curtailment)
end

"""Compute raw wave resource power (kW) at index k."""
function power_available_wave(design::WaveDesign, op::WaveOp, k::Int)
    resource = value_at(op.resource, k)
    p = resource * design.capture_width
    return smooth_min(p, design.rated_power) * (one(resource) - op.curtailment)
end

"""Compute raw hydrokinetic resource power (kW) at index k."""
function power_available_hydrokinetic(design::HydrokineticDesign, op::HydrokineticOp, k::Int)
    v = value_at(op.resource, k)
    if design.rotor_model !== nothing
        availability = smooth_step(v - design.cut_in) * smooth_step(design.cut_out - v)
        p = if _plain_float(v) && _plain_float(op.fluid_density)
            ccblade_rotor_power_kw(design.rotor_model, v, op.fluid_density)
        else
            # Match the wind adapter boundary: package-backed primal replay,
            # smooth actuator-disk envelope for AD-valued resource inputs.
            v_eff = smooth_max(v, zero(v))
            area = pi * (design.rotor_diameter / 2)^2
            0.5 * op.fluid_density * area * v_eff^3 * design.cp / 1000
        end
        return smooth_min(p, design.rated_power) * availability * (one(v) - op.curtailment)
    end
    availability = smooth_step(v - design.cut_in) * smooth_step(design.cut_out - v)
    v_eff = smooth_max(v, zero(v))
    area = pi * (design.rotor_diameter / 2)^2
    p = 0.5 * op.fluid_density * area * v_eff^3 * design.cp / 1000
    return smooth_min(p, design.rated_power) * availability * (one(v) - op.curtailment)
end

"""Convert mechanical or DC power to electrical using a generator model."""
function generator_output(design::GeneratorDesign, op::GeneratorOp, mechanical_power)
    if _plain_float(mechanical_power)
        p_raw = if design.generator_model === nothing
            max(mechanical_power, zero(mechanical_power)) * design.efficiency
        else
            input_power = max(mechanical_power, zero(mechanical_power))
            idle_offset = generatorse_output_kw(design.generator_model, zero(input_power))
            max(generatorse_output_kw(design.generator_model, input_power) - idle_offset,
                zero(mechanical_power))
        end
        return min(p_raw, design.rated_power) * op.availability
    end

    p_raw = if design.generator_model === nothing
        smooth_max(mechanical_power, zero(mechanical_power)) * design.efficiency
    else
        input_power = smooth_max(mechanical_power, zero(mechanical_power))
        idle_offset = generatorse_output_kw(design.generator_model, zero(input_power))
        smooth_max(generatorse_output_kw(design.generator_model, input_power) - idle_offset,
            zero(mechanical_power))
    end
    p = smooth_min(p_raw, design.rated_power)
    return p * op.availability
end

"""Convert device-side power to bus-side power through converter losses."""
function converter_output(design::ConverterDesign, op::ConverterOp, device_power)
    if _plain_float(device_power)
        p = clamp(device_power, -design.rated_power, design.rated_power)
        p_bus = if design.converter_model === nothing
            p >= zero(p) ? p * design.efficiency : p / design.efficiency
        else
            powerconverter_output_kw(design.converter_model, p) -
                powerconverter_output_kw(design.converter_model, zero(p))
        end
        return p_bus * op.availability
    end

    p = smooth_clamp(device_power, -design.rated_power, design.rated_power)
    p_bus = if design.converter_model === nothing
        p_supply = smooth_max(p, zero(p))
        p_load = smooth_min(p, zero(p))
        p_supply * design.efficiency + p_load / design.efficiency
    else
        powerconverter_output_kw(design.converter_model, p) -
            powerconverter_output_kw(design.converter_model, zero(p))
    end
    return p_bus * op.availability
end

"""Solar power to bus (kW) including generator and converter."""
function solar_power(design::SolarDesign, op::SolarOp,
    gen_design::GeneratorDesign, gen_op::GeneratorOp,
    conv_design::ConverterDesign, conv_op::ConverterOp,
    k::Int)

    p_raw = power_available_solar(design, op, k)
    p_gen = generator_output(gen_design, gen_op, p_raw)
    return converter_output(conv_design, conv_op, p_gen)
end

"""Wind power to bus (kW) including generator and converter."""
function wind_power(design::WindDesign, op::WindOp,
    gen_design::GeneratorDesign, gen_op::GeneratorOp,
    conv_design::ConverterDesign, conv_op::ConverterOp,
    k::Int)

    p_raw = power_available_wind(design, op, k)
    p_gen = generator_output(gen_design, gen_op, p_raw)
    return converter_output(conv_design, conv_op, p_gen)
end

"""Wave power to bus (kW) including generator and converter."""
function wave_power(design::WaveDesign, op::WaveOp,
    gen_design::GeneratorDesign, gen_op::GeneratorOp,
    conv_design::ConverterDesign, conv_op::ConverterOp,
    k::Int)

    p_raw = power_available_wave(design, op, k)
    p_gen = generator_output(gen_design, gen_op, p_raw)
    return converter_output(conv_design, conv_op, p_gen)
end

"""Hydrokinetic power to bus (kW) including generator and converter."""
function hydrokinetic_power(design::HydrokineticDesign, op::HydrokineticOp,
    gen_design::GeneratorDesign, gen_op::GeneratorOp,
    conv_design::ConverterDesign, conv_op::ConverterOp,
    k::Int)

    p_raw = power_available_hydrokinetic(design, op, k)
    p_gen = generator_output(gen_design, gen_op, p_raw)
    return converter_output(conv_design, conv_op, p_gen)
end

"""Diesel power to bus (kW) and fuel used (kg or L) for the time step."""
function diesel_power(design::DieselDesign, op::DieselOp,
    gen_design::GeneratorDesign, gen_op::GeneratorOp,
    conv_design::ConverterDesign, conv_op::ConverterOp,
    power_setpoint_kw, dt_hours)

    if _plain_float(power_setpoint_kw)
        p_req = clamp(power_setpoint_kw, design.min_power, design.rated_power)
        engine = diesel_engine_design(design)
        p_engine = clamp(p_req, zero(p_req), engine.max_power_kw)
        p_gen = generator_output(gen_design, gen_op, p_engine)
        p_bus = converter_output(conv_design, conv_op, p_gen) * op.availability
        fuel_used = diesel_fuel_used(engine, p_engine, dt_hours)
        return p_bus, fuel_used
    end

    p_req = smooth_clamp(power_setpoint_kw, design.min_power, design.rated_power)
    engine = diesel_engine_design(design)
    p_engine = smooth_clamp(p_req, zero(p_req), engine.max_power_kw)
    p_gen = generator_output(gen_design, gen_op, p_engine)
    p_bus = converter_output(conv_design, conv_op, p_gen) * op.availability
    fuel_used = diesel_fuel_used(engine, p_engine, dt_hours)
    return p_bus, fuel_used
end
