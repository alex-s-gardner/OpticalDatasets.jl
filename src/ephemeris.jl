# A Landsat scene's own orbit, from the `_ANG.txt` beside its band rasters.
#
# The MTL carries only the four corner coordinates, which on a north-up L1 product are the raster's
# axis-aligned bounding box — not the imaged swath, so no scan direction is recoverable from them. The
# `_ANG.txt`'s `GROUP = EPHEMERIS` block carries the satellite's own ECEF trajectory at 1 s spacing,
# which gives the ground-track direction directly.

"""
    landsat_ephemeris(path) -> NamedTuple{(:time, :x, :y, :z)}

A Landsat scene's satellite ephemeris from its `_ANG.txt`: `time` in seconds of day, `x`/`y`/`z` in
ECEF meters.

`GROUP = EPHEMERIS` holds `NUMBER_OF_POINTS` samples as parenthesised lists spanning several lines,
`EPHEMERIS_ECEF_X = (-2513196.897534, -2519426.030063, ...`, which a line-at-a-time `KEY = VALUE`
reader would truncate to its first row without complaining — so this reads the whole block before
treating a list as closed.

The declared count is checked against all four parsed vectors rather than trusted: a truncated list
would otherwise produce a shorter trajectory, and the pair used to derive a bearing would come from
the wrong point in the orbit without any sign of it.
"""
function landsat_ephemeris(path::AbstractString)
    f = _ang_fields(path)
    get1(k) = haskey(f, k) ? f[k] : throw(ArgumentError(
        "$path has no $k; the ephemeris is what the ground-track direction is derived from"))
    t, x, y, z = get1("EPHEMERIS_TIME"), get1("EPHEMERIS_ECEF_X"),
                 get1("EPHEMERIS_ECEF_Y"), get1("EPHEMERIS_ECEF_Z")
    n = haskey(f, "NUMBER_OF_POINTS") ? Int(first(f["NUMBER_OF_POINTS"])) : length(t)
    all(v -> length(v) == n, (t, x, y, z)) || throw(ArgumentError(
        "$path declares $n ephemeris points but parsed " *
        "$(length(t))/$(length(x))/$(length(y))/$(length(z)); the list parse is wrong"))
    return (; time = t, x, y, z)
end

# Every numeric `KEY = VALUE` field of an `_ANG.txt`, scalars as one-element vectors. A separate
# parser from Landsat MTL reading because the format is not the same one — see `landsat_ephemeris`.
function _ang_fields(path::AbstractString)
    isfile(path) || throw(ArgumentError("no ANG file at $path"))
    out = Dict{String,Vector{Float64}}()
    text = read(path, String)
    key = nothing
    buf = Float64[]
    open_list = false
    for raw in split(text, '\n')
        s = strip(raw)
        if open_list
            done = occursin(')', s)
            append!(buf, _ang_numbers(s))
            if done
                out[key] = copy(buf)
                open_list = false
            end
            continue
        end
        i = findfirst('=', s)
        i === nothing && continue
        k = strip(s[1:prevind(s, i)])
        v = strip(s[nextind(s, i):end])
        (startswith(k, "GROUP") || startswith(k, "END_GROUP")) && continue
        if startswith(v, "(")
            key = String(k)
            buf = _ang_numbers(v)
            occursin(')', v) ? (out[key] = copy(buf)) : (open_list = true)
        else
            n = tryparse(Float64, v)
            n === nothing || (out[String(k)] = [n])
        end
    end
    isempty(out) && throw(ArgumentError("$path parsed to no numeric fields; is it an ANG file?"))
    return out
end

_ang_numbers(s::AbstractString) =
    [parse(Float64, m.match) for m in eachmatch(r"-?\d+\.?\d*(?:[eE][-+]?\d+)?", s)]

"""
    landsat_ephemeris_path(band_path) -> String

The `_ANG.txt` beside a Landsat band raster, on whatever route reached the band.

Derived from the band's own path rather than resolved separately, so a scene read from `/vsis3`
finds its ephemeris in the same bucket and one read from disk finds it in the same directory.
"""
landsat_ephemeris_path(band_path::AbstractString) =
    replace(band_path, r"_B\d+\.TIF$"i => "_ANG.txt")
