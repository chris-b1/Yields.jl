# bootstrapped class of curve methods
"""
    Boostrap(interpolation_method=QuadraticSpline)
    
This `YieldCurveFitParameters` object defines the interpolation method to use when bootstrapping the curve. Provided options are `QuadraticSpline()` (the default) and `LinearSpline()`. You may also pass a custom interpolation method with the function signature of `f(xs, ys) -> f(x) -> y`.

If constructing curves and the rates are not `Rate`s (ie you pass a `Vector{Float64}`), then they will be interpreted as `Periodic(1)` `Rate`s, except the [`Par`](@ref) curve, which is interpreted as `Periodic(2)` `Rate`s. [`CMT`](@ref) and [`OIS`](@ref) FinanceCore.CompoundingFrequency assumption depends on the corresponding maturity.

See for more:

- [`Zero`](@ref)
- [`Forward`](@ref)
- [`Par`](@ref)
- [`CMT`](@ref)
- [`OIS`](@ref)
"""
struct Bootstrap{T} <: YieldCurveFitParameters
    interpolation::T
end
__default_rate_interpretation(ns,r::T) where {T<:Rate} = r
__default_rate_interpretation(::Type{Bootstrap{T}},r::U) where {T,U<:Real} = Periodic(r,1)

function Bootstrap()
    return Bootstrap(QuadraticSpline())
end

struct BootstrapCurve{T,U,V} <: AbstractYieldCurve
    rates::T
    maturities::U
    zero::V # function time -> continuous zero rate
end
FinanceCore.discount(yc::T, time) where {T<:BootstrapCurve} = exp(-yc.zero(time) * time)

__ratetype(::Type{BootstrapCurve{T,U,V}}) where {T,U,V}= Yields.Rate{Float64, typeof(DEFAULT_COMPOUNDING)}

# Forward curves

"""
    ForwardStarting(curve,forwardstart)

Rebase a `curve` so that `discount`/`accumulation`/etc. are re-based so that time zero from the new curves perspective is the given `forwardstart` time.

# Examples

```julia-repl
julia> zero = [5.0, 5.8, 6.4, 6.8] ./ 100
julia> maturity = [0.5, 1.0, 1.5, 2.0]
julia> curve = Yields.Zero(zero, maturity)
julia> fwd = Yields.ForwardStarting(curve, 1.0)

julia> FinanceCore.discount(curve,1,2)
0.9275624570410582

julia> FinanceCore.discount(fwd,1) # `curve` has effectively been reindexed to `1.0`
0.9275624570410582
```

# Extended Help

While `ForwardStarting` could be nested so that, e.g. the third period's curve is the one-period forward of the second period's curve, it will be more efficient to reuse the initial curve from a runtime and compiler perspective.

`ForwardStarting` is not used to construct a curve based on forward rates. See  [`Forward`](@ref) instead.
"""
struct ForwardStarting{T,U} <: AbstractYieldCurve
    curve::U
    forwardstart::T
end
__ratetype(::Type{ForwardStarting{T,U}}) where {T,U}= __ratetype(U)

function FinanceCore.discount(c::ForwardStarting, to)
    FinanceCore.discount(c.curve, c.forwardstart, to + c.forwardstart)
end

function Base.zero(c::ForwardStarting, to,cf::C) where {C<:FinanceCore.CompoundingFrequency}
    z = forward(c.curve,c.forwardstart,to+c.forwardstart)
    return convert(cf,z)
end


"""
    Constant(rate::Real, cf::CompoundingFrequency=Periodic(1))
    Constant(r::Rate)

Construct a yield object where the spot rate is constant for all maturities. If `rate` is not a `Rate` type, will assume `Periodic(1)` for the compounding frequency

# Examples

```julia-repl
julia> y = Yields.Constant(0.05)
julia> FinanceCore.discount(y,2)
0.9070294784580498     # 1 / (1.05) ^ 2
```
"""
struct Constant{T} <: AbstractYieldCurve
    rate::T
    Constant(rate::T) where {T<:Rate} = new{T}(rate)
end

__ratetype(::Type{Constant{T}}) where {T} = T
__default_rate_interpretation(::Type{Constant},r) = Periodic(r,1)
FinanceCore.CompoundingFrequency(c::Constant{T}) where {T} = c.rate.compounding

function Constant(rate::T) where {T<:Real}
    r = __default_rate_interpretation(Constant,rate)
    return Constant(r)
end

Base.zero(c::Constant, time) = c.rate
Base.zero(c::Constant, time, cf::FinanceCore.CompoundingFrequency) = convert(cf, c.rate)
FinanceCore.rate(c::Constant) = c.rate
FinanceCore.rate(c::Constant, time) = c.rate
FinanceCore.discount(r::Constant, time) = FinanceCore.discount(r.rate, time)
FinanceCore.discount(r::Constant, from, to) = FinanceCore.discount(r.rate, to - from)
FinanceCore.accumulation(r::Constant, time) = accumulation(r.rate, time)
FinanceCore.accumulation(r::Constant, from, to) = accumulation(r.rate, to - from)

