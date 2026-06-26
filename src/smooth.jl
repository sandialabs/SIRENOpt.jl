import FLOWMath: abs_smooth, ksmax, ksmin

"""Default smoothing scale for abs-style functions."""
const DEFAULT_ABS_DELTA = 1.0e-6

"""Default KS hardness for smooth min/max and clamp."""
const DEFAULT_KS_HARDNESS = 50.0

"""AD-safe absolute value using FLOWMath.abs_smooth."""
function smooth_abs(x; delta::Real = DEFAULT_ABS_DELTA)
    return abs_smooth(x, delta * one(x))
end

"""AD-safe maximum of two scalars using KS max."""
function smooth_max(a, b; hardness::Real = DEFAULT_KS_HARDNESS)
    return ksmax([a, b], hardness)
end

"""AD-safe minimum of two scalars using KS min."""
function smooth_min(a, b; hardness::Real = DEFAULT_KS_HARDNESS)
    return ksmin([a, b], hardness)
end

"""AD-safe maximum of an array using KS max."""
function smooth_max(xs::AbstractVector; hardness::Real = DEFAULT_KS_HARDNESS)
    return ksmax(xs, hardness)
end

"""AD-safe minimum of an array using KS min."""
function smooth_min(xs::AbstractVector; hardness::Real = DEFAULT_KS_HARDNESS)
    return ksmin(xs, hardness)
end

"""AD-safe clamp using KS min/max (approximate)."""
function smooth_clamp(x, lo, hi; hardness::Real = DEFAULT_KS_HARDNESS)
    return smooth_min(smooth_max(x, lo; hardness = hardness), hi; hardness = hardness)
end

"""AD-safe smooth transition from 0 to 1 as `x` crosses zero."""
function smooth_step(x; hardness::Real = DEFAULT_KS_HARDNESS)
    return (one(x) + tanh(hardness * x)) / 2
end

"""Clamp for index-like values: smooth clamp + hard integer bounds."""
function smooth_clamp_index(x::Real, lo::Int, hi::Int; hardness::Real = DEFAULT_KS_HARDNESS)
    x_clamped = smooth_clamp(x, oftype(x, lo), oftype(x, hi); hardness = hardness)
    return Int(Base.clamp(round(Int, x_clamped), lo, hi))
end
