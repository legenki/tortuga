// The route as a metro line: You → bridge or guard → middle → exit → site.
// layoutMetro() decides what is drawn (pure, tested); renderMetro() draws it
// as SVG. Colours come from CSS classes in style.css.

import { flagEmoji } from '../lib/flags';
import type { BridgeKind, Hop, Stage } from '../lib/protocol';
import { DEFAULT_SITE } from '../lib/site';

export const WIDTH = 312;
export const HEIGHT = 92;
export const LINE_Y = 34;
const STEP = 68;
export const SITE_CHARS = 12;
const X0 = 20;

export type SegmentStyle = 'plain' | 'snowflake' | 'obfs4' | 'webtunnel';

export interface Station {
  /** Stays the same while the same relay holds the place, so a change animates. */
  key: string;
  kind: 'you' | 'relay' | 'bridge' | 'site';
  /** Full text for the tooltip. */
  title: string;
  x: number;
  label: string;
  sub: string;
  flag: string;
  lit: boolean;
}

export interface Segment {
  x1: number;
  x2: number;
  style: SegmentStyle;
  lit: boolean;
  /** The step that is happening now while connecting. */
  pending: boolean;
}

export interface MetroModel {
  stations: Station[];
  segments: Segment[];
}

export interface MetroInput {
  bridge: BridgeKind;
  site: string;
  /** The site's circuit, or null before one is known. */
  hops: Hop[] | null;
  /** null: off. While connecting, the last bootstrap stage. */
  stage: Stage | null;
  connecting: boolean;
}

/** The end station without a site: Chrome's shared incognito circuit, or a tab that isn't a web page. */
const DEFAULT_LABEL = {
  chrome: { label: 'Incognito', title: 'Incognito windows' },
  firefox: { label: 'No site', title: 'This tab isn’t a web page' },
} as const;

const BRIDGE_NAMES: Record<BridgeKind, string> = { none: 'No bridge', snowflake: 'Snowflake', obfs4: 'obfs4', webtunnel: 'WebTunnel' };

function short(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

/** A site name that fits: whole, else without its last label ("wikipedia"), else cut. */
export function shortSite(site: string): string {
  if (site.length <= SITE_CHARS) return site;
  const name = site.slice(0, site.lastIndexOf('.'));
  return name && name.length <= SITE_CHARS ? name : short(site, SITE_CHARS);
}

/** How many stations are lit, and which segment is pending, for a stage. */
function progress(input: MetroInput): { lit: number; pending: number | null } {
  if (!input.connecting) return { lit: 5, pending: null };
  if (input.stage === 'directory') return { lit: 2, pending: 1 };
  if (input.stage === 'ready') return { lit: 5, pending: null };
  return { lit: 1, pending: 0 };
}

export function layoutMetro(input: MetroInput): MetroModel {
  const { lit, pending } = progress(input);
  // By role, not position: a path can have two middles (onion services).
  const hops = input.hops ?? [];
  const first = hops[0];
  const middle = hops.find(h => h.role === 'middle');
  const exit = hops.find(h => h.role === 'exit');
  const viaBridge = input.bridge !== 'none';
  const relay = (h: Hop | undefined, role: string, fallback: string) => ({
    key: h ? `${role}:${h.id}` : role,
    title: h ? `${fallback} ${h.addr ?? ''} ${h.country ?? ''} ${h.id}`.replace(/\s+/g, ' ').trim() : fallback,
    label: fallback,
    sub: h ? (h.country ?? short(h.id, 8)) : '…',
    flag: flagEmoji(h?.country),
  });

  const stations: Omit<Station, 'x' | 'lit'>[] = [
    { key: 'you', kind: 'you', title: 'You — sites don’t see your IP', label: 'You', sub: 'hidden', flag: '' },
    viaBridge
      ? { key: first ? `bridge:${first.id}` : 'bridge', kind: 'bridge', title: `${BRIDGE_NAMES[input.bridge]} bridge`, label: 'Bridge', sub: BRIDGE_NAMES[input.bridge], flag: '' }
      : { ...relay(first, 'guard', 'Guard'), kind: 'relay' },
    { ...relay(middle, 'middle', 'Middle'), kind: 'relay' },
    { ...relay(exit, 'exit', 'Exit'), kind: 'relay' },
    // The site's name sits above the end of the line, right-aligned, where
    // no flag is drawn; 12 characters fit without reaching the exit's flag.
    input.site === DEFAULT_SITE
      ? { key: 'site:default', kind: 'site', ...DEFAULT_LABEL[__TARGET__], sub: '', flag: '' }
      : { key: `site:${input.site}`, kind: 'site', title: input.site, label: shortSite(input.site), sub: '', flag: '' },
  ];

  return {
    stations: stations.map((s, i) => ({ ...s, x: X0 + i * STEP, lit: i < lit })),
    segments: [0, 1, 2, 3].map(i => ({
      x1: X0 + i * STEP,
      x2: X0 + (i + 1) * STEP,
      style: i === 0 && viaBridge ? (input.bridge as SegmentStyle) : 'plain',
      lit: i < lit - 1,
      pending: i === pending,
    })),
  };
}

const NS = 'http://www.w3.org/2000/svg';

function el<K extends keyof SVGElementTagNameMap>(tag: K, attrs: Record<string, string | number>, text?: string): SVGElementTagNameMap[K] {
  const node = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, String(v));
  if (text !== undefined) node.textContent = text;
  return node;
}

