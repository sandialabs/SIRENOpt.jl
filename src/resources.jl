"""
Utilities for building short-horizon, high-resolution resource profiles from
the SIRENO-Lite CSV inputs. These are meant to generate sensical sub-minute
variations while preserving the slower trends in the original data.
"""

using Random
using DelimitedFiles

"""Read the SIRENO-Lite resource CSV and return the raw profile columns."""
function read_sirenolite_resource_csv(path::AbstractString)
    data, header = readdlm(path, ',', Float64, header = true)
    names = vec(String.(header))
    n = size(data, 1)

    function col(candidates::AbstractVector{<:AbstractString}; default::Float64 = 0.0)
        idx = nothing
        for candidate in candidates
            idx = findfirst(==(candidate), names)
            idx === nothing || break
        end
        if idx === nothing
            return fill(default, n)
        end
        return data[:, idx]
    end

    return (
        time_hours = col(["Time", "Time_h"]),
        load_w = col(["Load", "Load_W_shape", "Load_W"]),
        solar_w = col(["Solar", "Solar_W_shape", "Solar_profile"]),
        wind_w = col(["Wind", "Wind_W_shape", "Wind_profile"]),
        wave_w = col(["Wave", "Wave_W_shape", "Wave_profile"]),
        hydrogen_g = col(["Hydrogen", "Hydrogen_g_per_h_shape", "Hydrogen_g_per_h"]),
        potable_water_l = col(["PotableWater", "PotableWater_L_per_h_shape", "PotableWater_L_per_h"]),
    )
end

"""Normalize a profile to the [0, 1] range (all zeros if the max is nonpositive)."""
function normalize_profile(values::AbstractVector{<:Real})
    max_val = maximum(values)
    if max_val <= 0
        return zeros(Float64, length(values))
    end
    return Float64.(values) ./ max_val
end

"""Simple linear interpolation with endpoint clamping."""
function linear_interp(x::AbstractVector{<:Real}, y::AbstractVector{<:Real},
    xnew::AbstractVector{<:Real})

    n = length(x)
    ynew = Vector{Float64}(undef, length(xnew))
    idx = 1
    for (i, xi) in enumerate(xnew)
        if xi <= x[1]
            ynew[i] = y[1]
            continue
        elseif xi >= x[end]
            ynew[i] = y[end]
            continue
        end

        while idx < n && x[idx + 1] < xi
            idx += 1
        end
        x0 = x[idx]
        x1 = x[idx + 1]
        y0 = y[idx]
        y1 = y[idx + 1]
        frac = (xi - x0) / (x1 - x0)
        ynew[i] = y0 + frac * (y1 - y0)
    end
    return ynew
end

function bandlimited_noise(t::AbstractVector{<:Real};
    fmin::Real, fmax::Real, ncomp::Int, rng::AbstractRNG)

    freqs = exp.(rand(rng, ncomp) .* log(fmax / fmin)) .* fmin
    phases = 2π .* rand(rng, ncomp)
    noise = zeros(Float64, length(t))
    for i in 1:ncomp
        noise .+= sin.(2π .* freqs[i] .* t .+ phases[i])
    end
    return noise ./ ncomp
end

function colored_noise(n::Int; alpha::Real, rng::AbstractRNG)
    noise = zeros(Float64, n)
    x = 0.0
    sigma = sqrt(max(0.0, 1 - alpha^2))
    for i in 1:n
        x = alpha * x + sigma * randn(rng)
        noise[i] = x
    end
    max_abs = maximum(abs.(noise))
    return max_abs > 0 ? noise ./ max_abs : noise
end

function scaled_noise(t::AbstractVector{<:Real};
    fmin::Real, fmax::Real, ncomp::Int, alpha::Real, rng::AbstractRNG)

    bl = bandlimited_noise(t; fmin = fmin, fmax = fmax, ncomp = ncomp, rng = rng)
    cn = colored_noise(length(t); alpha = alpha, rng = rng)
    noise = 0.6 .* bl .+ 0.4 .* cn
    max_abs = maximum(abs.(noise))
    return max_abs > 0 ? noise ./ max_abs : noise
end

function apply_variation(base::AbstractVector{<:Real}, t::AbstractVector{<:Real};
    frac::Real, fmin::Real, fmax::Real, alpha::Real, rng::AbstractRNG)

    noise = scaled_noise(t; fmin = fmin, fmax = fmax, ncomp = 8, alpha = alpha, rng = rng)
    return Float64.(base) .* (1 .+ frac .* noise)
