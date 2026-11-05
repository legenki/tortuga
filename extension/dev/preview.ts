import { layoutMetro, renderMetro, type MetroInput } from '../src/popup/metro';
import type { Hop } from '../src/lib/protocol';

const hops = (first: Hop['role'], exit = 'exit1'): Hop[] => [
  { role: first, id: `${first}id`, addr: first === 'bridge' ? '192.0.2.3' : '64.65.1.161', country: first === 'bridge' ? null : 'US' },
  { role: 'middle', id: 'middleid', addr: '176.123.3.35', country: 'MD' },
  { role: 'exit', id: exit, addr: '185.220.101.3', country: exit === 'exit1' ? 'DE' : 'NL' },
];

const states: [string, MetroInput][] = [
  ['Connecting — first hop', { bridge: 'snowflake', site: 'github.com', hops: null, stage: 'bridge', connecting: true }],
  ['Connecting — directory', { bridge: 'snowflake', site: 'github.com', hops: null, stage: 'directory', connecting: true }],
  ['On — Snowflake', { bridge: 'snowflake', site: 'github.com', hops: hops('bridge'), stage: 'ready', connecting: false }],
  ['On — obfs4', { bridge: 'obfs4', site: 'wikipedia.org', hops: hops('bridge'), stage: 'ready', connecting: false }],
  ['On — WebTunnel', { bridge: 'webtunnel', site: 'ycombinator.com', hops: hops('bridge'), stage: 'ready', connecting: false }],
  ['On — no bridge', { bridge: 'none', site: 'duckduckgo.com', hops: hops('guard'), stage: 'ready', connecting: false }],
  ['On — Chrome, circuit not known yet', { bridge: 'none', site: 'default', hops: null, stage: 'ready', connecting: false }],
];

const grid = document.getElementById('grid')!;
for (const [title, input] of states) {
  const card = document.createElement('div');
  card.className = 'card';
  card.innerHTML = `<h3>${title}</h3>`;
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.classList.add('metro');
  card.append(svg);
  grid.append(card);
  renderMetro(svg, layoutMetro(input));
}

// A circuit change: the exit station animates in every 3 s.
const changing = document.createElement('div');
changing.className = 'card';
changing.innerHTML = '<h3>New circuit (exit changes every 3 s)</h3>';
const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
svg.classList.add('metro');
changing.append(svg);
grid.append(changing);
let flip = false;
const draw = () => renderMetro(svg, layoutMetro({ bridge: 'snowflake', site: 'github.com', hops: hops('bridge', flip ? 'exit2' : 'exit1'), stage: 'ready', connecting: false }));
draw();
setInterval(() => { flip = !flip; draw(); }, 3000);

document.getElementById('theme')!.addEventListener('click', () => {
  const root = document.documentElement;
  root.dataset.theme = root.dataset.theme === 'dark' ? 'light' : 'dark';
});
