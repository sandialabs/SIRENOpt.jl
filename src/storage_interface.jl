const _J_PER_KWH = 3.6e6
const _SECONDS_PER_HOUR_SIREN = 3600.0

function generic_storage_params(design::BatteryDesign)
    template = design.storage_model
    standing_loss_rate = template isa AgnosticStorageDynamics.StorageParams ?
        template.standing_loss_rate : zero(design.capacity_kwh)

    return AgnosticStorageDynamics.StorageParams(
        energy_capacity = design.capacity_kwh * _J_PER_KWH,
        energy_min = design.reserve_soc * design.capacity_kwh * _J_PER_KWH,
        charge_rate_max = design.max_charge_kw * _W_PER_KW,
        discharge_rate_max = design.max_discharge_kw * _W_PER_KW,
        charge_efficiency = design.charge_efficiency,
        discharge_efficiency = design.discharge_efficiency,
        standing_loss_rate = standing_loss_rate,
    )
end

function generic_storage_step(design::BatteryDesign, soc, power_command_kw, dt_hours)
    params = generic_storage_params(design)
    initial_energy = soc * design.capacity_kwh * _J_PER_KWH
    charge_kw = _plain_float(power_command_kw) ?
        max(-power_command_kw, zero(power_command_kw)) :
        smooth_max(-power_command_kw, zero(power_command_kw))
    discharge_kw = _plain_float(power_command_kw) ?
        max(power_command_kw, zero(power_command_kw)) :
        smooth_max(power_command_kw, zero(power_command_kw))

    result = AgnosticStorageDynamics.simulate_storage(
        [charge_kw * _W_PER_KW],
        [discharge_kw * _W_PER_KW],
        params;
        dt = dt_hours * _SECONDS_PER_HOUR_SIREN,
        initial_energy = initial_energy,
    )

    capacity_j = design.capacity_kwh * _J_PER_KWH
    soc_new = result.energy[end] / capacity_j
    power_kw = (result.discharge_power[1] - result.charge_power[1]) / _W_PER_KW
    return soc_new, power_kw
end
