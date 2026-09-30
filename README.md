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

This package reads identity only — the same scope [SLCDatasets.jl](https://github.com/alex-s-gardner/SLCDatasets.jl)
has for Sentinel-1 and NISAR. Converting one into an ITS_LIVE product's `img_pair_info` belongs to the
package that writes that product.
