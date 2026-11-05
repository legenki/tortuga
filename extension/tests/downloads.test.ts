import { describe, it, expect } from 'vitest';
import { Downloads, type DlDeps } from '../src/background/downloads';
import { HELPER_MISSING } from '../src/background/controller';
import { HelperClient } from '../src/background/helper';
import type { DownloadsState } from '../src/lib/messages';
import type { TorrentInfo, TorrentRow } from '../src/lib/protocol';
import { FakePort, flush } from './fake-port';

const INFO: TorrentInfo = { id: '7acf', name: 'debian.iso', size: 792723456, files: 1, folder: '/Users/me/Downloads/Tortuga' };
const ROW: TorrentRow = { id: '7acf', name: 'debian.iso', done: 1, size: 792723456, downRate: 5, upRate: 0, state: 'downloading', error: null };
const MAGNET = { url: 'magnet:?xt=urn:btih:7acf' };

function setup(lastError?: string) {
  const ports: FakePort[] = [];
  const states: DownloadsState[] = [];
  const saved: boolean[] = [];
  const deps: DlDeps = {
    connect: (onEvent, onGone) => {
      const port = new FakePort();
      ports.push(port);
      return new HelperClient(port, onEvent, onGone, () => lastError);
    },
    broadcast: s => void states.push(s),
    saveActive: async a => void saved.push(a),
  };
  return { d: new Downloads(deps), ports, states, saved };
}

/** Answer the hello on the newest port. */
async function hello(ports: FakePort[]) {
  await flush();
  const port = ports.at(-1)!;
  port.emit({ id: port.idOf('hello'), type: 'hello', payload: { protocol: 1, version: '0.1.0' } });
  await flush();
  return port;
}

describe('Downloads', () => {
  it('connects on first use, says hello, then inspects', async () => {
    const { d, ports } = setup();
    const inspecting = d.inspect(MAGNET);
    const port = await hello(ports);
    expect(port.sent[1]).toMatchObject({ type: 'torrent.inspect', payload: { source: MAGNET } });
    port.emit({ id: port.idOf('torrent.inspect'), type: 'torrent.info', payload: INFO });
    await expect(inspecting).resolves.toEqual(INFO);
    expect(d.current.folder).toBe(INFO.folder);
  });

  it('uses one port for every request', async () => {
    const { d, ports } = setup();
    const first = d.inspect(MAGNET);
    const port = await hello(ports);
    port.emit({ id: port.idOf('torrent.inspect'), type: 'torrent.info', payload: INFO });
    await first;
    const pausing = d.pause('7acf');
    await flush();
    port.emit({ id: port.idOf('torrent.pause'), type: 'ok' });
    await pausing;
    expect(ports).toHaveLength(1);
  });

  it('remembers that there are downloads, and forgets when the list empties', async () => {
    const { d, ports, saved, states } = setup();
    const adding = d.add(MAGNET);
    const port = await hello(ports);
    port.emit({ id: port.idOf('torrent.add'), type: 'torrent.info', payload: INFO });
    await adding;
    port.emit({ type: 'torrent.progress', payload: { torrents: [ROW] } });
    expect(states.at(-1)?.rows).toEqual([ROW]);
    port.emit({ type: 'torrent.progress', payload: { torrents: [] } });
    await flush();
    expect(saved).toEqual([true, false]);
  });

  it('passes the helper’s error on', async () => {
    const { d, ports } = setup();
    const adding = d.add({ url: 'magnet:?xt=urn:btih:bad' });
    const port = await hello(ports);
    port.emit({ id: port.idOf('torrent.add'), type: 'error', payload: { code: 'torrent_failed', message: 'no peers' } });
    await expect(adding).rejects.toThrow('no peers');
  });

  it('gets bridge lines over the same port', async () => {
    const { d, ports } = setup();
    const fetching = d.fetchBridges('webtunnel');
    const port = await hello(ports);
    expect(port.sent[1]).toMatchObject({ type: 'bridges.fetch', payload: { kind: 'webtunnel' } });
    port.emit({ id: port.idOf('bridges.fetch'), type: 'error', payload: { code: 'bridges_failed', message: 'none are needed here' } });
    await expect(fetching).rejects.toThrow('none are needed here');
  });

  it('reports a missing helper and reconnects on the next request', async () => {
    const { d, ports, states } = setup('Specified native messaging host not found.');
    const first = d.inspect(MAGNET);
    await flush();
    ports[0].die();
    await expect(first).rejects.toThrow();
    expect(states.at(-1)).toMatchObject({ helperMissing: true, error: HELPER_MISSING, rows: [] });
    void d.inspect(MAGNET).catch(() => undefined);
    await flush();
    expect(ports).toHaveLength(2);
  });
});
