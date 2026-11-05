import { describe, it, expect } from 'vitest';
import { layoutMetro, type MetroInput } from '../src/popup/metro';
import type { Hop } from '../src/lib/protocol';

const hops: Hop[] = [
  { role: 'bridge', id: 'bridgeid1', addr: '192.0.2.3', country: null },
  { role: 'middle', id: 'middleid', addr: '176.123.3.35', country: 'MD' },
  { role: 'exit', id: 'exitid', addr: '185.220.101.3', country: 'DE' },
];
const on: MetroInput = { bridge: 'snowflake', site: 'github.com', hops, stage: 'ready', connecting: false };

describe('layoutMetro', () => {
  it('draws five stations, the bridge as its transport', () => {
    const { stations } = layoutMetro(on);
    expect(stations.map(s => s.label)).toEqual(['You', 'Bridge', 'Middle', 'Exit', 'github.com']);
    expect(stations[1]).toMatchObject({ kind: 'bridge', sub: 'Snowflake', flag: '' });
    expect(stations[3]).toMatchObject({ sub: 'DE', flag: '🇩🇪' });
    expect(stations.every(s => s.lit)).toBe(true);
  });

  it('styles only the segment the bridge covers', () => {
    expect(layoutMetro(on).segments.map(s => s.style)).toEqual(['snowflake', 'plain', 'plain', 'plain']);
    expect(layoutMetro({ ...on, bridge: 'obfs4' }).segments[0].style).toBe('obfs4');
    expect(layoutMetro({ ...on, bridge: 'none', hops: [{ ...hops[0], role: 'guard', country: 'US' }, hops[1], hops[2]] }).segments[0].style).toBe('plain');
  });

  it('without a bridge the first station is the guard with its flag', () => {
    const s = layoutMetro({ ...on, bridge: 'none', hops: [{ ...hops[0], role: 'guard', country: 'US' }, hops[1], hops[2]] }).stations[1];
    expect(s).toMatchObject({ kind: 'relay', label: 'Guard', sub: 'US', flag: '🇺🇸' });
  });

  it('keys stations by relay, so a new circuit changes the keys', () => {
    const a = layoutMetro(on).stations.map(s => s.key);
    const b = layoutMetro({ ...on, hops: [hops[0], hops[1], { ...hops[2], id: 'otherexit' }] }).stations.map(s => s.key);
    expect(a.filter((k, i) => k !== b[i])).toEqual(['exit:exitid']);
  });

  it('lights up step by step while connecting', () => {
    const connecting = { ...on, hops: null, connecting: true };
    const first = layoutMetro({ ...connecting, stage: 'bridge' });
    expect(first.stations.map(s => s.lit)).toEqual([true, false, false, false, false]);
    expect(first.segments.map(s => s.pending)).toEqual([true, false, false, false]);
    const dir = layoutMetro({ ...connecting, stage: 'directory' });
    expect(dir.stations.map(s => s.lit)).toEqual([true, true, false, false, false]);
    expect(dir.segments.map(s => [s.lit, s.pending])).toEqual([[true, false], [false, true], [false, false], [false, false]]);
    expect(dir.stations[2].sub).toBe('…');
  });

  it('shortens long site names to fit the end of the line', () => {
    const label = (site: string) => layoutMetro({ ...on, site }).stations[4];
    expect(label('github.com')).toMatchObject({ label: 'github.com', title: 'github.com' });
    expect(label('wikipedia.org')).toMatchObject({ label: 'wikipedia', title: 'wikipedia.org' });
    expect(label('ycombinator.com').label).toBe('ycombinator');
    expect(label('averyveryverylongname.org').label).toBe('averyveryve…');
  });

  it('calls Chrome’s shared circuit Incognito', () => {
    expect(layoutMetro({ ...on, site: 'default' }).stations[4].label).toBe('Incognito');
  });
});
