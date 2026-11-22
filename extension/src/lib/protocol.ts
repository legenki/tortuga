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
  | 'bad_request' | 'hello_required' | 'protocol_mismatch' | 'tor_failed' | 'not_running' | 'bridges_failed'
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

/** Anything the helper sends: a reply (with id) or an event (without). */
export type HelperMessage =
  | { id?: number; type: 'hello'; payload: { protocol: number; version: string; features?: string[] } }
  | { id?: number; type: 'ok' }
  | { id?: number; type: 'tor.status'; payload: { phase: Stage; percent: number; blocked: string | null } }
  | { id?: number; type: 'tor.ready'; payload: { socksPort: number } }
  | { id?: number; type: 'circuit'; payload: Circuit }
  | { id?: number; type: 'bridges.lines'; payload: FetchedLines }
  | { id?: number; type: 'error'; payload: { code: ErrorCode; message: string } };

/** What the extension asks the helper. */
export type HelperRequest =
  | { type: 'hello'; payload: { protocol: number } }
  | { type: 'tor.start'; payload: { bridge: { kind: BridgeKind; lines?: string[] } } }
  | { type: 'tor.stop' }
  | { type: 'tor.newCircuit'; payload: { site: string } }
  | { type: 'bridges.fetch'; payload: { kind: 'obfs4' | 'webtunnel' } };
