import type { TorrentRow } from './protocol';

/**
 * A link the Downloads feature takes: a magnet with a BitTorrent info hash, or
 * an http(s) address whose path ends in `.torrent`.
 */
export function isTorrentLink(href: string): boolean {
  if (/^magnet:\?/i.test(href)) return /[?&]xt=urn:bt(ih|mh):/i.test(href);
  try {
    const u = new URL(href);
    return (u.protocol === 'http:' || u.protocol === 'https:') && /\.torrent$/i.test(u.pathname);
  } catch {
    return false;
  }
}

const UNITS = ['B', 'KB', 'MB', 'GB', 'TB'];

/** 1536 → "1.5 KB"; one decimal below 100, none above. */
export function formatBytes(n: number): string {
  let v = Math.max(0, n);
  let i = 0;
  while (v >= 1024 && i < UNITS.length - 1) {
    v /= 1024;
    i++;
  }
  const digits = i === 0 || v >= 100 ? 0 : 1;
  return `${v.toFixed(digits)} ${UNITS[i]}`;
}

export function percent(row: TorrentRow): number {
  return row.size > 0 ? Math.min(100, Math.floor((row.done / row.size) * 100)) : 0;
}

/** The line under a download's name. */
export function rowLine(row: TorrentRow): string {
  switch (row.state) {
    case 'starting':
      return 'Starting…';
    case 'downloading':
      return `${formatBytes(row.done)} of ${formatBytes(row.size)} · ${formatBytes(row.downRate)}/s`;
    case 'seeding':
      return `Done · ${formatBytes(row.size)} · sharing ${formatBytes(row.upRate)}/s`;
    case 'paused':
      return `Paused · ${percent(row)}% of ${formatBytes(row.size)}`;
    case 'error':
      return `Error: ${row.error ?? 'unknown'}`;
  }
}

/** Downloads still getting data, for the tab's badge. */
export function activeCount(rows: TorrentRow[]): number {
  return rows.filter(r => r.state === 'starting' || r.state === 'downloading').length;
}