end

"""
Build short-horizon profiles (1-minute default) with sub-second variations.

Returns a NamedTuple with:
`t_hours`, `solar_ts`, `wind_ts`, `wave_ts`, `load_ts`, `h2_ts`, `desal_ts`, `dt_hours`.

Units are aligned with the SIRENO-Lite formulation:
- `solar_ts`: kW/m^2 proxy resource
- `wind_ts`: m/s
- `wave_ts`: kW/m proxy resource
- `load_ts`: kW electric demand
- `h2_ts`: kg/h hydrogen demand rate
- `desal_ts`: m^3/h potable-water demand rate
"""
function short_horizon_profiles(path::AbstractString;
    start_hour::Real = 0.0,
    horizon_s::Real = 60.0,
    dt_s::Real = 0.01,
    seed::Integer = 1,
    peak_load_kw::Real = 1.0,
    solar_kw_per_m2::Real = 1.0,
    wind_speed_range::Tuple{<:Real,<:Real} = (3.0, 8.5),
    wave_kw_per_m_range::Tuple{<:Real,<:Real} = (0.4, 1.2),
    h2_daily_demand_g::Real = 400.0,
    water_daily_demand_l::Real = 265.0,
    noise_frac = (solar = 0.05, wind = 0.10, wave = 0.08, load = 0.02))

    rng = MersenneTwister(seed)
    data = read_sirenolite_resource_csv(path)

    solar_unit = normalize_profile(data.solar_w)
    wind_unit = normalize_profile(data.wind_w)
    wave_unit = normalize_profile(data.wave_w)
    load_unit = normalize_profile(data.load_w)
    hydrogen_g = normalize_profile(data.hydrogen_g) .* h2_daily_demand_g
    water_l = normalize_profile(data.potable_water_l) .* water_daily_demand_l

    t_s = collect(0.0:dt_s:horizon_s)
    t_hours = start_hour .+ t_s ./ 3600.0

    solar_base = linear_interp(data.time_hours, solar_unit, t_hours) .* solar_kw_per_m2
    wind_unit_short = linear_interp(data.time_hours, wind_unit, t_hours)
    wave_unit_short = linear_interp(data.time_hours, wave_unit, t_hours)
    load_base = linear_interp(data.time_hours, load_unit, t_hours) .* peak_load_kw
    h2_base = linear_interp(data.time_hours, hydrogen_g, t_hours) ./ 1000.0
    water_base = linear_interp(data.time_hours, water_l, t_hours) ./ 1000.0

    solar = apply_variation(solar_base, t_s;
        frac = noise_frac.solar, fmin = 0.05, fmax = 1.5, alpha = 0.995, rng = rng)
    solar = clamp.(solar, 0.0, solar_kw_per_m2 * 1.2)

    wind_min, wind_max = wind_speed_range
    wind_base = wind_min .+ wind_unit_short .* (wind_max - wind_min)
    wind = apply_variation(wind_base, t_s;
        frac = noise_frac.wind, fmin = 0.2, fmax = 4.0, alpha = 0.98, rng = rng)
    wind = clamp.(wind, wind_min * 0.8, wind_max * 1.2)

    wave_min, wave_max = wave_kw_per_m_range
    wave_base = wave_min .+ wave_unit_short .* (wave_max - wave_min)
    wave = apply_variation(wave_base, t_s;
        frac = noise_frac.wave, fmin = 0.05, fmax = 0.8, alpha = 0.995, rng = rng)
    wave = clamp.(wave, 0.0, wave_max * 1.2)

    load = apply_variation(load_base, t_s;
        frac = noise_frac.load, fmin = 0.05, fmax = 1.0, alpha = 0.99, rng = rng)
    load = clamp.(load, 0.0, Inf)

    return (
        t_hours = t_hours,
        solar_ts = TimeSeries(t_hours, solar),
        wind_ts = TimeSeries(t_hours, wind),
        wave_ts = TimeSeries(t_hours, wave),
        load_ts = TimeSeries(t_hours, load),
        h2_ts = TimeSeries(t_hours, h2_base),
        desal_ts = TimeSeries(t_hours, water_base),
        dt_hours = dt_s / 3600.0,
    )
end
