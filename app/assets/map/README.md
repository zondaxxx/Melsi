# Country borders

`countries.json` contains Natural Earth **1:50m admin-0 countries**, reduced
to exterior rings for the locally painted home-screen map. It has 241
countries and territories, 1,512 exterior rings and 53,290 points (889,853
bytes). Antarctica is omitted, as in the previous 1:110m asset. No island or
small territory is discarded to meet a file-size threshold.

The JSON schema is unchanged: `{"c":[{"i":"ISO code","a":[lon,lat],
"r":[[[lon,lat],...],...]}]}`. `i` comes from `ISO_A2_EH`, preserving the
codes for France and Norway; Natural Earth's `-99` becomes an empty code.
Every exterior ring is closed. Interior holes are omitted, matching the
existing renderer.

All 176 existing country records retain their original codes and anchor
coordinates exactly. `scripts/map-country-anchors.json` records those
legacy anchors, keyed by Natural Earth's `ADM0_A3`, so regeneration does not
move existing server/country placements. Newly represented territories use
Natural Earth's `LABEL_X` / `LABEL_Y`, rounded to 0.01°.

## Source and license

- [Natural Earth 1:50m countries](https://www.naturalearthdata.com/downloads/50m-cultural-vectors/50m-admin-0-countries-2/)
- [Pinned GeoJSON, repository release v5.1.2](https://github.com/nvkelso/natural-earth-vector/blob/v5.1.2/geojson/ne_50m_admin_0_countries.geojson)
- Source SHA-256: `3e458fc036ad0a66411f2c1e6cac49c5d7bfb81cb1123bc513b22511a2b7fdeb`
- [Natural Earth terms of use](https://www.naturalearthdata.com/about/terms-of-use/): public domain; modification and commercial use are permitted.

## Rebuild

From the repository root, using Python 3 and its standard library:

```sh
python3 scripts/generate-map-countries.py
```

The script downloads the pinned public GeoJSON and verifies its checksum.
To use an already downloaded copy or compare generated output without
overwriting the bundled asset:

```sh
python3 scripts/generate-map-countries.py \
  --source /path/to/ne_50m_admin_0_countries.geojson \
  --output /tmp/countries.json
```

Generation applies Ramer–Douglas–Peucker simplification with a 0.02° maximum
perpendicular error before rounding, splitting at shared border junctions.
Canonical arc direction keeps the simplified common borders identical.
Ring extrema are preserved. If simplification would collapse or reverse a
ring, change its area by over 2%, or introduce a proper self-intersection,
all its source vertices are retained, including on adjoining boundaries.
Coordinates normally use three decimal places; tiny/problematic rings keep
six-place source precision when necessary to avoid collapse or crossings.

The generator validates the schema inputs, coordinate ranges, ring counts,
legacy country coverage and codes. Generation is deterministic. No map SDK,
runtime map download or additional Python package is needed.
