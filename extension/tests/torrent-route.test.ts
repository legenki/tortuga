import { describe, it, expect } from 'vitest';
import { torrentRoute, type PendingTorrent } from '../src/lib/torrent-route';

const FILE: PendingTorrent = { source: { torrentFile: 'ZDQ6aW5mb2Vl' }, site: 'example.org', incognito: null, direct: false };
const LINK: PendingTorrent = { source: { url: 'https://example.org/a.torrent' }, site: 'example.org', incognito: null, direct: false };
const MAGNET: PendingTorrent = { source: { url: 'magnet:?xt=urn:btih:7acf&tr=http://tracker.example/announce' }, site: 'example.org', incognito: null, direct: false };

const OFF = { phase: 'off', socksPort: null } as const;
const ON = { phase: 'on', socksPort: 9150 } as const;
const CONNECTING = { phase: 'connecting', socksPort: null } as const;
const FAILED = { phase: 'failed', socksPort: null } as const;

describe('torrentRoute', () => {
  it('goes direct while Tor is off', () => {
    expect(torrentRoute(LINK, OFF, 'firefox')).toEqual({ kind: 'direct' });
    expect(torrentRoute(MAGNET, OFF, 'firefox')).toEqual({ kind: 'direct' });
  });

  it('fetches .torrent links through Tor, as the site they were on', () => {
    expect(torrentRoute(LINK, ON, 'firefox')).toEqual({ kind: 'tor', via: { socksPort: 9150, site: 'example.org' } });
  });

  it('never fetches a .torrent link directly while Tor is connecting or stopped', () => {
    expect(torrentRoute(LINK, CONNECTING, 'firefox')).toEqual({ kind: 'wait' });
    expect(torrentRoute(LINK, FAILED, 'firefox')).toEqual({ kind: 'wait' });
  });

  it('asks before looking a magnet up from the user’s own IP', () => {
    expect(torrentRoute(MAGNET, ON, 'firefox')).toEqual({ kind: 'ask' });
    expect(torrentRoute(MAGNET, CONNECTING, 'firefox')).toEqual({ kind: 'ask' });
    expect(torrentRoute({ ...MAGNET, direct: true }, ON, 'firefox')).toEqual({ kind: 'direct' });
  });

  it('needs no network for a .torrent file', () => {
    expect(torrentRoute(FILE, ON, 'firefox')).toEqual({ kind: 'direct' });
  });

  it('Chrome: only Incognito windows are covered; unknown counts as Incognito', () => {
    expect(torrentRoute({ ...LINK, incognito: false }, ON, 'chrome')).toEqual({ kind: 'direct' });
    expect(torrentRoute({ ...MAGNET, incognito: false }, ON, 'chrome')).toEqual({ kind: 'direct' });
    expect(torrentRoute({ ...LINK, incognito: true }, ON, 'chrome')).toMatchObject({ kind: 'tor' });
    expect(torrentRoute(LINK, ON, 'chrome')).toMatchObject({ kind: 'tor' });
    expect(torrentRoute(MAGNET, ON, 'chrome')).toEqual({ kind: 'ask' });
  });

  it('Firefox: every window is covered', () => {
    expect(torrentRoute({ ...LINK, incognito: false }, ON, 'firefox')).toMatchObject({ kind: 'tor' });
  });
});
