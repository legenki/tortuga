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

  it('reuses one port, and reconnects after the helper goes away', async () => {
    const { direct, ports } = setup('Specified native messaging host not found.');
    const first = direct.fetchBridges('obfs4');
    await flush();
    ports[0].die();
    await expect(first).rejects.toThrow();
    void direct.fetchBridges('obfs4').catch(() => undefined);
    await flush();
    expect(ports).toHaveLength(2);
  });
});
