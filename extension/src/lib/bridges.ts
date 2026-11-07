import type { BridgeLines } from './messages';
import type { BridgeKind, FetchedLines } from './protocol';

export type LineKind = keyof BridgeLines;

/**
 * `ip:port` as Tor's bridge lines have it: an IPv4 address or a bracketed
 * IPv6 one (no host names: Arti takes neither), and a port from 1 to 65535.
 */
export function isBridgeAddr(addr: string): boolean {
  const m = /^(?:(\d{1,3}(?:\.\d{1,3}){3})|\[([0-9a-f:.]+)\]):(\d{1,5})$/i.exec(addr);
  if (!m) return false;
  const port = Number(m[3]);
  if (port < 1 || port > 65535) return false;
  if (m[1]) return m[1].split('.').every(octet => Number(octet) <= 255);
  try {
    return new URL(`http://[${m[2]}]/`).hostname !== '';
  } catch {
    return false;
  }
}
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
    else if (!addr || !isBridgeAddr(addr)) errors.push(`${where}: no IP address:port after “${kind}” (like 192.0.2.1:443 or [2001:db8::1]:443)`);
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

/**
 * New lines saved for the bridge Tor runs on, or is connecting or failing
 * on: the lines to restart it with. Null when there is nothing to apply.
 */
export function linesToApply(tor: { phase: string; bridge: BridgeKind }, old: BridgeLines, next: BridgeLines): string[] | null {
  if (tor.phase === 'off' || (tor.bridge !== 'obfs4' && tor.bridge !== 'webtunnel')) return null;
  const lines = next[tor.bridge];
  if (lines.length === 0 || JSON.stringify(lines) === JSON.stringify(old[tor.bridge])) return null;
  return lines;
}

/** The lines to send to the helper for `kind` (Snowflake uses the helper's defaults). */
export function linesFor(kind: BridgeKind, saved: BridgeLines): string[] {
  return kind === 'obfs4' || kind === 'webtunnel' ? saved[kind] : [];
}
