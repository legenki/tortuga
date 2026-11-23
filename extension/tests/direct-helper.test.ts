import { describe, it, expect } from 'vitest';
import { DirectHelper } from '../src/background/direct-helper';
import { HelperClient } from '../src/background/helper';
import { FakePort, flush } from './fake-port';

function setup(lastError?: string) {
  const ports: FakePort[] = [];
  const direct = new DirectHelper({
    connect: (onEvent, onGone) => {
      const port = new FakePort();
      ports.push(port);
      return new HelperClient(port, onEvent, onGone, () => lastError);
    },
  });
  return { direct, ports };
}

async function hello(ports: FakePort[]) {
  await flush();
  const port = ports.at(-1)!;
  port.emit({ id: port.idOf('hello'), type: 'hello', payload: { protocol: 1, version: '0.3.0', features: ['apps'] } });
  await flush();
  return port;
}

describe('DirectHelper', () => {
  it('says hello, then fetches bridge lines', async () => {
    const { direct, ports } = setup();
    const fetching = direct.fetchBridges('obfs4');
    const port = await hello(ports);
    expect(port.sent[1]).toMatchObject({ type: 'bridges.fetch', payload: { kind: 'obfs4' } });
    port.emit({ id: port.idOf('bridges.fetch'), type: 'bridges.lines', payload: { lines: ['obfs4 a'], source: 'moat', country: null, viaTor: false } });
    await expect(fetching).resolves.toMatchObject({ lines: ['obfs4 a'] });
  });

  it('passes the helper’s error on', async () => {
    const { direct, ports } = setup();
    const fetching = direct.fetchBridges('webtunnel');
    const port = await hello(ports);
    port.emit({ id: port.idOf('bridges.fetch'), type: 'error', payload: { code: 'bridges_failed', message: 'none are needed here' } });
    await expect(fetching).rejects.toThrow('none are needed here');
  });

  it('uses one port for two requests in a row', async () => {
    const { direct, ports } = setup();
    const first = direct.fetchBridges('obfs4');
    const port = await hello(ports);
    port.emit({ id: port.idOf('bridges.fetch'), type: 'bridges.lines', payload: { lines: ['obfs4 a'], source: 'moat', country: null, viaTor: false } });
    await first;
    const second = direct.fetchBridges('webtunnel');
    await flush();
    port.emit({ id: port.idOf('bridges.fetch'), type: 'bridges.lines', payload: { lines: ['webtunnel b'], source: 'moat', country: null, viaTor: false } });
    await expect(second).resolves.toMatchObject({ lines: ['webtunnel b'] });
    expect(ports).toHaveLength(1);
    expect(port.sent.map(m => m.type)).toEqual(['hello', 'bridges.fetch', 'bridges.fetch']);
  });

  it('opens a new port after one that was working goes away', async () => {
    const { direct, ports } = setup();
    const first = direct.fetchBridges('obfs4');
    const port = await hello(ports);
    port.emit({ id: port.idOf('bridges.fetch'), type: 'bridges.lines', payload: { lines: ['obfs4 a'], source: 'moat', country: null, viaTor: false } });
    await first;
    port.die();
    void direct.fetchBridges('obfs4').catch(() => undefined);
    await flush();
    expect(ports).toHaveLength(2);
  });

  it('ignores a late goodbye from an old port', async () => {
    const { direct, ports } = setup();
    const first = direct.fetchBridges('obfs4');
    const old = await hello(ports);
    old.emit({ id: old.idOf('bridges.fetch'), type: 'bridges.lines', payload: { lines: ['obfs4 a'], source: 'moat', country: null, viaTor: false } });
    await first;
    old.die();
    const second = direct.fetchBridges('obfs4');
    const fresh = await hello(ports);
    fresh.emit({ id: fresh.idOf('bridges.fetch'), type: 'bridges.lines', payload: { lines: ['obfs4 b'], source: 'moat', country: null, viaTor: false } });
    await second;
    expect(ports).toHaveLength(2);
    old.die(); // stale: must not clear the newer connection
    const third = direct.fetchBridges('obfs4');
    await flush();
    expect(ports).toHaveLength(2);
    fresh.emit({ id: fresh.idOf('bridges.fetch'), type: 'bridges.lines', payload: { lines: ['obfs4 c'], source: 'moat', country: null, viaTor: false } });
    await expect(third).resolves.toMatchObject({ lines: ['obfs4 c'] });
  });

  it('closes a port whose hello failed, and opens a new one next time', async () => {
    const { direct, ports } = setup();
    const first = direct.fetchBridges('obfs4');
    await flush();
    ports[0].emit({ id: ports[0].idOf('hello'), type: 'error', payload: { code: 'protocol_mismatch', message: 'too old' } });
    await expect(first).rejects.toThrow('too old');
    expect(ports[0].disconnected).toBe(true);
    void direct.fetchBridges('obfs4').catch(() => undefined);
    await flush();
    expect(ports).toHaveLength(2);
  });
});
