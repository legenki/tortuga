import type { BridgeKind, FetchedLines, TorrentInfo, TorrentRow, TorrentSource } from './protocol';
import type { TorState } from './state';

/** Popup → background. Each is answered with the current TorState. */
export type BgMessage =
  | { type: 'GET_STATE' }
  | { type: 'TOR_ON'; bridge: BridgeKind }
  | { type: 'TOR_OFF' }
  | { type: 'SET_BRIDGE'; bridge: BridgeKind }
  | { type: 'NEW_CIRCUIT'; site: string };

/** Background → popup, after every change. */
export type BgBroadcast = { type: 'STATE'; state: TorState } | { type: 'DOWNLOADS'; state: DownloadsState };

/** Everything the Downloads tab shows. */
export interface DownloadsState {
  rows: TorrentRow[];
  /** Where downloads are saved, once the helper has said. */
  folder: string | null;
  error: string | null;
  helperMissing: boolean;
}

/**
 * Messages about downloads, from the popup, the confirm window and the link
 * catcher in pages. OPEN puts a torrent up for confirmation and opens the
 * confirm window; the window then INSPECTs and CONFIRMs it by its token.
 */
export type DlMessage =
  | { type: 'GET_DOWNLOADS' }
  | { type: 'TORRENT_OPEN'; source: TorrentSource }
  /** `direct`: the user agreed to look a magnet up from their own IP while Tor is on. */
  | { type: 'TORRENT_INSPECT'; token: string; direct?: boolean }
  | { type: 'TORRENT_CONFIRM'; token: string }
  | { type: 'TORRENT_CANCEL'; token: string }
  | { type: 'TORRENT_PAUSE'; id: string }
  | { type: 'TORRENT_RESUME'; id: string }
  | { type: 'TORRENT_REMOVE'; id: string; deleteFiles: boolean };

/**
 * The answer to INSPECT / CONFIRM. `askDirect`: Tor is on and this is a magnet,
 * which can only be looked up from the user's own IP; ask first.
 */
export type DlResult = { ok: true; info: TorrentInfo } | { ok: false; error: string; askDirect?: boolean };

/** Settings page → background: get bridge lines from bridges.torproject.org. */
export type BridgesMessage = { type: 'FETCH_BRIDGES'; kind: keyof BridgeLines };
export type BridgesResult = ({ ok: true } & FetchedLines) | { ok: false; error: string };

/** Set while there are downloads, so a restarted browser resumes them. */
export const DOWNLOADS_KEY = 'tortugaDownloads';

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
