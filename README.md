# OpticalDatasets

Read a Landsat or Sentinel-2 product's identity from a STAC item, into one sensor-neutral type.

```julia
using OpticalDatasets, JSON3

item = JSON3.read(read("landsat_item.json", String))
id = open_optical(item)
id.mission, id.satellite, id.sensor, id.acquisition_time
```

`open_optical` takes any `AbstractDict` — the result of parsing a STAC item JSON with whatever JSON
library a caller already has, so this package depends on none.

A Landsat product id and a Sentinel-2 product name can also be parsed directly, without a STAC item:

```julia
landsat_identification("LC08_L1TP_009011_20200703_20200913_02_T1", DateTime(2020, 7, 3, 15, 0, 24, 531))
sentinel2_identification("S2B_MSIL1C_20200612T150759_N0209_R025_T22WEB_20200612T184700")
```

Sentinel-2's product name carries its full sensing instant; Landsat's carries only a date, so
`landsat_identification` needs the acquisition time supplied separately and checks the two agree.

## Reading imagery

Given a path, `open_optical` returns one band as a lazy array indexed `(row, column)`, read a tile at a
time through [ChunkManifests.jl](https://github.com/alex-s-gardner/ChunkManifests.jl): a GeoTIFF or COG
(Landsat) or a JPEG 2000 file (Sentinel-2), from a local file, an `https://` URL or an `s3://` object.

```julia
r = open_optical("https://storage.googleapis.com/gcp-public-data-sentinel-2/tiles/.../T22WEB_20200612T150759_B08.jp2")
r[1:1024, 1:1024]                                  # reads the one tile that covers it
read_window!(Matrix{Float32}(undef, 4096, 4096), r, 1:4096, 1:4096)   # converted tile by tile

using AWSS3, ChunkManifests                        # Landsat's bucket is requester-pays
open_optical("s3://usgs-landsat/collection02/.../LC08_..._B8.TIF";
             transport = S3Transport("usgs-landsat"; requesterpays = true))
```

A window's tiles are fetched concurrently and decoded on several threads, and several tasks may read one
band at once.

Converting an identity into an ITS_LIVE product's `img_pair_info` belongs to the package that writes
that product, as it does for [SLCDatasets.jl](https://github.com/alex-s-gardner/SLCDatasets.jl)'s
Sentinel-1 and NISAR products.
