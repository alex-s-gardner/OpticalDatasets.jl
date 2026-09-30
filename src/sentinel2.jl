# Sentinel-2 product names: `S2{A|B}_MSIL1C_YYYYMMDDTHHMMSS_N{baseline}_R{orbit}_T{tile}_{gentime}` —
# satellite, instrument and processing level, sensing start, processing baseline, relative orbit, MGRS
# tile, generation time. Unlike Landsat's, this carries the full sensing instant, so nothing external
# is needed to complete it.
#
# A STAC record for the same product often names it differently — earth-search's own `id` is
# `S2B_22WEB_20200612_0_L1C`, not this. Read `properties["s2:product_uri"]` (stripped of `.SAFE`) for
# the canonical name, not a STAC provider's own `id`; see `open_optical`.

"""
    sentinel2_identification(id) -> Identification

`id`'s own fields — the canonical Sentinel-2 product name (as ESA's `.SAFE` naming gives it, e.g.
`S2B_MSIL1C_20200612T150759_N0209_R025_T22WEB_20200612T184700`, with or without a trailing `.SAFE`),
not a STAC provider's shorter item id.
"""
function sentinel2_identification(id::AbstractString)
    name = endswith(id, ".SAFE") ? id[1:(end - 5)] : id
    parts = split(name, '_')
    length(parts) == 7 || throw(ArgumentError(
        "not a Sentinel-2 product name (expected 7 underscore-separated fields): $id"))
    missat, sensor_correction, acqtime, _baseline, _orbit, _tile, _gentime = parts

    length(missat) == 3 && startswith(missat, "S2") || throw(ArgumentError(
        "Sentinel-2 product name must start with `S2` followed by the satellite letter: $id"))
    satellite = missat[2:end]

    length(sensor_correction) >= 4 && startswith(sensor_correction, "MSI") || throw(ArgumentError(
        "Sentinel-2 product name's second field must be `MSI` followed by the correction level: $id"))
    sensor, correction_level = sensor_correction[1:3], sensor_correction[4:end]

    acquisition_time = DateTime(acqtime, dateformat"yyyymmdd\THHMMSS")

    return Identification(String(name), "S", satellite, sensor, correction_level, acquisition_time,
                          nothing, nothing, nothing, nothing, nothing)
end
