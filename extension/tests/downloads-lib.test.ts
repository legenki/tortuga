import { describe, it, expect } from 'vitest';
import { activeCount, formatBytes, isTorrentLink, percent, rowLine } from '../src/lib/downloads';
import type { TorrentRow } from '../src/lib/protocol';

const row = (r: Partial<TorrentRow>): TorrentRow => ({
  id: 'ab', name: 'debian.iso', done: 0, size: 792723456, downRate: 0, upRate: 0, state: 'downloading', error: null, ...r,
});

describe('isTorrentLink', () => {
  it('takes magnets with an info hash and links to .torrent files', () => {
    expect(isTorrentLink('magnet:?xt=urn:btih:7acf8fb590b2060dd9c3146ef770169d593433b0&dn=x')).toBe(true);
    expect(isTorrentLink('magnet:?dn=x&xt=urn:btmh:1220abcd')).toBe(true);
    expect(isTorrentLink('https://cdimage.debian.org/debian-13.7.0-amd64-netinst.iso.torrent')).toBe(true);
    expect(isTorrentLink('http://example.org/files/A.TORRENT?download=1')).toBe(true);
  });

  it('leaves everything else alone', () => {
    expect(isTorrentLink('magnet:?xt=urn:ed2k:abc')).toBe(false);
    expect(isTorrentLink('https://example.org/torrent-guide.html')).toBe(false);
    expect(isTorrentLink('ftp://example.org/a.torrent')).toBe(false);
    expect(isTorrentLink('javascript:alert(1)')).toBe(false);
  });
});

describe('formatting', () => {
  it('formats sizes', () => {
    expect(formatBytes(0)).toBe('0 B');
    expect(formatBytes(1536)).toBe('1.5 KB');
    expect(formatBytes(135266304)).toBe('129 MB');
    expect(formatBytes(792723456)).toBe('756 MB');
    expect(formatBytes(4080486400)).toBe('3.8 GB');
  });

  it('describes each state', () => {
    expect(rowLine(row({ state: 'starting' }))).toBe('Starting…');
    expect(rowLine(row({ done: 135266304, downRate: 7032509 }))).toBe('129 MB of 756 MB · 6.7 MB/s');
    expect(rowLine(row({ state: 'seeding', done: 792723456, upRate: 1024 }))).toBe('Done · 756 MB · sharing 1.0 KB/s');
    expect(rowLine(row({ state: 'paused', done: 396361728 }))).toBe('Paused · 50% of 756 MB');
    expect(rowLine(row({ state: 'error', error: 'disk full' }))).toBe('Error: disk full');
    expect(percent(row({ size: 0 }))).toBe(0);
  });

  it('counts only downloads still getting data', () => {
    expect(activeCount([row({}), row({ state: 'starting' }), row({ state: 'paused' }), row({ state: 'seeding' })])).toBe(2);
  });
});
