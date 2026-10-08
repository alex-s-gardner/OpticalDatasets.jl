# A band of an optical product's imagery, read lazily and a chunk at a time.
#
# A Landsat Collection 2 band is a tiled, DEFLATE-compressed COG of around 300 million pixels, and a
# Sentinel-2 band a tiled JPEG 2000 file. ChunkManifests.jl scans either into a Zarr array whose chunks are
# the file's own tiles, located from the file's metadata without reading a pixel; a window then reads and
# decodes the tiles it covers, fetching them concurrently from a remote object and decoding them on
# several threads.
#
# **Index order is `(row, column)`.** The file stores rows one after another, which Zarr.jl reports as
# `(x, y)`; the array is permuted so that an image is indexed by row first, as it is conventionally in
# Julia.

"""
    OpticalRaster{T}

One band of an optical product, lazily readable and chunk-aware, indexed `(row, column)`: the band's
scanned Zarr array, permuted.

Returned by [`open_optical`](@ref) given a path. `eachchunk` reports the file's own tile grid, which is
what makes a chunk-aligned read cheap and a strided one expensive. Safe to read from several tasks at once.
"""
const OpticalRaster{T} = DiskArrays.PermutedDiskArray{T,2,(2, 1),(2, 1),<:Zarr.ZArray{T,2}}

"""
    open_optical(path; transport = nothing) -> OpticalRaster

Open the band at `path` — a GeoTIFF or COG, or a JPEG 2000 file — for lazy, chunked reading.

`path` is a local file, an `https://` URL or an `s3://` URI; a remote object is read in place. `transport`
is the ChunkManifests.jl transport to read it through, which a requester-pays bucket needs, as Landsat's
is:

```julia
using AWSS3, ChunkManifests
open_optical("s3://usgs-landsat/collection02/.../LC08_..._B8.TIF";
             transport = S3Transport("usgs-landsat"; requesterpays = true))
```

Only the metadata is read on opening; nothing of the imagery until it is indexed. A file holding several
bands is refused: Landsat and Sentinel-2 distribute one band per file.

This is the imagery counterpart to `open_optical(::AbstractDict)`, which reads a STAC item's identity.
"""
function open_optical(path::AbstractString; transport = nothing)
    startswith(path, "/vsi") && throw(ArgumentError(
        "`$path` is a GDAL virtual path; name the object itself, as `s3://bucket/key` for `/vsis3/` " *
        "or the `https://` URL for `/vsicurl/`"))
    a = scan(path; level = 0, transport)["0"]["data"]
    ndims(a) == 2 || throw(ArgumentError(
        "`$path` holds several bands; open_optical reads a single-band file"))
    return permutedims(a, (2, 1))
end

"""
    read_window(r::OpticalRaster, rows, cols) -> Matrix

`r[rows, cols]`: the tiles the window covers, fetched concurrently and decoded on several threads.
"""
read_window(r::OpticalRaster, rows::AbstractUnitRange, cols::AbstractUnitRange) = r[rows, cols]

"""
    read_window!(dest, r::OpticalRaster, rows, cols) -> dest

[`read_window`](@ref) into an array the caller already holds, converting to `dest`'s element type as each
tile is placed.

This is the form to use when the values are wanted as something other than the file's own type. Reading
a `UInt16` band into a `Float32` destination converts tile by tile, which saves both the whole-scene
`UInt16` array and the separate conversion pass over it that a caller otherwise pays for — on a 291
million pixel Landsat band, 583 MB and 1,166 MB of allocation respectively.

Conversion is exact for zero either way, so a caller testing a `Float32` destination for the file's
no-data zeros gets the same answer as one testing the raw integers.
"""
function read_window!(dest::AbstractMatrix, r::OpticalRaster, rows::AbstractUnitRange,
                      cols::AbstractUnitRange)
    checkbounds(r, rows, cols)
    size(dest) == (length(rows), length(cols)) || throw(DimensionMismatch(
        "destination is $(size(dest)) for a $(length(rows))x$(length(cols)) window"))
    DiskArrays.readblock!(r, dest, rows, cols)
    return dest
end
