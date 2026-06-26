using Random

"""
    latin_hypercube(lower, upper, n_samples; rng=Random.default_rng(), centered=false)
    latin_hypercube(lower, upper; n_samples=10 * length(lower), kwargs...)

Generate a Latin hypercube sampling plan over box bounds.

Rows of the returned matrix are sample points and columns correspond to design
variables. Each column contains exactly one sample in each of `n_samples`
equal-probability strata, then scales the unit hypercube to `lower` and
`upper`. Set `centered=true` to use stratum centers instead of random offsets.
"""
function latin_hypercube(
    lower::AbstractVector{<:Real},
    upper::AbstractVector{<:Real},
    n_samples::Integer;
    rng::AbstractRNG = Random.default_rng(),
    centered::Bool = false,
)
    length(lower) == length(upper) ||
        throw(DimensionMismatch("lower and upper must have the same length"))
    n_samples > 0 || throw(ArgumentError("n_samples must be positive"))

    n_dim = length(lower)
    T = promote_type(eltype(lower), eltype(upper), Float64)
    samples = Matrix{T}(undef, n_samples, n_dim)

    for j in 1:n_dim
        lo = T(lower[j])
        hi = T(upper[j])
        isfinite(lo) && isfinite(hi) ||
            throw(ArgumentError("Latin hypercube bounds must be finite"))
        hi >= lo ||
            throw(ArgumentError("upper[$j] must be greater than or equal to lower[$j]"))

        width = hi - lo
        perm = randperm(rng, n_samples)
        offsets = centered ? fill(T(0.5), n_samples) : rand(rng, T, n_samples)
        for i in 1:n_samples
            unit = (T(perm[i] - 1) + offsets[i]) / T(n_samples)
            samples[i, j] = lo + width * unit
        end
    end

    return samples
end

function latin_hypercube(
    lower::AbstractVector{<:Real},
    upper::AbstractVector{<:Real};
    n_samples::Integer = 10 * length(lower),
    kwargs...,
)
    return latin_hypercube(lower, upper, n_samples; kwargs...)
end

"""Short alias for `latin_hypercube`."""
lhyper(args...; kwargs...) = latin_hypercube(args...; kwargs...)
