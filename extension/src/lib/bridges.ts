import type { BridgeLines } from './messages';
import type { BridgeKind, FetchedLines } from './protocol';

export type LineKind = keyof BridgeLines;

const ADDR = /^(\[[0-9a-f:]+\]|[0-9.]+|[a-z0-9.-]+):\d{1,5}$/i;
const FINGERPRINT = /^[0-9A-F]{40}$/i;

/**
 * Bridge lines pasted on the settings page, as from bridges.torproject.org:
 * `obfs4 1.2.3.4:443 <40 hex> cert=… iat-mode=0`, with or without a leading
 * `Bridge`. Blank lines and `#` comments are skipped. Lines come back as
 * `Bridge …`, the form the helper parses.
 */
export function parseLines(kind: LineKind, text: string): { lines: string[]; errors: string[] } {
  const lines: string[] = [];
  const errors: string[] = [];
  text.split('\n').forEach((raw, i) => {
    const line = raw.trim().replace(/^Bridge\s+/i, '');
    if (!line || line.startsWith('#')) return;
    const [transport, addr, fingerprint] = line.split(/\s+/);
    const where = `Line ${i + 1}`;
    if (transport !== kind) errors.push(`${where}: starts with “${transport}”, expected “${kind}”`);
    else if (!addr || !ADDR.test(addr)) errors.push(`${where}: no address:port after “${kind}”`);
    else if (!fingerprint || !FINGERPRINT.test(fingerprint)) errors.push(`${where}: no 40-character fingerprint after the address`);
    else lines.push(`Bridge ${line}`);
  });
  return { lines, errors };
}

/** What the settings page says after getting lines from bridges.torproject.org. */
export function fetchedText(kind: LineKind, f: FetchedLines): string {
  const name = kind === 'obfs4' ? 'obfs4' : 'WebTunnel';
  const what = f.source === 'builtin' ? 'built-in' : 'handed out for your network';
  const where = f.country ? ` (${f.country.toUpperCase()})` : '';
  const via = f.viaTor ? ', through Tor' : '';
  return `Got ${f.lines.length} ${name} ${f.lines.length === 1 ? 'line' : 'lines'} from bridges.torproject.org — ${what}${where}${via}.`;
}

/** Can Tor start with this bridge kind? obfs4 and WebTunnel need saved lines. */
export function bridgeReady(kind: BridgeKind, saved: BridgeLines): boolean {
  return kind === 'none' || kind === 'snowflake' || saved[kind].length > 0;
}

/** The lines to send to the helper for `kind` (Snowflake uses the helper's defaults). */
export function linesFor(kind: BridgeKind, saved: BridgeLines): string[] {
  return kind === 'obfs4' || kind === 'webtunnel' ? saved[kind] : [];
}
