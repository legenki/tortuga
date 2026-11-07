import type { TorrentSource, TorrentVia } from './protocol';
import type { TorState } from './state';

/** A torrent waiting in a confirm window, and where its link was clicked. */
export interface PendingTorrent {
  source: TorrentSource;
  /** The site whose circuits fetch a `.torrent` link through Tor. */
  site: string;
  /**
   * Chrome: whether the link came from an Incognito window, the only ones Tor
   * covers there; null when unknown (pasted in the popup), taken as Incognito.
   */
  incognito: boolean | null;
  /** The user agreed to look a magnet up from their own IP while Tor is on. */
  direct: boolean;
}

/**
 * How the helper may reach the network for a pending torrent, before the
 * download itself (which always runs from the user's own IP, as the confirm
 * window says):
 * - direct: as before (Tor doesn't cover this link, or a file needs no fetch);
 * - tor: fetch the `.torrent` link through the Tor helper's SOCKS port;
 * - ask: a magnet while Tor is on; looking it up would reveal the user's IP;
 * - wait: a `.torrent` link that must go through Tor, but Tor isn't ready.
 */
export type TorrentRoute =
  | { kind: 'direct' }
  | { kind: 'tor'; via: TorrentVia }
  | { kind: 'ask' }
  | { kind: 'wait' };

export const TOR_NOT_READY = 'Tor is not connected yet. Try again once it is: this link is fetched through Tor, never directly.';

export function torrentRoute(p: PendingTorrent, tor: Pick<TorState, 'phase' | 'socksPort'>, target: 'chrome' | 'firefox'): TorrentRoute {
  if (!('url' in p.source)) return { kind: 'direct' };
  const torCovers = tor.phase !== 'off' && (target === 'firefox' || p.incognito !== false);
  if (!torCovers) return { kind: 'direct' };
  if (/^magnet:/i.test(p.source.url)) return p.direct ? { kind: 'direct' } : { kind: 'ask' };
  if (tor.phase === 'on' && tor.socksPort !== null) return { kind: 'tor', via: { socksPort: tor.socksPort, site: p.site } };
  return { kind: 'wait' };
}
