import { describe, it, expect } from 'vitest';
import { viewFor } from '../src/popup/view';
import { initialState, reduce } from '../src/lib/state';

describe('viewFor', () => {
  it('shows progress while connecting', () => {
    const s = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'snowflake' }), { type: 'status', percent: 40, blocked: null });
    expect(viewFor(s, 'default')).toMatchObject({ torSelected: true, tone: 'busy', status: 'Connecting via Snowflake… 40%' });
  });

  it('lists the hops of the site when on', () => {
    let s = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'none' }), { type: 'ready', socksPort: 9150 });
    s = reduce(s, { type: 'circuit', circuit: { site: 'default', bridge: null, hops: [{ role: 'exit', id: 'abcdefghij', country: null }] } });
    expect(viewFor(s, 'default')).toMatchObject({ tone: 'on', canNewCircuit: true, hops: ['Exit · — · abcdefgh'] });
  });

  it('offers Restart after a failure but not for a missing helper', () => {
    const on = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'none' }), { type: 'ready', socksPort: 1 });
    expect(viewFor(reduce(on, { type: 'failed', error: 'gone' }), 'default')).toMatchObject({ tone: 'alert', showRestart: true });
    expect(viewFor(reduce(on, { type: 'failed', error: 'x', helperMissing: true }), 'default')).toMatchObject({ status: 'Helper not installed', showRestart: false });
  });
});
