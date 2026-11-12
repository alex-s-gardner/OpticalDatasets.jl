"""
    OpticalDatasets

Read a Landsat or Sentinel-2 product's identity from a STAC item, into one sensor-neutral type.

```julia
using OpticalDatasets, JSON3

item = JSON3.read(read("landsat_item.json", String))
id = open_optical(item)
id.mission, id.satellite, id.sensor, id.acquisition_time   # a NanoDates.NanoDate
```

[`open_optical`](@ref) takes any `AbstractDict` — the result of parsing a STAC item JSON with whatever
JSON library a caller already has, so this package depends on none. It reads `properties`'
`s2:product_uri` when present (a Sentinel-2 product) and `datetime` otherwise (a Landsat one, whose
own product id names a date but not a time of day).

A Landsat product id and a Sentinel-2 product name are parsed directly by
[`landsat_identification`](@ref) and [`sentinel2_identification`](@ref), for a caller who already has
the id string and does not need `open_optical`'s STAC-shaped dispatch.

Given a path instead of a STAC item, [`open_optical`](@ref) returns an [`OpticalRaster`](@ref): one
band of the imagery, read lazily a chunk at a time and safe to read from several tasks at once.
ChunkManifests.jl locates the tiles of a GeoTIFF, COG or JPEG 2000 file and reads them, from a local file,
an `https://` URL or an `s3://` object; a window's tiles are fetched concurrently and decoded on several
threads, which is what makes a remote scene read at the link's speed rather than its latency.

Converting an `Identification` into an `ImagePairInfo` belongs to
[`ItsLiveOffsetProduction.jl`](https://github.com/alex-s-gardner/ItsLiveOffsetProduction.jl), which
owns ITS_LIVE product packaging — the same way `SLCDatasets.Identification` is consumed there.
"""
module OpticalDatasets

import ChunkManifests
using Dates: Dates, DateTime, Microsecond
using NanoDates: NanoDate
import DiskArrays
# Loaded for the ChunkManifests.jl extension that decodes a JPEG 2000 tile.
import OpenJpeg_jll
import Zarr

include("types.jl")
include("landsat.jl")
include("ephemeris.jl")
include("sentinel2.jl")
include("raster.jl")

export Identification, open_optical, landsat_identification, sentinel2_identification, parse_utc,
       OpticalRaster, read_window, read_window!, landsat_ephemeris, landsat_ephemeris_path

"""
    parse_utc(s) -> NanoDate

A UTC timestamp, `YYYY-MM-DDTHH:MM:SS[.f…][Z]` as a STAC item's `datetime` or a Landsat MTL's
`DATE_ACQUIRED`/`SCENE_CENTER_TIME` gives it, truncated to the microsecond. Parsed field by field: a
`DateFormat` parse builds its error messages at run time, which `juliac --trim` cannot compile.
"""
function parse_utc(s::AbstractString)
    t = endswith(s, "Z") ? s[1:(end - 1)] : s
    date, time = split(t, 'T'; limit = 2)
    ymd = split(date, '-')
    hms = split(time, ':')
    (length(ymd) == 3 && length(hms) == 3) || throw(ArgumentError("not a UTC timestamp: " * String(s)))
    sec = split(hms[3], '.'; limit = 2)
    us = 0
    if length(sec) == 2
        f = sec[2]
        all(isdigit, f) || throw(ArgumentError("not a UTC timestamp: " * String(s)))
        us = length(f) >= 6 ? parse(Int, view(f, 1:6)) : parse(Int, f) * 10^(6 - length(f))
    end
    whole = DateTime(parse(Int, ymd[1]), parse(Int, ymd[2]), parse(Int, ymd[3]), parse(Int, hms[1]),
                     parse(Int, hms[2]), parse(Int, sec[1]))
    return NanoDate(whole) + Microsecond(us)
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
    return landsat_identification(id, parse_utc(dt))
end

end
