"""
    OpticalDatasets

Read a Landsat or Sentinel-2 product's identity from a STAC item, into one sensor-neutral type.

```julia
using OpticalDatasets, JSON3

item = JSON3.read(read("landsat_item.json", String))
id = open_optical(item)
id.mission, id.satellite, id.sensor, id.acquisition_time
```

[`open_optical`](@ref) takes any `AbstractDict` — the result of parsing a STAC item JSON with whatever
JSON library a caller already has, so this package depends on none. It reads `properties`'
`s2:product_uri` when present (a Sentinel-2 product) and `datetime` otherwise (a Landsat one, whose
own product id names a date but not a time of day).

A Landsat product id and a Sentinel-2 product name are parsed directly by
[`landsat_identification`](@ref) and [`sentinel2_identification`](@ref), for a caller who already has
the id string and does not need `open_optical`'s STAC-shaped dispatch.

This package reads identity only. Converting one into
[`AutoRIFT.ImagePairInfo`](https://github.com/alex-s-gardner/AutoRIFT.jl) belongs to that package,
the same way `SLCDatasets.Identification` is consumed there — see `ItsLiveAutoRIFT`'s docstring.
"""
module OpticalDatasets

using Dates: Dates, DateTime, @dateformat_str

include("types.jl")
include("landsat.jl")
include("sentinel2.jl")

export Identification, open_optical, landsat_identification, sentinel2_identification

# ISO-8601 as STAC's `datetime` property gives it: a trailing `Z`, and a fractional-seconds field that
# may hold more digits than `DateTime`'s millisecond precision can carry — truncated, not rounded,
# matching how a Landsat product id's own date field is already millisecond-oblivious.
function _parse_iso_datetime(s::AbstractString)
    s = rstrip(s, 'Z')
    if occursin('.', s)
        base, frac = split(s, '.'; limit = 2)
        return DateTime(base * "." * rpad(first(frac, 3), 3, '0'),
                        dateformat"yyyy-mm-ddTHH:MM:SS.sss")
    end
    return DateTime(s, dateformat"yyyy-mm-ddTHH:MM:SS")
end

"""
    open_optical(stac::AbstractDict) -> Identification

The product a STAC item describes, as an [`Identification`](@ref).

Sentinel-2: from `properties["s2:product_uri"]`, which carries the full sensing instant already — a
STAC provider's own `id` is not used, since it need not be the canonical product name (earth-search's
is `S2B_22WEB_20200612_0_L1C`, not the SAFE name).

Landsat: from the top-level `id` (the canonical product id, on every STAC provider checked) plus
`properties["datetime"]` for the time of day the id itself does not carry.
"""
function open_optical(stac::AbstractDict)
    props = get(stac, "properties", Dict{String,Any}())
    uri = get(props, "s2:product_uri", nothing)
    uri === nothing || return sentinel2_identification(uri)

    id = get(stac, "id", nothing)
    id === nothing && throw(ArgumentError(
        "the STAC item has neither `properties.s2:product_uri` (Sentinel-2) nor a top-level `id` " *
        "(Landsat) — cannot determine which product this is"))
    dt = get(props, "datetime", nothing)
    dt === nothing && throw(ArgumentError(
        "the STAC item has no `properties.datetime`, needed to complete Landsat product id " *
        "`$id`'s acquisition time"))
    return landsat_identification(id, _parse_iso_datetime(dt))
end

end
