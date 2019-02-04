""" """ struct Erlang{T<:Real} <: ContinuousUnivariateDistribution
    α::Int
    θ::T
    function Erlang{T}(α::Real, θ::T) where T
        @check_args(Erlang, isinteger(α) && α >= zero(α))
        new{T}(α, θ)
    end
end
Erlang(α::Int, θ::T) where {T<:Real} = Erlang{T}(α, θ)
Erlang(α::Int, θ::Integer) = Erlang{Float64}(α, Float64(θ))
Erlang(α::Int) = Erlang(α, 1.0)
Erlang() = Erlang(1, 1.0)
@distr_support Erlang 0.0 Inf
function convert(::Type{Erlang{T}}, α::Int, θ::S) where {T <: Real, S <: Real}
    Erlang(α, T(θ))
end
function convert(::Type{Erlang{T}}, d::Erlang{S}) where {T <: Real, S <: Real}
    Erlang(d.α, T(d.θ))
end
shape(d::Erlang) = d.α
scale(d::Erlang) = d.θ
rate(d::Erlang) = inv(d.θ)
params(d::Erlang) = (d.α, d.θ)
@inline partype(d::Erlang{T}) where {T<:Real} = T
mean(d::Erlang) = d.α * d.θ
var(d::Erlang) = d.α * d.θ^2
skewness(d::Erlang) = 2 / sqrt(d.α)
kurtosis(d::Erlang) = 6 / d.α
function mode(d::Erlang)
    (α, θ) = params(d)
    α >= 1 ? θ * (α - 1) : error("Erlang has no mode when α < 1")
end
function entropy(d::Erlang)
    (α, θ) = params(d)
    α + lgamma(α) + (1 - α) * digamma(α) + log(θ)
end
mgf(d::Erlang, t::Real) = (1 - t * d.θ)^(-d.α)
cf(d::Erlang, t::Real)  = (1 - im * t * d.θ)^(-d.α)
@_delegate_statsfuns Erlang gamma α θ
rand(d::Erlang) = StatsFuns.RFunctions.gammarand(d.α, d.θ)