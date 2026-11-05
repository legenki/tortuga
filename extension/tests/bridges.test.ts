import { describe, it, expect } from 'vitest';
import { bridgeReady, fetchedText, linesFor, parseLines } from '../src/lib/bridges';
import { NO_LINES } from '../src/lib/messages';

const OBFS4 = 'obfs4 192.0.2.55:38114 316E643333645F6D79216558614D3931657A5F5F cert=YXJlIGZyZXF1ZW50bHkgZnVsbA iat-mode=0';
const WEBTUNNEL = 'webtunnel [2001:db8::1]:443 8838024498816A039FCBBAB14E6F40A0843051FA url=https://example.org/path ver=0.0.1';

describe('parseLines', () => {
  it('accepts lines with or without "Bridge" and normalises them', () => {
    const text = `# from bridges.torproject.org\n${OBFS4}\n\nBridge ${OBFS4}\n`;
    expect(parseLines('obfs4', text)).toEqual({ lines: [`Bridge ${OBFS4}`, `Bridge ${OBFS4}`], errors: [] });
  });

  it('accepts WebTunnel lines with IPv6 addresses', () => {
    expect(parseLines('webtunnel', WEBTUNNEL)).toEqual({ lines: [`Bridge ${WEBTUNNEL}`], errors: [] });
  });

  it('names the line and the problem', () => {
    const { lines, errors } = parseLines('obfs4', `${WEBTUNNEL}\nobfs4 nowhere\nobfs4 192.0.2.1:443 notafingerprint`);
    expect(lines).toEqual([]);
    expect(errors).toEqual([
      'Line 1: starts with “webtunnel”, expected “obfs4”',
      'Line 2: no address:port after “obfs4”',
      'Line 3: no 40-character fingerprint after the address',
    ]);
  });
});

describe('fetchedText', () => {
  it('says how many lines, which kind and how they came', () => {
    expect(fetchedText('obfs4', { lines: ['a', 'b', 'c'], source: 'builtin', country: 'it', viaTor: false }))
      .toBe('Got 3 obfs4 lines from bridges.torproject.org — built-in (IT).');
    expect(fetchedText('webtunnel', { lines: ['a'], source: 'bridgedb', country: 'ru', viaTor: true }))
      .toBe('Got 1 WebTunnel line from bridges.torproject.org — handed out for your network (RU), through Tor.');
  });
});

describe('bridgeReady / linesFor', () => {
  const saved = { ...NO_LINES, obfs4: [`Bridge ${OBFS4}`] };

  it('needs saved lines only for obfs4 and WebTunnel', () => {
    expect(bridgeReady('none', NO_LINES)).toBe(true);
    expect(bridgeReady('snowflake', NO_LINES)).toBe(true);
    expect(bridgeReady('obfs4', NO_LINES)).toBe(false);
    expect(bridgeReady('obfs4', saved)).toBe(true);
    expect(bridgeReady('webtunnel', saved)).toBe(false);
  });

  it('sends lines only for the transports that need them', () => {
    expect(linesFor('obfs4', saved)).toEqual([`Bridge ${OBFS4}`]);
    expect(linesFor('snowflake', saved)).toEqual([]);
  });
});
