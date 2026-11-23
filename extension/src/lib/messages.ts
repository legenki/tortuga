import type { BridgeKind, FetchedLines } from './protocol';
import type { TorState } from './state';

/** Popup → background. Each is answered with the current TorState. */
export type BgMessage =
  | { type: 'GET_STATE' }
  | { type: 'TOR_ON'; bridge: BridgeKind }
  | { type: 'TOR_OFF' }
  | { type: 'SET_BRIDGE'; bridge: BridgeKind }
  | { type: 'NEW_CIRCUIT'; site: string };

/** Background → popup, after every change. */
export type BgBroadcast = { type: 'STATE'; state: TorState };

/** Settings page → background: get bridge lines from bridges.torproject.org. */
export type BridgesMessage = { type: 'FETCH_BRIDGES'; kind: keyof BridgeLines };
export type BridgesResult = ({ ok: true } & FetchedLines) | { ok: false; error: string };

/** What survives the background being restarted. */
export interface Stored {
  enabled: boolean;
  bridge: BridgeKind;
}

/** Bridge lines the user saved on the settings page, per transport. */
export interface BridgeLines {
  obfs4: string[];
  webtunnel: string[];
}

export const LINES_KEY = 'tortugaBridgeLines';
export const NO_LINES: BridgeLines = { obfs4: [], webtunnel: [] };

export const STORAGE_KEY = 'tortuga';
