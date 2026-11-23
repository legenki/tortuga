# Map data

`npm install && npm run build` writes `Packages/TortugaKit/Sources/TortugaKit/Resources/WorldMap.json`:

- `dots`: land on a 0.5° grid (centres of cells), from Natural Earth 1:110m land, without Antarctica.
- `countries`: each country's label point by ISO 3166 alpha-2 code, from Natural Earth 1:50m admin-0 countries.

Natural Earth is in the public domain (https://www.naturalearthdata.com/about/terms-of-use/). The output is committed; run this again only to update the data.
