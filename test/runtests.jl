using OpticalDatasets
using OpticalDatasets: Identification
using Dates
using Test

# Every id below is a real `img_pair_info.id_img1`/`id_img2` captured from the hyp3-autorift
# reference container across the golden test suite, not synthesized — see AutoRIFT.jl's
# `tools/golden`.

@testset "Landsat" begin
    id = landsat_identification("LC08_L1TP_009011_20200703_20200913_02_T1",
                                DateTime("2020-07-03T15:00:24.531"))
    @test id.mission == "L"
    @test id.satellite == "8"
    @test id.sensor == "C"
    @test id.correction_level == "L1TP"
    @test id.path == 9
    @test id.row == 11
    @test id.collection_number == 2
    @test id.collection_category == "T1"
    @test id.processing_date == "20200913"
    @test id.acquisition_time == DateTime("2020-07-03T15:00:24.531")

    lt05 = landsat_identification("LT05_L1TP_060018_19851028_20200918_02_T1",
                                  DateTime(1985, 10, 28))
    @test (lt05.satellite, lt05.sensor) == ("5", "T")
    @test (lt05.path, lt05.row) == (60, 18)

    le07 = landsat_identification("LE07_L1TP_061018_20130314_20200908_02_T1",
                                  DateTime(2013, 3, 14))
    @test (le07.satellite, le07.sensor) == ("7", "E")

    # A one-digit path (`001013`) is not a fixed-width parsing trap.
    p000 = landsat_identification("LT05_L1GS_001013_19920425_20200915_02_T2",
                                  DateTime(1992, 4, 25))
    @test (p000.path, p000.row) == (1, 13)
    @test p000.collection_category == "T2"

    @test_throws "same acquisition" landsat_identification(
        "LC08_L1TP_009011_20200703_20200913_02_T1", DateTime(2020, 7, 4))
    @test_throws "Collection 2 product id" landsat_identification("not_an_id", DateTime(2020, 1, 1))
end

@testset "Sentinel-2" begin
    id = sentinel2_identification("S2B_MSIL1C_20200612T150759_N0209_R025_T22WEB_20200612T184700")
    @test id.mission == "S"
    @test id.satellite == "2B"
    @test id.sensor == "MSI"
    @test id.correction_level == "L1C"
    @test id.acquisition_time == DateTime(2020, 6, 12, 15, 7, 59)
    @test id.path === nothing

    # With the `.SAFE` suffix a real product directory name carries.
    same = sentinel2_identification(
        "S2B_MSIL1C_20200612T150759_N0209_R025_T22WEB_20200612T184700.SAFE")
    @test same.id == id.id

    id2 = sentinel2_identification("S2A_MSIL1C_20200627T150921_N0209_R025_T22WEB_20200627T170912")
    @test id2.satellite == "2A"

    @test_throws "product name" sentinel2_identification("not_an_id")
end

@testset "open_optical (STAC)" begin
    landsat_item = Dict(
        "id" => "LC08_L1TP_009011_20200703_20200913_02_T1",
        "properties" => Dict("datetime" => "2020-07-03T15:00:24.531814Z"),
    )
    id = open_optical(landsat_item)
    @test id.mission == "L"
    @test id.acquisition_time == DateTime(2020, 7, 3, 15, 0, 24, 531)

    s2_item = Dict(
        "id" => "S2B_22WEB_20200612_0_L1C",   # a provider's own id, deliberately not the SAFE name
        "properties" => Dict(
            "s2:product_uri" => "S2B_MSIL1C_20200612T150759_N0209_R025_T22WEB_20200612T184700.SAFE",
            "datetime" => "2020-06-12T15:13:33.286000Z",   # the tile's sensing time, not id_img1's
        ),
    )
    sid = open_optical(s2_item)
    @test sid.mission == "S"
    @test sid.id == "S2B_MSIL1C_20200612T150759_N0209_R025_T22WEB_20200612T184700"
    # The product name's own embedded time, not the STAC item's `datetime` — see `open_optical`.
    @test sid.acquisition_time == DateTime(2020, 6, 12, 15, 7, 59)

    @test_throws "neither" open_optical(Dict("properties" => Dict()))
end

include("raster.jl")
