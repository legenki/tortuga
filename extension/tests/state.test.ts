import { describe, it, expect } from 'vitest';
import { BLACKHOLE_PORT, initialState, reduce, routedPort, type TorState } from '../src/lib/state';
import type { Circuit } from '../src/lib/protocol';

const circuit: Circuit = { site: 'github.com', bridge: null, hops: [{ role: 'guard', id: 'g', addr: '192.0.2.1', country: 'DE' }] };

function on(): TorState {
  return reduce(reduce(initialState(), { type: 'turnOn', bridge: 'snowflake' }), { type: 'ready', socksPort: 9150 });
}

describe('reduce', () => {
  it('off → connecting → on', () => {
    const connecting = reduce(initialState(), { type: 'turnOn', bridge: 'snowflake' });
    expect(connecting).toMatchObject({ phase: 'connecting', bridge: 'snowflake', percent: 0 });
    const progressed = reduce(connecting, { type: 'status', stage: 'directory', percent: 40, blocked: null });
    expect(progressed).toMatchObject({ percent: 40, stage: 'directory' });
    expect(reduce(progressed, { type: 'ready', socksPort: 9150 })).toMatchObject({ phase: 'on', socksPort: 9150, percent: 100, stage: 'ready' });
  });

  it('keeps the helper version across on and off', () => {
    const hello = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'none' }), { type: 'hello', version: '0.1.0' });
    expect(reduce(hello, { type: 'turnOff' }).helperVersion).toBe('0.1.0');
    expect(reduce(reduce(hello, { type: 'turnOff' }), { type: 'turnOn', bridge: 'none' }).helperVersion).toBe('0.1.0');
  });

  it('keeps circuits per site while on', () => {
    expect(reduce(on(), { type: 'circuit', circuit }).circuits['github.com']).toEqual(circuit);
    expect(reduce(initialState(), { type: 'circuit', circuit }).circuits).toEqual({});
  });

  it('a failure while on drops the port', () => {
    const failed = reduce(on(), { type: 'failed', error: 'The helper stopped' });
    expect(failed).toMatchObject({ phase: 'failed', socksPort: null, error: 'The helper stopped' });
  });

  it('a failure while off stays off', () => {
    expect(reduce(initialState(), { type: 'failed', error: 'x' }).phase).toBe('off');
  });

  it('ignores late events from an older start', () => {
    expect(reduce(initialState(), { type: 'ready', socksPort: 9150 }).phase).toBe('off');
  });

  it('a bridge chosen while off is kept, ignored while on', () => {
    expect(reduce(initialState(), { type: 'choose', bridge: 'obfs4' }).bridge).toBe('obfs4');
    expect(reduce(on(), { type: 'choose', bridge: 'obfs4' }).bridge).toBe('snowflake');
  });

  it('turning off keeps the bridge choice', () => {
    expect(reduce(on(), { type: 'turnOff' })).toEqual(initialState('snowflake'));
    expect(reduce(on(), { type: 'turnOff' }).stage).toBeNull();
  });
});

describe('routedPort', () => {
  it('lets traffic go its own way only when off', () => {
    expect(routedPort(initialState())).toBeNull();
  });

  it('uses the SOCKS port when on', () => {
    expect(routedPort(on())).toBe(9150);
  });

  it('blocks while connecting or failed', () => {
    expect(routedPort(reduce(initialState(), { type: 'turnOn', bridge: 'none' }))).toBe(BLACKHOLE_PORT);
    expect(routedPort(reduce(on(), { type: 'failed', error: 'x' }))).toBe(BLACKHOLE_PORT);
  });
});
