const _PVLIB_W_PER_KW = 1000.0

Base.@kwdef struct PvlibSolarModel{TM,TI,T<:Real}
    pv_module::TM
    inverter::Union{Nothing,TI} = nothing
    surface_tilt_deg::T
    surface_azimuth_deg::T
    altitude_m::T
    albedo::T = T(0.25)
    use_inverter_ac::Bool = false
end

function pvlib_solar_model(;
    module_name::AbstractString = "Canadian Solar CS5P-220M [ 2009]",
    inverter_name::AbstractString = "ABB: MICRO-0.25-I-OUTD-US-208 [208V]",
    surface_tilt_deg::Real,
    surface_azimuth_deg::Real = 180.0,
    altitude_m::Real = 0.0,
    albedo::Real = 0.25,
    use_inverter_ac::Bool = false,
    T::Type = Float64,
)
    module_params = PVlib.read_solar_module(module_name)
    inverter_params = PVlib.read_solar_inverter(inverter_name)
    return PvlibSolarModel(
        module_params,
        inverter_params,
        convert(T, surface_tilt_deg),
        convert(T, surface_azimuth_deg),
        convert(T, altitude_m),
        convert(T, albedo),
        use_inverter_ac,
    )
end

function pvlib_solar_dc_power_kw(model::PvlibSolarModel, array_area_m2, weather::PVlib.WeatherSample, solar_position::PVlib.SolarPosition)
    module_area = model.pv_module.area + zero(array_area_m2)
    scale = array_area_m2 / smooth_max(module_area, oftype(array_area_m2, 1.0e-9))
    total_irradiance = PVlib.get_total_irradiance(model.surface_tilt_deg + zero(array_area_m2), model.surface_azimuth_deg + zero(array_area_m2), weather, solar_position, model.albedo + zero(array_area_m2))
    cell_temp = PVlib.sapm_cell_temperature(total_irradiance, weather; a = model.pv_module.a, b = model.pv_module.b, deltaT = model.pv_module.dtc)
    effective_irradiance = PVlib.sapm_effective_irradiance(total_irradiance, model.pv_module, solar_position, model.surface_tilt_deg + zero(array_area_m2), model.surface_azimuth_deg + zero(array_area_m2), model.altitude_m + zero(array_area_m2))
    dc = PVlib.sapm_dc_components(model.pv_module, effective_irradiance, cell_temp)
    return smooth_max(scale * dc.p_mp / _PVLIB_W_PER_KW, zero(array_area_m2))
end

function pvlib_solar_ac_power_kw(model::PvlibSolarModel, array_area_m2, weather::PVlib.WeatherSample, solar_position::PVlib.SolarPosition)
    model.inverter === nothing && return pvlib_solar_dc_power_kw(model, array_area_m2, weather, solar_position)
    module_area = model.pv_module.area + zero(array_area_m2)
    scale = array_area_m2 / smooth_max(module_area, oftype(array_area_m2, 1.0e-9))
    total_irradiance = PVlib.get_total_irradiance(model.surface_tilt_deg + zero(array_area_m2), model.surface_azimuth_deg + zero(array_area_m2), weather, solar_position, model.albedo + zero(array_area_m2))
    cell_temp = PVlib.sapm_cell_temperature(total_irradiance, weather; a = model.pv_module.a, b = model.pv_module.b, deltaT = model.pv_module.dtc)
    effective_irradiance = PVlib.sapm_effective_irradiance(total_irradiance, model.pv_module, solar_position, model.surface_tilt_deg + zero(array_area_m2), model.surface_azimuth_deg + zero(array_area_m2), model.altitude_m + zero(array_area_m2))
    dc = PVlib.sapm_dc_components(model.pv_module, effective_irradiance, cell_temp)
    ac = PVlib.sandia_ac_power(model.inverter, dc)
    return smooth_max(scale * ac.ac_power / _PVLIB_W_PER_KW, zero(array_area_m2))
end
