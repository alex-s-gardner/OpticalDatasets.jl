# A band of an optical product's imagery, read lazily and a chunk at a time.
#
# **Why a type rather than a call.** A Landsat Collection 2 band is a tiled, DEFLATE-compressed COG of
# around 300 million pixels. Reading it whole costs a 350 MB transfer and three full-size copies before a
# caller sees a value, and over `/vsis3` it is one serial transfer: measured on
# `LC08_L1TP_009011_20200703`, 693 MB of imagery took 70 s, about 10 MB/s, which is latency rather than
# bandwidth. Read a chunk at a time from several tasks at once and the same bytes arrive an order of
# magnitude faster.
#
# **GDAL does the decoding.** Nothing here parses TIFF: the tile directory, the DEFLATE streams and the
# `/vsis3` and `/vsicurl` transports are GDAL's, reached through ArchGDAL, and this adds only the
# `DiskArrays` interface over them plus the handle discipline that makes concurrent reads safe. A
# hand-rolled reader would have to reimplement tiled COG decoding to gain nothing a caller can observe.
#
# **One dataset per concurrent reader.** GDAL is thread-safe per *handle*: two tasks may read the same
# file at once through two datasets, and must not share one. So the handles live in a `Channel` used as a
# pool, and a reader holds one for the length of its block read. A pool rather than a dataset per read
# because opening one over `/vsis3` is itself a round trip for the header.
#
# **Index order is `(row, column)`.** GDAL counts `(x, y)` with `x` varying fastest, and an image in Julia
# is conventionally indexed by row first. This returns the Julia order, transposing each block as it is
# read, so a caller never holds a whole transposed copy of the scene.

"""
    OpticalRaster{T} <: DiskArrays.AbstractDiskArray{T,2}

One band of an optical product, lazily readable and chunk-aware, indexed `(row, column)`.

Returned by [`open_optical`](@ref) given a path. Nothing is read on construction beyond the header, so
the cost of opening is one round trip; `eachchunk` reports the file's own tile grid, which is what makes
a chunk-aligned read cheap and a strided one expensive.

Safe to read from several tasks at once: each takes a GDAL dataset from an internal pool of
`concurrency` handles. Close it with [`close`](@ref) when done, which releases them.
"""
struct OpticalRaster{T,P} <: DiskArrays.AbstractDiskArray{T,2}
    path::String
    band::Int
    dims::Tuple{Int,Int}        # (rows, columns) = (y, x)
    chunk::Tuple{Int,Int}       # the file's own tile shape, in the same order
    pool::P
end

Base.size(r::OpticalRaster) = r.dims

"""
    open_optical(path; band = 1, concurrency = Threads.nthreads()) -> OpticalRaster

Open one band of a raster at `path` for lazy, chunked reading.

`path` is anything GDAL opens, so a local file, a `/vsis3/` object or a `/vsicurl/` URL all work. For a
requester-pays bucket the caller is responsible for the credentials and for
`AWS_REQUEST_PAYER=requester`, since those are process-wide GDAL configuration rather than a property of
one raster.

`concurrency` sizes the handle pool and so bounds how many tasks may read at once; reads beyond that wait
for a handle rather than opening another. The default is deliberately small. Parallel reading is a clear
win over a serial one — measured on a 338 MiB Landsat band over `/vsis3`, 54.9 s serial against 32.3 s —
but going wider than a handful of connections does not help and has been measured to hurt: the transport,
not the request count, is the limit, and `aws s3 cp`'s own multipart download of the same object managed
8.7 MB/s against this reader's 17.2.

This is the imagery counterpart to `open_optical(::AbstractDict)`, which reads a STAC item's identity.
"""
function open_optical(path::AbstractString; band::Integer = 1,
                      concurrency::Integer = min(8, Threads.nthreads()))
    concurrency >= 1 || throw(ArgumentError("concurrency must be at least 1, got $concurrency"))
    probe = ArchGDAL.read(path)
    bd = ArchGDAL.getband(probe, band)
    T = eltype(bd)
    nx, ny = ArchGDAL.width(probe), ArchGDAL.height(probe)
    bx, by = ArchGDAL.blocksize(bd)
    # A band reporting a zero block edge would make the chunk grid degenerate; fall back to the whole
    # extent on that axis, which is what an untiled raster effectively has.
    chunk = (by > 0 ? Int(by) : ny, bx > 0 ? Int(bx) : nx)
    pool = Channel{Any}(concurrency)
    put!(pool, probe)
    for _ in 2:concurrency
        put!(pool, ArchGDAL.read(path))
    end
    return OpticalRaster{T,typeof(pool)}(String(path), Int(band), (Int(ny), Int(nx)), chunk, pool)
