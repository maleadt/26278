""" """ struct InverseGamma{T<:Real} <: ContinuousUnivariateDistribution
    invd::Gamma{T}
    θ::T
    function InverseGamma{T}(α, θ) where T
        @check_args(InverseGamma, α > zero(α) && θ > zero(θ))
        new{T}(Gamma(α, 1 / θ), θ)
    end
end
InverseGamma(α::T, θ::T) where {T<:Real} = InverseGamma{T}(α, θ)
InverseGamma(α::Real, θ::Real) = InverseGamma(promote(α, θ)...)
InverseGamma(α::Integer, θ::Integer) = InverseGamma(Float64(α), Float64(θ))
InverseGamma(α::Real) = InverseGamma(α, 1.0)
InverseGamma() = InverseGamma(1.0, 1.0)
@distr_support InverseGamma 0.0 Inf
convert(::Type{InverseGamma{T}}, α::S, θ::S) where {T <: Real, S <: Real} = InverseGamma(T(α), T(θ))
convert(::Type{InverseGamma{T}}, d::InverseGamma{S}) where {T <: Real, S <: Real} = InverseGamma(T(shape(d.invd)), T(d.θ))
shape(d::InverseGamma) = shape(d.invd)
scale(d::InverseGamma) = d.θ
rate(d::InverseGamma) = scale(d.invd)
params(d::InverseGamma) = (shape(d), scale(d))
@inline partype(d::InverseGamma{T}) where {T<:Real} = T
mean(d::InverseGamma{T}) where {T<:Real} = ((α, θ) = params(d); α  > 1 ? θ / (α - 1) : T(Inf))
mode(d::InverseGamma) = scale(d) / (shape(d) + 1)
function var(d::InverseGamma{T}) where T<:Real
    (α, θ) = params(d)
    α > 2 ? θ^2 / ((α - 1)^2 * (α - 2)) : T(Inf)
end
function skewness(d::InverseGamma{T}) where T<:Real
    α = shape(d)
    α > 3 ? 4sqrt(α - 2) / (α - 3) : T(NaN)
end
function kurtosis(d::InverseGamma{T}) where T<:Real
    α = shape(d)
    α > 4 ? (30α - 66) / ((α - 3) * (α - 4)) : T(NaN)
end
function entropy(d::InverseGamma)
    (α, θ) = params(d)
    α + lgamma(α) - (1 + α) * digamma(α) + log(θ)
end
pdf(d::InverseGamma, x::Real) = exp(logpdf(d, x))
function logpdf(d::InverseGamma, x::Real)
    (α, θ) = params(d)
    α * log(θ) - lgamma(α) - (α + 1) * log(x) - θ / x
end
cdf(d::InverseGamma, x::Real) = ccdf(d.invd, 1 / x)
ccdf(d::InverseGamma, x::Real) = cdf(d.invd, 1 / x)
logcdf(d::InverseGamma, x::Real) = logccdf(d.invd, 1 / x)
logccdf(d::InverseGamma, x::Real) = logcdf(d.invd, 1 / x)
quantile(d::InverseGamma, p::Real) = 1 / cquantile(d.invd, p)
cquantile(d::InverseGamma, p::Real) = 1 / quantile(d.invd, p)
invlogcdf(d::InverseGamma, p::Real) = 1 / invlogccdf(d.invd, p)
invlogccdf(d::InverseGamma, p::Real) = 1 / invlogcdf(d.invd, p)
function mgf(d::InverseGamma{T}, t::Real) where T<:Real
    (a, b) = params(d)
    t == zero(t) ? one(T) : 2(-b*t)^(0.5a) / gamma(a) * besselk(a, sqrt(-4*b*t))
end
function cf(d::InverseGamma{T}, t::Real) where T<:Real
    (a, b) = params(d)
    t == zero(t) ? one(T)+zero(T)*im : 2(-im*b*t)^(0.5a) / gamma(a) * besselk(a, sqrt(-4*im*b*t))
end
rand(d::InverseGamma) = 1 / rand(d.invd)
function _rand!(d::InverseGamma, A::AbstractArray)
    s = sampler(d.invd)
    for i = 1:length(A)
        v = 1 / rand(s)
        @inbounds A[i] = v
    end
    A
end