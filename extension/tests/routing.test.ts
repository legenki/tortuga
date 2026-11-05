import { describe, it, expect } from 'vitest';
import { chromeConfig, firefoxAnswer } from '../src/background/routing';

describe('firefoxAnswer', () => {
  const page = { requestId: '1', tabId: 1, type: 'main_frame', url: 'https://www.torproject.org/' };

  it('leaves requests alone when off', () => {
    expect(firefoxAnswer(null, page)).toBeUndefined();
  });

  it('sends the site as SOCKS login with no failover', () => {
    expect(firefoxAnswer(9150, page)).toEqual([
      { type: 'socks', host: '127.0.0.1', port: 9150, proxyDNS: true, username: 'torproject.org', password: 'x' },
      null,
    ]);
  });
});

describe('chromeConfig', () => {
  it('is one SOCKS5 server', () => {
    expect(chromeConfig(9150)).toEqual({ mode: 'fixed_servers', rules: { singleProxy: { scheme: 'socks5', host: '127.0.0.1', port: 9150 } } });
  });
});
