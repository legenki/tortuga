// The helper's messages (helper/tortuga-helper/src/protocol.rs), as the
// extension sees them. Keep PROTOCOL_VERSION equal to the helper's.

export const PROTOCOL_VERSION = 1;
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

export type ErrorCode = 'bad_request' | 'hello_required' | 'protocol_mismatch' | 'tor_failed' | 'not_running' | 'torrent_failed';

/** A torrent to fetch: a magnet or http(s) link to a `.torrent`, or the file itself (base64). */
export type TorrentSource = { url: string } | { torrentFile: string };

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
  | { id?: number; type: 'hello'; payload: { protocol: number; version: string } }
  | { id?: number; type: 'ok' }
  | { id?: number; type: 'tor.status'; payload: { phase: Stage; percent: number; blocked: string | null } }
  | { id?: number; type: 'tor.ready'; payload: { socksPort: number } }
  | { id?: number; type: 'circuit'; payload: Circuit }
  | { id?: number; type: 'torrent.info'; payload: TorrentInfo }
  | { id?: number; type: 'torrent.progress'; payload: { torrents: TorrentRow[] } }
  | { id?: number; type: 'error'; payload: { code: ErrorCode; message: string } };

/** What the extension asks the helper. */
export type HelperRequest =
  | { type: 'hello'; payload: { protocol: number } }
  | { type: 'tor.start'; payload: { bridge: { kind: BridgeKind; lines?: string[] } } }
  | { type: 'tor.stop' }
  | { type: 'tor.newCircuit'; payload: { site: string } }
  | { type: 'torrent.inspect'; payload: { source: TorrentSource } }
  | { type: 'torrent.add'; payload: { source: TorrentSource } }
  | { type: 'torrent.pause'; payload: { id: string } }
  | { type: 'torrent.resume'; payload: { id: string } }
  | { type: 'torrent.remove'; payload: { id: string; deleteFiles: boolean } };
