# The scene identity: what a Landsat product ID or a Sentinel-2 product URI already encodes, plus
# the one acquisition time neither encodes to millisecond precision on its own.
#
# Landsat's ID carries a date but not a time of day; a caller must supply the acquisition instant
# separately, from the product's own metadata (a STAC item's `datetime`, or an MTL's
# `DATE_ACQUIRED`/`SCENE_CENTER_TIME`). Sentinel-2's product URI carries the full sensing instant
# already, so nothing external is needed for that field on that path — see `open_optical`.

"""
    Identification

What a Landsat or Sentinel-2 product's own name already says about it.

`mission` is `"L"` or `"S"`, matching the single-letter code ITS_LIVE's `img_pair_info` uses;
`satellite` is the spacecraft number (`"8"`, `"5"`, `"2B"`, ...); `sensor` is the instrument code
(`"C"`, `"T"`, `"E"` for Landsat's OLI/TIRS, TM, ETM+; `"MSI"` for Sentinel-2).

`path`/`row`/`collection_number`/`collection_category`/`processing_date` are Landsat-only and
`nothing` for a Sentinel-2 product, which has no such fields.
"""
struct Identification
    id::String
    mission::String
    satellite::String
    sensor::String
    correction_level::String
    acquisition_time::DateTime
    path::Union{Int,Nothing}
    row::Union{Int,Nothing}
    collection_number::Union{Int,Nothing}
    collection_category::Union{String,Nothing}
    processing_date::Union{String,Nothing}
end
