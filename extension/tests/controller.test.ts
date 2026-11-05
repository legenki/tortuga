import { describe, it, expect } from 'vitest';
import { Controller, HELPER_MISSING, INCOGNITO_NEEDED, type Deps } from '../src/background/controller';
import { HelperClient } from '../src/background/helper';
import type { Stored } from '../src/lib/messages';
import { BLACKHOLE_PORT, type TorState } from '../src/lib/state';
import { FakePort, flush } from './fake-port';

function setup(opts: { incognito?: boolean; lastError?: string } = {}) {
  const ports: FakePort[] = [];
  const routes: (number | null)[] = [];
  const privacy: boolean[] = [];
  const saved: Stored[] = [];
  const states: TorState[] = [];
  const deps: Deps = {
    connect: (onEvent, onGone) => {
      const port = new FakePort();
      ports.push(port);
      return new HelperClient(port, onEvent, onGone, () => opts.lastError);
    },
    applyRoute: async p => void routes.push(p),
    applyPrivacy: async on => void privacy.push(on),
    save: async s => void saved.push(s),
    broadcast: s => void states.push(s),
    incognitoAllowed: async () => opts.incognito ?? true,
  };
  return { c: new Controller(deps), ports, routes, privacy, saved, states };
}

/** Answer hello and tor.start the way a healthy helper does. */
async function boot(port: FakePort, socksPort = 9150) {
  await flush();
  port.emit({ id: port.idOf('hello'), type: 'hello', payload: { protocol: 1, version: '0.1.0' } });
  await flush();
  port.emit({ id: port.idOf('tor.start'), type: 'tor.ready', payload: { socksPort } });
  await flush();
}

describe('Controller', () => {
  it('blocks traffic while connecting, then routes through the SOCKS port', async () => {
    const { c, ports, routes, privacy, saved } = setup();
    await c.turnOn('snowflake');
    expect(routes).toEqual([BLACKHOLE_PORT]);
    expect(privacy).toEqual([true]);
    expect(saved).toEqual([{ enabled: true, bridge: 'snowflake' }]);
    await boot(ports[0]);
    expect(ports[0].sent[1]).toMatchObject({ type: 'tor.start', payload: { bridge: { kind: 'snowflake' } } });
    expect(c.current.phase).toBe('on');
    expect(routes).toEqual([BLACKHOLE_PORT, 9150]);
  });

  it('turning off releases the route and privacy settings and the helper', async () => {
    const { c, ports, routes, privacy, saved } = setup();
    await c.turnOn('none');
    await boot(ports[0]);
    await c.turnOff();
    expect(routes.at(-1)).toBeNull();
    expect(privacy.at(-1)).toBe(false);
    expect(saved.at(-1)).toEqual({ enabled: false, bridge: 'none' });
    expect(ports[0].disconnected).toBe(true);
  });

  it('keeps traffic blocked when the helper dies', async () => {
    const { c, ports, routes } = setup({ lastError: 'Native host has exited.' });
    await c.turnOn('none');
    await boot(ports[0]);
    ports[0].die();
    await flush();
    expect(c.current).toMatchObject({ phase: 'failed', error: 'Native host has exited.', helperMissing: false });
    expect(routes.at(-1)).toBe(BLACKHOLE_PORT);
  });

  it('reports a missing helper', async () => {
    const { c, ports } = setup({ lastError: 'Specified native messaging host not found.' });
    await c.turnOn('none');
    ports[0].die();
    await flush();
    await flush();
    expect(c.current).toMatchObject({ phase: 'failed', helperMissing: true, error: HELPER_MISSING });
  });

  it('asks to update an older helper', async () => {
    const { c, ports } = setup();
    await c.turnOn('none');
    await flush();
    ports[0].emit({ id: ports[0].idOf('hello'), type: 'error', payload: { code: 'protocol_mismatch', message: 'helper speaks protocol 2, extension 1' } });
    await flush();
    await flush();
    expect(c.current.phase).toBe('failed');
    expect(c.current.error).toMatch(/^Update the Tortuga helper/);
  });

  it('Chrome without incognito access fails before starting the helper', async () => {
    const { c, ports } = setup({ incognito: false });
    await c.turnOn('none');
    expect(ports).toEqual([]);
    expect(c.current).toMatchObject({ phase: 'failed', error: INCOGNITO_NEEDED });
  });

  it('stores circuits and asks for new ones', async () => {
    const { c, ports } = setup();
    await c.turnOn('none');
    await boot(ports[0]);
    ports[0].emit({ type: 'circuit', payload: { site: 'github.com', bridge: null, hops: [{ role: 'guard', id: 'g', country: 'DE' }] } });
    await flush();
    expect(c.current.circuits['github.com'].hops[0].id).toBe('g');
    const renewed = c.newCircuit('github.com');
    await flush();
    ports[0].emit({ id: ports[0].idOf('tor.newCircuit'), type: 'ok' });
    await renewed;
    expect(ports[0].sent.at(-1)).toMatchObject({ type: 'tor.newCircuit', payload: { site: 'github.com' } });
  });

  it('a reply to an older start does not turn Tor on', async () => {
    const { c, ports } = setup();
    await c.turnOn('none');
    await flush();
    await c.turnOff();
    ports[0].emit({ id: ports[0].idOf('hello'), type: 'hello', payload: { protocol: 1, version: '0.1.0' } });
    await flush();
    expect(c.current.phase).toBe('off');
  });
});