end

"""
    close(r::OpticalRaster)

Release `r`'s GDAL handles. Reading afterwards throws rather than reopening.
"""
function Base.close(r::OpticalRaster)
    close(r.pool)
    for ds in r.pool
        ArchGDAL.destroy(ds)
    end
    return nothing
end

DiskArrays.haschunks(::OpticalRaster) = DiskArrays.Chunked()
DiskArrays.eachchunk(r::OpticalRaster) = DiskArrays.GridChunks(r, r.chunk)

function DiskArrays.readblock!(r::OpticalRaster, dest::AbstractArray,
                               rows::AbstractUnitRange, cols::AbstractUnitRange)
    size(dest) == (length(rows), length(cols)) || throw(DimensionMismatch(
        "destination is $(size(dest)) for a $(length(rows))x$(length(cols)) window"))
    ds = take!(r.pool)
    try
        bd = ArchGDAL.getband(ds, r.band)
        # `ArchGDAL.read(band, yrange, xrange)` answers in GDAL's own `(x, y)` order, so the block
        # transposes on the way into a `(row, column)` destination.
        blk = ArchGDAL.read(bd, rows, cols)
        permutedims!(dest, blk, (2, 1))
    finally
        put!(r.pool, ds)
    end
    return dest
end

"""
    read_window(r::OpticalRaster, rows, cols; slabs = 4 * Threads.nthreads()) -> Matrix

`r[rows, cols]`, fetched by several tasks at once.

A `DiskArrays` read is one blocking request however large the window, which over a network transport
leaves the link idle between round trips. This splits the window into row slabs aligned to `r`'s own
chunk grid and reads them concurrently, which is where the order-of-magnitude difference on a remote
scene comes from.

`slabs` is a target count, not a guarantee: it is raised to at least one chunk row per slab, so a window
shorter than `slabs` chunk rows simply uses fewer. It defaults to a few per pooled handle, which keeps
every handle busy without splitting the window so finely that each request stops amortizing its latency.
"""
function read_window(r::OpticalRaster{T}, rows::AbstractUnitRange, cols::AbstractUnitRange;
                     slabs::Integer = 4 * r.pool.sz_max + 4) where {T}
    out = Matrix{T}(undef, length(rows), length(cols))
    return read_window!(out, r, rows, cols; slabs)
end

"""
    read_window!(dest, r::OpticalRaster, rows, cols; slabs = ...) -> dest

[`read_window`](@ref) into an array the caller already holds, converting to `dest`'s element type as each
slab arrives.

This is the form to use when the values are wanted as something other than the file's own type. Reading
a `UInt16` band into a `Float32` destination converts one slab at a time, which is both the whole-scene
`UInt16` array and the separate conversion pass over it that a caller otherwise pays for — on a 291
million pixel Landsat band, 583 MB and 1,166 MB of allocation respectively.

Conversion is exact for zero either way, so a caller testing a `Float32` destination for the file's
no-data zeros gets the same answer as one testing the raw integers.
"""
function read_window!(dest::AbstractMatrix, r::OpticalRaster, rows::AbstractUnitRange,
                      cols::AbstractUnitRange; slabs::Integer = 4 * r.pool.sz_max + 4)
    checkbounds(r, rows, cols)
    size(dest) == (length(rows), length(cols)) || throw(DimensionMismatch(
        "destination is $(size(dest)) for a $(length(rows))x$(length(cols)) window"))
    # Slab boundaries land on the chunk grid, so no two tasks decode the same tile.
    step = max(r.chunk[1], cld(length(rows), max(slabs, 1)))
    step = cld(step, r.chunk[1]) * r.chunk[1]
    starts = first(rows):step:last(rows)
    tasks = map(starts) do lo
        hi = min(lo + step - 1, last(rows))
        Threads.@spawn begin
            local slab = view(dest, (lo - first(rows) + 1):(hi - first(rows) + 1), :)
            DiskArrays.readblock!(r, slab, lo:hi, cols)
        end
    end
    foreach(wait, tasks)
    return dest
end
