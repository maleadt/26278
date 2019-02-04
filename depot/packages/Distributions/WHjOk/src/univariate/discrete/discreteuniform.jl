""" """ struct DiscreteUniform <: DiscreteUnivariateDistribution
    a::Int
    b::Int
    pv::Float64
    function DiscreteUniform(a::Real, b::Real)
        @check_args(DiscreteUniform, a <= b)
        new(a, b, 1.0 / (b - a + 1))
    end
    DiscreteUniform(b::Real) = DiscreteUniform(0, b)
    DiscreteUniform() = new(0, 1, 0.5)
end
@distr_support DiscreteUniform d.a d.b
span(d::DiscreteUniform) = d.b - d.a + 1
probval(d::DiscreteUniform) = d.pv
params(d::DiscreteUniform) = (d.a, d.b)
show(io::IO, d::DiscreteUniform) = show(io, d, (:a, :b))
mean(d::DiscreteUniform) = middle(d.a, d.b)
median(d::DiscreteUniform) = middle(d.a, d.b)
var(d::DiscreteUniform) = (span(d)^2 - 1.0) / 12.0
skewness(d::DiscreteUniform) = 0.0
function kurtosis(d::DiscreteUniform)
    n2 = span(d)^2
    -1.2 * (n2 + 1.0) / (n2 - 1.0)
end
entropy(d::DiscreteUniform) = log(span(d))
mode(d::DiscreteUniform) = d.a
modes(d::DiscreteUniform) = [d.a:d.b]
cdf(d::DiscreteUniform, x::Int) = (x < d.a ? 0.0 :
                                   x > d.b ? 1.0 :
                                   (floor(Int,x) - d.a + 1.0) * d.pv)
pdf(d::DiscreteUniform, x::Int) = insupport(d, x) ? d.pv : 0.0
logpdf(d::DiscreteUniform, x::Int) = insupport(d, x) ? log(d.pv) : -Inf
quantile(d::DiscreteUniform, p::Float64) = d.a + floor(Int,p * span(d))
function mgf(d::DiscreteUniform, t::Real)
    a, b = d.a, d.b
    u = b - a + 1
    t == 0 ? 1.0 : (exp(t*a) * expm1(t*u)) / (u*expm1(t))
end
function cf(d::DiscreteUniform, t::Real)
    a, b = d.a, d.b
    u = b - a + 1
    t == 0 ? complex(1.0) : (im*cos(t*(a+b)/2) + sin(t*(a-b-1)/2)) / (u*sin(t/2))
end
rand(d::DiscreteUniform) = rand(GLOBAL_RNG, d)
rand(rng::AbstractRNG, d::DiscreteUniform) = rand(rng, d.a:d.b)
function fit_mle(::Type{DiscreteUniform}, x::AbstractArray{T}) where T <: Real
    if isempty(x)
        throw(ArgumentError("x cannot be empty."))
    end
    xmin = xmax = x[1]
    for i = 2:length(x)
        @inbounds xi = x[i]
        if xi < xmin
            xmin = xi
        elseif xi > xmax
            xmax = xi
        end
    end
    DiscreteUniform(xmin, xmax)
end