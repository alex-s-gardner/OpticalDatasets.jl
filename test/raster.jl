# The lazy reader, on files built here rather than fetched: a tiled DEFLATE GeoTIFF, Landsat Collection 2's
# layout — tiled, compressed, `UInt16` — and a tiled JPEG 2000 file, Sentinel-2's. Fixtures pin both
# without a network.

using OpticalDatasets, Test
import ArchGDAL
import DiskArrays

# `(row, col)` truth, and the file GDAL writes from it. ArchGDAL takes `(x, y)`, so the array written is
# the transpose of what `OpticalRaster` must hand back. GDAL writes the fixtures, and also decodes them
# for the JPEG 2000 comparison below, so the reader is checked against an independent implementation.
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
        @test r isa OpticalRaster{UInt16}
        @test size(r) == (nrows, ncols)
        @test eltype(r) == UInt16
        @test DiskArrays.haschunks(r) isa DiskArrays.Chunked
        @test map(length, first(DiskArrays.eachchunk(r))) == (128, 128)
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

        # Several tasks reading overlapping windows at once agree with one reading alone.
        wins = [(rand(1:300):600, rand(1:200):501) for _ in 1:16]
        @test fetch.([Threads.@spawn read_window(r, w...) for w in wins]) == [truth[w...] for w in wins]
    end
end

@testset "an untiled band reads" begin
    mktempdir() do dir
        path = joinpath(dir, "striped.tif")
        truth = tiled_fixture(path, 64, 40; blocky = 1, tiled = false)
        r = open_optical(path)
        @test size(r) == (64, 40)
        @test map(length, first(DiskArrays.eachchunk(r)))[2] == 40
        @test read_window(r, 1:64, 1:40) == truth
    end
end

@testset "a tiled JPEG 2000 band decodes as GDAL decodes it" begin
    mktempdir() do dir
        nrows, ncols = 300, 257
        truth = UInt16[(r * 7919 + c * 104_729) % 32_768 for r in 1:nrows, c in 1:ncols]
        path = joinpath(dir, "band.jp2")
        ArchGDAL.create(""; driver = ArchGDAL.getdriver("MEM"), width = ncols, height = nrows,
                        nbands = 1, dtype = UInt16) do mem
            ArchGDAL.write!(mem, permutedims(truth), 1)
            ArchGDAL.copy(mem; filename = path, driver = ArchGDAL.getdriver("JP2OpenJPEG"),
                          options = ["REVERSIBLE=YES", "QUALITY=100", "BLOCKXSIZE=128", "BLOCKYSIZE=128",
                                     "RESOLUTIONS=3"]) |> ArchGDAL.destroy
        end
        gdal = ArchGDAL.read(path) do ds
            permutedims(ArchGDAL.read(ArchGDAL.getband(ds, 1)))
        end
        @test gdal == truth

        r = open_optical(path)
        @test size(r) == (nrows, ncols)
        @test eltype(r) == UInt16
        @test map(length, first(DiskArrays.eachchunk(r))) == (128, 128)
        @test r[:, :] == gdal
        @test r[100:250, 30:200] == gdal[100:250, 30:200]
        asfloat = Matrix{Float32}(undef, 151, 171)
        @test read_window!(asfloat, r, 100:250, 30:200) == Float32.(gdal[100:250, 30:200])
    end
end

@testset "a GDAL virtual path is refused with the form to use" begin
    @test_throws "name the object itself, as `s3://bucket/key`" open_optical("/vsis3/bucket/key.TIF")
end
