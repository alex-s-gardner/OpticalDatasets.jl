# Landsat Collection 2 product IDs: `LXSS_LLLL_PPPRRR_YYYYMMDD_yyyymmdd_CC_TX` — sensor, satellite,
# correction level, WRS-2 path/row, acquisition date, processing date, collection number, collection
# category. Every field but the acquisition time of day is already in the string; USGS's own naming
# specification is the source, not a sample observed once.

# `X` in `LX..`: `C` OLI/TIRS combined (Landsat 8/9), `O` OLI only, `T` TM (Landsat 4/5) or TIRS only,
# `E` ETM+ (Landsat 7), `M` MSS.
function _parse_landsat_id(id::AbstractString)
    parts = split(id, '_')
    length(parts) == 7 || throw(ArgumentError(
        "not a Landsat Collection 2 product id (expected 7 underscore-separated fields): $id"))
    sensor_sat, correction_level, pathrow, acqdate, procdate, collection, category = parts

    length(sensor_sat) == 4 && sensor_sat[1] == 'L' || throw(ArgumentError(
        "Landsat product id must start with `L` followed by a sensor code and two digits: $id"))
    sensor = string(sensor_sat[2])
    satellite = string(parse(Int, sensor_sat[3:4]))

    length(pathrow) == 6 || throw(ArgumentError("Landsat path/row field must be 6 digits: $id"))
    path, row = parse(Int, pathrow[1:3]), parse(Int, pathrow[4:6])

    return (; mission = "L", satellite, sensor, correction_level, path, row,
            collection_number = parse(Int, collection), collection_category = category,
            processing_date = procdate, acquisition_date = acqdate)
end

"""
    landsat_identification(id, acquisition_time::DateTime) -> Identification

`id`'s own fields, plus `acquisition_time` for the one thing a Landsat product ID does not carry: the
time of day. `id` carries the *date*, and this checks the two agree — a mismatch means `id` and
`acquisition_time` describe different acquisitions, not that either is malformed on its own, so it is
not silently resolved by preferring one.
"""
function landsat_identification(id::AbstractString, acquisition_time::DateTime)
    p = _parse_landsat_id(id)
    Dates.format(acquisition_time, dateformat"yyyymmdd") == p.acquisition_date || throw(ArgumentError(
        "`id` names acquisition date $(p.acquisition_date) but `acquisition_time` is " *
        "$acquisition_time; they must describe the same acquisition"))
    return Identification(String(id), p.mission, p.satellite, p.sensor, p.correction_level,
                          acquisition_time, p.path, p.row, p.collection_number,
                          p.collection_category, p.processing_date)
end
