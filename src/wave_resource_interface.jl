function wave_power_flux_kw_per_m(significant_wave_height_m, energy_period_s; water_density = 1025.0)
    g = 9.80665
    return water_density * g^2 * significant_wave_height_m^2 * energy_period_s / (64 * pi) / _W_PER_KW
end

function wave_spectrum_power_flux_kw_per_m(spectrum; water_density = 1025.0)
    hs = WaveSpectra.Moments.significant_waveheight(spectrum)
    energy_frequency = WaveSpectra.Moments.energy_frequency(spectrum)
    energy_period = inv(energy_frequency)
    hs_m = Unitful.ustrip(hs)
    te_s = Unitful.ustrip(energy_period)
    return wave_power_flux_kw_per_m(hs_m, te_s; water_density = water_density)
end

function wave_resource_timeseries(t_hours::AbstractVector, wave_flux_kw_per_m::AbstractVector)
    length(t_hours) == length(wave_flux_kw_per_m) ||
        throw(ArgumentError("time and wave resource vectors must have matching length"))
    return TimeSeries(t_hours, wave_flux_kw_per_m)
end
