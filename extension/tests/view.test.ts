import { describe, it, expect } from 'vitest';
import { viewFor } from '../src/popup/view';
import { initialState, reduce } from '../src/lib/state';

describe('viewFor', () => {
  it('shows progress and the connecting line while connecting', () => {
    const s = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'snowflake' }), { type: 'status', stage: 'directory', percent: 40, blocked: null });
    expect(viewFor(s, 'default')).toMatchObject({
      torSelected: true, tone: 'busy', status: 'Connecting via Snowflake… 40%',
      metro: { bridge: 'snowflake', hops: null, stage: 'directory', connecting: true },
    });
  });

  it('draws the site’s circuit and its exit relay when on', () => {
    let s = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'none' }), { type: 'ready', socksPort: 9150 });
    s = reduce(s, { type: 'circuit', circuit: { site: 'github.com', bridge: null, hops: [
      { role: 'guard', id: 'g', addr: '192.0.2.1', country: 'US' },
      { role: 'middle', id: 'm', addr: '192.0.2.2', country: 'MD' },
      { role: 'exit', id: 'e', addr: '185.220.101.3', country: 'DE' },
    ] } });
    const v = viewFor(s, 'github.com');
    expect(v).toMatchObject({ tone: 'on', canNewCircuit: true, exit: 'Exit relay 185.220.101.3 · DE' });
    expect(v.metro?.hops).toHaveLength(3);
    expect(viewFor(s, 'wikipedia.org')).toMatchObject({ exit: null, metro: { hops: null } });
  });

  it('offers Restart after a failure but not for a missing helper', () => {
    const on = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'none' }), { type: 'ready', socksPort: 1 });
    expect(viewFor(reduce(on, { type: 'failed', error: 'gone' }), 'default')).toMatchObject({ tone: 'alert', showRestart: true, metro: null });
    expect(viewFor(reduce(on, { type: 'failed', error: 'x', helperMissing: true }), 'default')).toMatchObject({ status: 'Helper not installed', showRestart: false });
  });
});
