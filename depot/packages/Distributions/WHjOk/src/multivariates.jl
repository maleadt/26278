""" """ length(d::MultivariateDistribution)
""" """ size(d::MultivariateDistribution)
""" """ rand!(d::MultivariateDistribution, x::AbstractArray)
function rand!(d::MultivariateDistribution, x::AbstractVector)
    length(x) == length(d) ||
        throw(DimensionMismatch("Output size inconsistent with sample length."))
    _rand!(d, x)
end
function rand!(d::MultivariateDistribution, A::AbstractMatrix)
    size(A,1) == length(d) ||
        throw(DimensionMismatch("Output size inconsistent with sample length."))
    _rand!(sampler(d), A)
end
""" """ rand(d::MultivariateDistribution) = _rand!(d, Vector{eltype(d)}(undef, length(d)))
rand(d::MultivariateDistribution, n::Int) = _rand!(sampler(d), Matrix{eltype(d)}(undef, length(d), n))
""" """ _rand!(d::MultivariateDistribution, x::AbstractArray)
""" """ insupport{D<:MultivariateDistribution}(d::Union{D, Type{D}}, x::AbstractArray)
function insupport!(r::AbstractArray, d::Union{D,Type{D}}, X::AbstractMatrix) where D<:MultivariateDistribution
    n = length(r)
    size(X) == (length(d),n) ||
        throw(DimensionMismatch("Inconsistent array dimensions."))
    for i in 1:n
        @inbounds r[i] = insupport(d, view(X, :, i))
    end
    return r
end
insupport(d::Union{D,Type{D}}, X::AbstractMatrix) where {D<:MultivariateDistribution} =
    insupport!(BitArray(undef, size(X,2)), d, X)
""" """ mean(d::MultivariateDistribution)
""" """ var(d::MultivariateDistribution)
""" """ entropy(d::MultivariateDistribution)
""" """ entropy(d::MultivariateDistribution, b::Real) = entropy(d) / log(b)
""" """ cov(d::MultivariateDistribution)
""" """ function cor(d::MultivariateDistribution)
    C = cov(d)
    n = size(C, 1)
    @assert size(C, 2) == n
    R = Matrix{eltype(C)}(undef, n, n)
    for j = 1:n
        for i = 1:j-1
            @inbounds R[i, j] = R[j, i]
        end
        R[j, j] = 1.0
        for i = j+1:n
            @inbounds R[i, j] = C[i, j] / sqrt(C[i, i] * C[j, j])
        end
    end
    return R
end
""" """ pdf(d::MultivariateDistribution, x::AbstractArray)
""" """ logpdf(d::MultivariateDistribution, x::AbstractArray)
_pdf(d::MultivariateDistribution, X::AbstractVector) = exp(_logpdf(d, X))
function logpdf(d::MultivariateDistribution, X::AbstractVector)
    length(X) == length(d) ||
        throw(DimensionMismatch("Inconsistent array dimensions."))
    _logpdf(d, X)
end
function pdf(d::MultivariateDistribution, X::AbstractVector)
    length(X) == length(d) ||
        throw(DimensionMismatch("Inconsistent array dimensions."))
    _pdf(d, X)
end
function _logpdf!(r::AbstractArray, d::MultivariateDistribution, X::AbstractMatrix)
    for i in 1 : size(X,2)
        @inbounds r[i] = logpdf(d, view(X,:,i))
    end
    return r
end
function _pdf!(r::AbstractArray, d::MultivariateDistribution, X::AbstractMatrix)
    for i in 1 : size(X,2)
        @inbounds r[i] = pdf(d, view(X,:,i))
    end
    return r
end
function logpdf!(r::AbstractArray, d::MultivariateDistribution, X::AbstractMatrix)
    size(X) == (length(d), length(r)) ||
        throw(DimensionMismatch("Inconsistent array dimensions."))
    _logpdf!(r, d, X)
end
function pdf!(r::AbstractArray, d::MultivariateDistribution, X::AbstractMatrix)
    size(X) == (length(d), length(r)) ||
        throw(DimensionMismatch("Inconsistent array dimensions."))
    _pdf!(r, d, X)
end
function logpdf(d::MultivariateDistribution, X::AbstractMatrix)
    size(X, 1) == length(d) ||
        throw(DimensionMismatch("Inconsistent array dimensions."))
    T = promote_type(partype(d), eltype(X))
    _logpdf!(Vector{T}(undef, size(X,2)), d, X)
end
function pdf(d::MultivariateDistribution, X::AbstractMatrix)
    size(X, 1) == length(d) ||
        throw(DimensionMismatch("Inconsistent array dimensions."))
    T = promote_type(partype(d), eltype(X))
    _pdf!(Vector{T}(undef, size(X,2)), d, X)
end
""" """ _logpdf(d::MultivariateDistribution, x::AbstractArray)
""" """ function loglikelihood(d::MultivariateDistribution, X::AbstractMatrix)
    size(X, 1) == length(d) || throw(DimensionMismatch("Inconsistent array dimensions."))
    return sum(i -> _logpdf(d, view(X, :, i)), 1:size(X, 2))
end
for fname in ["dirichlet.jl",
              "multinomial.jl",
              "dirichletmultinomial.jl",
              "mvnormal.jl",
              "mvnormalcanon.jl",
              "mvlognormal.jl",
              "mvtdist.jl",
              "vonmisesfisher.jl"]
    include(joinpath("multivariate", fname))
end