"""
    Step(rates,times)

Create a yield curve object where the applicable rate is the effective rate of interest applicable until corresponding time. If `rates` is not a `Vector{Rate}`, will assume `Periodic(1)` type.

The last rate will be applied to any time after the last time in `times`.

# Examples

```julia-repl
julia>y = Yields.Step([0.02,0.05], [1,2])

julia>rate(y,0.5)
0.02

julia>rate(y,1.5)
0.05

julia>rate(y,2.5)
0.05
```
"""
struct Step{R,T} <: AbstractYieldCurve
    rates::R
    times::T
    function Step(rates,times=eachindex(rates))
        r = __default_rate_interpretation.(Step,rates)
        new{typeof(r),typeof(times)}(r, times)
    end
end
__ratetype(::Type{Step{R,T}}) where {R,T}= eltype(R)
__default_rate_interpretation(::Type{Step},r) = Periodic(r,1)
FinanceCore.CompoundingFrequency(c::Step{T}) where {T} = first(c.rates).compounding



function FinanceCore.discount(y::Step, time)
    v = 1.0
    last_time = 0.0


    for (rate,t) in zip(y.rates,y.times)
        duration = min(time - last_time,t-last_time)
        v *= FinanceCore.discount(rate,duration)
        last_time = t
        (last_time > time) && return v
        
    end

    # if we did not return in the loop, then we extend the last rate
    v *= FinanceCore.discount(last(y.rates), time - last_time)
    return v
end



function Zero(b::Bootstrap,rates, maturities)
    rates = __default_rate_interpretation.(typeof(b),rates)
    return _zero_inner(rates,maturities,b.interpolation)
end

# zero is different than the other boostrapped curves in that it doesn't actually need to bootstrap 
# because the rate are already zero rates. Instead, we just cut straight to the 
# appropriate interpolation function based on the type dispatch.
function _zero_inner(rates, maturities, interp::QuadraticSpline)
    continuous_zeros = rate.(Continuous.(rates))
    return BootstrapCurve(
        rates,
        maturities,
        cubic_interp([0.0; maturities],[first(continuous_zeros); continuous_zeros])
    )
end

function _zero_inner(rates, maturities, interp::LinearSpline)
    continuous_zeros = rate.(Continuous.(rates))
    return BootstrapCurve(
        rates,
        maturities,
        linear_interp([0.0; maturities],[first(continuous_zeros); continuous_zeros])
    )
end

# fallback for user provided interpolation function
function _zero_inner(rates, maturities, interp::T) where {T}
    continuous_zeros = rate.(Continuous.(rates))
    return BootstrapCurve(
        rates,
        maturities,
        interp([0.0; maturities],[first(continuous_zeros); continuous_zeros])
    )
end

function Par(b::Bootstrap,rates, maturities)
    rates = __coerce_rate.(rates,Periodic(2))
    return BootstrapCurve(
        rates,
        maturities,
        # assume that maturities less than or equal to 12 months are settled once, otherwise semi-annual
        # per Hull 4.7
        bootstrap(rates, maturities, [m <= 1 ? nothing : 1 / r.compounding.frequency for (r, m) in zip(rates, maturities)], b.interpolation)
    )
end

function Forward(b::Bootstrap,rates, maturities)
    rates = __default_rate_interpretation.(typeof(b),rates)
    # convert to zeros and pass to Zero
    disc_v = Vector{Float64}(undef, length(rates))

    v = 1.0

    for (i,r) = enumerate(rates)
        Δt = maturities[i] - (i == 1 ? 0 : maturities[i-1])
        v *= FinanceCore.discount(r, Δt)
        disc_v[i] = v
    end

    z = (1.0 ./ disc_v) .^ (1 ./ maturities) .- 1 # convert disc_v to zero
    return Zero(b,z, maturities)
end

function CMT(b::Bootstrap,rates, maturities)
    rs = map(zip(rates, maturities)) do (r, m)
        if m <= 1
            Rate(r, Periodic(1 / m))
        else
            Rate(r, Periodic(2))
        end
    end

    CMT(b,rs, maturities)
end

function CMT(b::Bootstrap,rates::Vector{T}, maturities) where {T<:Rate}
    return BootstrapCurve(
        rates,
        maturities,
        # assume that maturities less than or equal to 12 months are settled once, otherwise semi-annual
        # per Hull 4.7
        bootstrap(rates, maturities, [m <= 1 ? nothing : 0.5 for m in maturities], b.interpolation)
    )
end


function OIS(b::Bootstrap,rates, maturities)
    rs = map(zip(rates, maturities)) do (r, m)
        if m <= 1
            Rate(r, Periodic(1 / m))
        else
            Rate(r, Periodic(4))
        end
    end

    return OIS(b,rs, maturities)
end
function OIS(b::Bootstrap,rates::Vector{<:Rate}, maturities)
    return BootstrapCurve(
        rates,
        maturities,
        # assume that maturities less than or equal to 12 months are settled once, otherwise quarterly
        # per Hull 4.7
        bootstrap(rates, maturities, [m <= 1 ? nothing : 1 / 4 for m in maturities], b.interpolation)
    )
end
