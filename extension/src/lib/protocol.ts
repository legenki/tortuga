// The helper's messages (helper/tortuga-helper/src/protocol.rs), as the
// extension sees them. Keep PROTOCOL_VERSION equal to the helper's.

export const PROTOCOL_VERSION = 1;
/** Where the helper's installers are. */
export const HELPER_DOWNLOAD = 'https://github.com/legenki/tortuga/releases/latest';

/** Native messaging host name, registered by the helper's installer. */
export const HOST_NAME = 'org.tortuga.helper';

export type BridgeKind = 'none' | 'snowflake' | 'obfs4' | 'webtunnel';
export type Role = 'guard' | 'bridge' | 'middle' | 'exit';

export interface Hop {
  role: Role;
  id: string;
  /** The relay's address; a Snowflake bridge's is a placeholder. */
  addr: string | null;
  country: string | null;
}

/** Bootstrap stage reported by `tor.status`. */
export type Stage = 'bridge' | 'directory' | 'ready';

export interface Circuit {
  site: string;
  bridge: Exclude<BridgeKind, 'none'> | null;
  hops: Hop[];
}

export type ErrorCode =
  | 'bad_request' | 'hello_required' | 'protocol_mismatch' | 'tor_failed' | 'not_running' | 'torrent_failed' | 'bridges_failed'
  /** A newer tor.start or a tor.stop replaced this start. */
  | 'cancelled'
  /** The helper couldn't send its answer. */
  | 'internal';

/** Bridge lines from bridges.torproject.org (Moat). */
export interface FetchedLines {
  lines: string[];
  /** "bridgedb": handed out for this network; "builtin": the public defaults. */
  source: string;
  country: string | null;
  viaTor: boolean;
}

/** A torrent to fetch: a magnet or http(s) link to a `.torrent`, or the file itself (base64). */
export type TorrentSource = { url: string } | { torrentFile: string };

/** Fetch a `.torrent` link through Tor: the Tor helper's SOCKS port and the site whose circuits to use. */
export interface TorrentVia {
  socksPort: number;
  site: string;
}

/** The hello feature that says the helper understands `via` on torrent requests. */
export const FEATURE_TORRENT_VIA_TOR = 'torrent-via-tor';
/** The hello feature that says the helper understands `torrent.open`. */
export const FEATURE_TORRENT_OPEN = 'torrent-open';

/** What the confirm window shows before a download starts. */
export interface TorrentInfo {
  /** The info hash: the torrent's id across restarts. */
  id: string;
  name: string;
  size: number;
  files: number;
  /** Where the files go. */
  folder: string;
}

export type TorrentState = 'starting' | 'downloading' | 'seeding' | 'paused' | 'error';

/** One row of the Downloads tab. Rates are bytes per second. */
export interface TorrentRow {
  id: string;
  name: string;
  done: number;
  size: number;
  downRate: number;
  upRate: number;
  state: TorrentState;
  error: string | null;
}

/** Anything the helper sends: a reply (with id) or an event (without). */
export type HelperMessage =
  | { id?: number; type: 'hello'; payload: { protocol: number; version: string; features?: string[] } }
  | { id?: number; type: 'ok' }
  | { id?: number; type: 'tor.status'; payload: { phase: Stage; percent: number; blocked: string | null } }
  | { id?: number; type: 'tor.ready'; payload: { socksPort: number } }
  | { id?: number; type: 'circuit'; payload: Circuit }
  | { id?: number; type: 'torrent.info'; payload: TorrentInfo }
  | { id?: number; type: 'torrent.progress'; payload: { torrents: TorrentRow[] } }
  | { id?: number; type: 'bridges.lines'; payload: FetchedLines }
  | { id?: number; type: 'error'; payload: { code: ErrorCode; message: string } };

/** What the extension asks the helper. */
export type HelperRequest =
  | { type: 'hello'; payload: { protocol: number } }
  | { type: 'tor.start'; payload: { bridge: { kind: BridgeKind; lines?: string[] } } }
  | { type: 'tor.stop' }
  | { type: 'tor.newCircuit'; payload: { site: string } }
  | { type: 'torrent.inspect'; payload: { source: TorrentSource; via?: TorrentVia } }
  | { type: 'torrent.add'; payload: { source: TorrentSource; via?: TorrentVia } }
  | { type: 'torrent.open' }
  | { type: 'torrent.pause'; payload: { id: string } }
  | { type: 'torrent.resume'; payload: { id: string } }
  | { type: 'torrent.remove'; payload: { id: string; deleteFiles: boolean } }
  | { type: 'bridges.fetch'; payload: { kind: 'obfs4' | 'webtunnel' } };
