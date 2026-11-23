// Writes TortugaKit's WorldMap.json: land as a 0.5° grid of dots, and each
// country's label point by ISO 3166 alpha-2 code. Data: Natural Earth
// (public domain), fetched from a pinned release of natural-earth-vector.
import { writeFileSync } from 'node:fs';
import { geoContains } from 'd3-geo';

const NE = 'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson';
const OUT = new URL('../../Packages/TortugaKit/Sources/TortugaKit/Resources/WorldMap.json', import.meta.url);
const STEP = 0.5;
// Antarctica is left out: no relays there, and it would take a third of the map.
const SOUTH = -58;
const NORTH = 84;

async function get(name) {
  const res = await fetch(`${NE}/${name}`);
  if (!res.ok) throw new Error(`${name}: HTTP ${res.status}`);
  return res.json();
}

const land = await get('ne_110m_land.geojson');
const countries = await get('ne_50m_admin_0_countries.geojson');

const dots = [];
for (let lat = NORTH - STEP / 2; lat >= SOUTH; lat -= STEP) {
  for (let lon = -180 + STEP / 2; lon < 180; lon += STEP) {
    if (land.features.some(f => geoContains(f, [lon, lat]))) dots.push([lon, lat]);
  }
}

const places = {};
for (const f of countries.features) {
  const p = f.properties;
  const code = p.ISO_A2_EH && p.ISO_A2_EH !== '-99' ? p.ISO_A2_EH : p.ISO_A2;
  // Antarctica's label point is off the map (see SOUTH).
  if (!code || code === '-99' || code === 'AQ' || places[code]) continue;
  places[code] = [Math.round(p.LABEL_X * 100) / 100, Math.round(p.LABEL_Y * 100) / 100];
}

writeFileSync(OUT, JSON.stringify({ dots, countries: places }) + '\n');
console.log(`${dots.length} dots, ${Object.keys(places).length} countries → ${OUT.pathname}`);
