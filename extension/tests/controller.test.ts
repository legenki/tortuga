import { describe, it, expect } from 'vitest';
import { Controller, HELPER_MISSING, INCOGNITO_NEEDED, type Deps } from '../src/background/controller';
import { HelperClient, HOST_FORBIDDEN } from '../src/background/helper';
import type { Stored } from '../src/lib/messages';
import { BLACKHOLE_PORT, type TorState } from '../src/lib/state';
import { FakePort, flush } from './fake-port';

function setup(opts: { incognito?: boolean; lastError?: string; routeError?: string; clearError?: string } = {}) {
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
    applyRoute: async p => {
      if (opts.routeError) throw new Error(opts.routeError);
      if (p === null && opts.clearError) throw new Error(opts.clearError);
      routes.push(p);
    },
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

  it('records the helper version and sends bridge lines', async () => {
    const { c, ports } = setup();
    await c.turnOn('obfs4', ['obfs4 192.0.2.55:443 AAAA cert=x iat-mode=0']);
    await boot(ports[0]);
    expect(c.current.helperVersion).toBe('0.1.0');
    expect(ports[0].sent[1]).toMatchObject({ type: 'tor.start', payload: { bridge: { kind: 'obfs4', lines: ['obfs4 192.0.2.55:443 AAAA cert=x iat-mode=0'] } } });
  });

  it('remembers a bridge chosen while off, restarts Tor with one chosen while on', async () => {
    const { c, ports, saved } = setup();
    await c.chooseBridge('webtunnel');
    expect(c.current).toMatchObject({ phase: 'off', bridge: 'webtunnel' });
    expect(saved.at(-1)).toEqual({ enabled: false, bridge: 'webtunnel' });
    expect(ports).toEqual([]);
    await c.turnOn('none');
    await boot(ports[0]);
    await c.chooseBridge('snowflake');
    await flush();
    // The same helper switches its running client; no second hello.
    expect(ports).toHaveLength(1);
    expect(ports[0].disconnected).toBe(false);
    expect(ports[0].sent.filter(m => m.type === 'hello')).toHaveLength(1);
    expect(ports[0].sent.at(-1)).toMatchObject({ type: 'tor.start', payload: { bridge: { kind: 'snowflake' } } });
    expect(c.current).toMatchObject({ phase: 'connecting', bridge: 'snowflake' });
    ports[0].emit({ id: ports[0].idOf('tor.start'), type: 'tor.ready', payload: { socksPort: 9151 } });
    await flush();
    expect(c.current).toMatchObject({ phase: 'on', socksPort: 9151 });
  });

  it('ignores the answer to a start that a bridge change replaced', async () => {
    const { c, ports } = setup();
    await c.turnOn('none');
    await flush();
    ports[0].emit({ id: ports[0].idOf('hello'), type: 'hello', payload: { protocol: 1, version: '0.1.0' } });
    await flush();
    const first = ports[0].idOf('tor.start');
    await c.chooseBridge('snowflake');
    await flush();
    ports[0].emit({ id: first, type: 'error', payload: { code: 'cancelled', message: 'replaced by a newer request' } });
    await flush();
    await flush();
    expect(c.current).toMatchObject({ phase: 'connecting', bridge: 'snowflake', error: null });
  });

  it('Restart after Tor failed asks the same helper again', async () => {
    const { c, ports } = setup();
    await c.turnOn('none');
    await flush();
    ports[0].emit({ id: ports[0].idOf('hello'), type: 'hello', payload: { protocol: 1, version: '0.1.0' } });
    await flush();
    ports[0].emit({ id: ports[0].idOf('tor.start'), type: 'error', payload: { code: 'tor_failed', message: 'no route' } });
    await flush();
    await flush();
    expect(c.current.phase).toBe('failed');
    await c.turnOn('none');
    await flush();
    expect(ports).toHaveLength(1);
    expect(ports[0].sent.filter(m => m.type === 'tor.start')).toHaveLength(2);
  });

  it('Restart after the helper died connects a new one', async () => {
    const { c, ports } = setup({ lastError: 'Native host has exited.' });
    await c.turnOn('none');
    await boot(ports[0]);
    ports[0].die();
    await flush();
    await c.turnOn('none');
    expect(ports).toHaveLength(2);
  });

  it('does not claim Direct when the browser refuses to release the proxy', async () => {
    const { c, ports } = setup({ clearError: 'policy' });
    await c.turnOn('none');
    await boot(ports[0]);
    await c.turnOff();
    expect(c.current.phase).toBe('failed');
    expect(c.current.error).toContain('refused to release');
  });

  it('asks for bridge lines only while Tor is on', async () => {
    const { c, ports } = setup();
    expect(c.fetchBridges('obfs4')).toBeNull();
    await c.turnOn('snowflake');
    await boot(ports[0]);
    const fetching = c.fetchBridges('obfs4')!;
    await flush();
    expect(ports[0].sent.at(-1)).toMatchObject({ type: 'bridges.fetch', payload: { kind: 'obfs4' } });
    ports[0].emit({ id: ports[0].idOf('bridges.fetch'), type: 'bridges.lines', payload: { lines: ['obfs4 a'], source: 'builtin', country: 'it', viaTor: false } });
    await expect(fetching).resolves.toMatchObject({ lines: ['obfs4 a'] });
  });

  it('passes bootstrap stages on', async () => {
    const { c, ports } = setup();
    await c.turnOn('snowflake');
    await flush();
    ports[0].emit({ type: 'tor.status', payload: { phase: 'directory', percent: 42, blocked: null } });
    await flush();
    expect(c.current).toMatchObject({ phase: 'connecting', stage: 'directory', percent: 42 });
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

  it('explains a helper installed for another extension ID', async () => {
    const { c, ports } = setup({ lastError: 'Access to the specified native messaging host is forbidden.' });
    await c.turnOn('none');
    ports[0].die();
    await flush();
    await flush();
    expect(c.current).toMatchObject({ phase: 'failed', error: HOST_FORBIDDEN });
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

  it('fails, instead of waiting forever, when the browser refuses the proxy setting', async () => {
    const { c, ports, states } = setup({ routeError: 'You cannot set a preference' });
    await c.turnOn('none');
    expect(ports).toEqual([]);
    expect(c.current.phase).toBe('failed');
    expect(c.current.error).toContain('You cannot set a preference');
    expect(states.at(-1)?.phase).toBe('failed');
  });

  it('without Incognito access, says how to grant it even though the proxy setting fails too', async () => {
    const { c, ports } = setup({ incognito: false, routeError: 'You do not have permission to access incognito preferences.' });
    await c.turnOn('none');
    expect(ports).toEqual([]);
    expect(c.current).toMatchObject({ phase: 'failed', error: INCOGNITO_NEEDED });
  });

  it('stores circuits and asks for new ones', async () => {
    const { c, ports } = setup();
    await c.turnOn('none');
    await boot(ports[0]);
    ports[0].emit({ type: 'circuit', payload: { site: 'github.com', bridge: null, hops: [{ role: 'guard', id: 'g', addr: '192.0.2.1', country: 'DE' }] } });
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