function segmentNode(s: Segment): SVGGElement {
  const g = el('g', { class: `seg seg-${s.style}${s.lit ? ' lit' : ''}${s.pending ? ' pending' : ''}` });
  const y = LINE_Y;
  if (s.style === 'obfs4') {
    const n = 6;
    const w = (s.x2 - s.x1) / n;
    let d = `M${s.x1} ${y}`;
    for (let i = 0; i < n; i++) d += ` q${w / 2} ${i % 2 ? 7 : -7} ${w} 0`;
    g.append(el('path', { d, class: 'stroke' }));
  } else if (s.style === 'webtunnel') {
    g.append(el('rect', { x: s.x1, y: y - 7, width: s.x2 - s.x1, height: 14, rx: 7, class: 'tube' }));
    g.append(el('line', { x1: s.x1, y1: y, x2: s.x2, y2: y, class: 'stroke thin' }));
  } else {
    g.append(el('line', { x1: s.x1, y1: y, x2: s.x2, y2: y, class: 'stroke' }));
  }
  return g;
}

function stationNode(s: Station, entering: boolean): SVGGElement {
  // The outer group places the station; the inner one is what animates, so a
  // CSS transform never fights the placement.
  const g = el('g', { class: `st st-${s.kind}${s.lit ? ' lit' : ''}${entering ? ' enter' : ''}`, transform: `translate(${s.x} 0)` });
  const inner = el('g', { class: 'in' });
  inner.append(el('title', {}, s.title));
  if (s.kind === 'bridge') inner.append(el('rect', { x: -10, y: LINE_Y - 10, width: 20, height: 20, rx: 6, class: 'dot' }));
  else if (s.kind === 'site') inner.append(el('circle', { cx: 0, cy: LINE_Y, r: 10, class: 'dot' }));
  else inner.append(el('circle', { cx: 0, cy: LINE_Y, r: 8, class: 'dot' }));
  if (s.flag) inner.append(el('text', { x: 0, y: 14, class: 'flag-emoji' }, s.flag));
  inner.append(s.kind === 'site'
    ? el('text', { x: 11, y: 14, class: 'label site-label' }, s.label)
    : el('text', { x: 0, y: 66, class: 'label' }, s.label));
  if (s.sub) inner.append(el('text', { x: 0, y: 80, class: 'sub' }, s.sub));
  g.append(inner);
  return g;
}

/** Draw `model` into `svg`; stations whose relay changed since the last draw animate in. */
export function renderMetro(svg: SVGSVGElement, model: MetroModel): void {
  const before = new Set((svg.dataset.keys ?? '').split('|').filter(Boolean));
  const firstDraw = before.size === 0;
  svg.setAttribute('viewBox', `0 0 ${WIDTH} ${HEIGHT}`);
  svg.replaceChildren(
    ...model.segments.map(segmentNode),
    ...model.stations.map(s => stationNode(s, !firstDraw && !before.has(s.key))),
  );
  svg.dataset.keys = model.stations.map(s => s.key).join('|');
}
