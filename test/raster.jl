# The lazy reader, on a tiled DEFLATE GeoTIFF built here rather than fetched: the layout under test is
# Landsat Collection 2's — tiled, compressed, `UInt16` — and a fixture pins it without a network.

using OpticalDatasets, Test
import ArchGDAL
import DiskArrays

# `(row, col)` truth, and the file GDAL writes from it. ArchGDAL takes `(x, y)`, so the array written is
# the transpose of what `OpticalRaster` must hand back.
function tiled_fixture(path, nrows, ncols; blockx = 128, blocky = 128, tiled = true)
    truth = UInt16[(r * 7919 + c * 104_729) % 65_536 for r in 1:nrows, c in 1:ncols]
    # GDAL requires a tile edge to be a multiple of 16, so a one-line block means a *striped* file and
    # `TILED=YES` must be left off rather than set with a smaller edge.
    options = tiled ? ["TILED=YES", "COMPRESS=DEFLATE",
                       "BLOCKXSIZE=$blockx", "BLOCKYSIZE=$blocky"] :
                      ["COMPRESS=DEFLATE", "BLOCKYSIZE=$blocky"]
    ArchGDAL.create(path; driver = ArchGDAL.getdriver("GTiff"), width = ncols, height = nrows,
                    nbands = 1, dtype = UInt16, options) do ds
        ArchGDAL.write!(ds, permutedims(truth), 1)
    end
    return truth
end

@testset "OpticalRaster reads a tiled, compressed band" begin
    mktempdir() do dir
        path = joinpath(dir, "tiled.tif")
        nrows, ncols = 600, 501
        truth = tiled_fixture(path, nrows, ncols)

        r = open_optical(path)
        try
            @test size(r) == (nrows, ncols)
            @test eltype(r) == UInt16
            @test r.chunk == (128, 128)
            @test DiskArrays.haschunks(r) isa DiskArrays.Chunked
            @test size(DiskArrays.eachchunk(r)) == (cld(nrows, 128), cld(ncols, 128))

            # Whole extent, a chunk-aligned window, a window straddling tiles, and the far corner, which
            # is a partial tile on both axes.
            for (rs, cs) in ((1:nrows, 1:ncols), (129:256, 129:256), (100:300, 60:400),
                             (580:600, 490:501))
                @test read_window(r, rs, cs) == truth[rs, cs]
            end

            # The `DiskArrays` indexing path, which goes through `readblock!` rather than `read_window`.
            @test r[100:300, 60:400] == truth[100:300, 60:400]
            @test r[7, 11] == truth[7, 11]

            @test_throws BoundsError read_window(r, 1:(nrows + 1), 1:ncols)

            # `read_window!` into a caller's array, including the converting form the pipeline uses:
            # a `UInt16` band read straight into `Float32` without the integer scene ever existing.
            into = Matrix{UInt16}(undef, nrows, ncols)
            @test read_window!(into, r, 1:nrows, 1:ncols) === into
            @test into == truth
            asfloat = Matrix{Float32}(undef, 201, 341)
            read_window!(asfloat, r, 100:300, 60:400)
            @test asfloat == Float32.(truth[100:300, 60:400])
            # Zero converts exactly, which is what lets a no-data test run on the converted values.
            @test findall(iszero, asfloat) == findall(iszero, truth[100:300, 60:400])
            @test_throws DimensionMismatch read_window!(Matrix{Float32}(undef, 5, 5), r, 1:10, 1:10)
        finally
            close(r)
        end

        # Concurrency is a pool size and must not change the answer — one handle and several agree.
        for c in (1, 2, 5)
            r2 = open_optical(path; concurrency = c)
            try
                @test read_window(r2, 1:nrows, 1:ncols) == truth
            finally
                close(r2)
            end
        end

        @test_throws ArgumentError open_optical(path; concurrency = 0)
    end
end

@testset "an untiled band still reports a usable chunk grid" begin
    # A striped GeoTIFF reports a block height of one line. The reader must not divide by a zero edge or
    # produce a degenerate grid.
    mktempdir() do dir
        path = joinpath(dir, "striped.tif")
        truth = tiled_fixture(path, 64, 40; blocky = 1, tiled = false)
        r = open_optical(path)
        try
            @test size(r) == (64, 40)
            @test r.chunk[2] == 40
            @test read_window(r, 1:64, 1:40) == truth
        finally
            close(r)
        end
    end
end
