// Render the toolbar and store icons from icons/*.svg into public/icons/.
//   npm i --no-save @resvg/resvg-js@2.6.2 && node scripts/icons.mjs
// 16 and 32 use icons/icon-small.svg (no route on the shell: it would blur).
// 128 is the store icon: the turtle at 96 px with 16 px clear on each side,
// as the Chrome Web Store asks.
import { Resvg } from '@resvg/resvg-js';
import { readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const svg = name => readFileSync(join(root, 'icons', name), 'utf8');
const render = (source, size) => new Resvg(source, { fitTo: { mode: 'width', value: size } }).render().asPng();

for (const size of [16, 32]) writeFileSync(join(root, `public/icons/icon-${size}.png`), render(svg('icon-small.svg'), size));
for (const size of [48, 96]) writeFileSync(join(root, `public/icons/icon-${size}.png`), render(svg('icon.svg'), size));
// 128 with padding: draw the 128 viewBox inside a 96 box centred in 128.
const padded = svg('icon.svg').replace('viewBox="0 0 128 128"', 'viewBox="-21.33 -21.33 170.67 170.67"');
writeFileSync(join(root, 'public/icons/icon-128.png'), render(padded, 128));
console.log('public/icons: 16 32 48 96 128');
