// Chrome only accepts scope 'incognito_session_only' while an Incognito window
// is open ("You cannot set a preference with scope 'incognito_session_only'
// when no incognito window is open"), and drops it when the last one closes.
// Tortuga is turned on from a regular window, and must keep covering the
// Incognito windows opened later, so it uses 'incognito_persistent'.
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { applyChromeRoute } from '../src/background/routing';
import { applyPrivacy } from '../src/background/privacy';

type Call = [string, unknown];
let calls: Call[];

function setting(name: string) {
  return {
    set: vi.fn(async (d: unknown) => void calls.push([`${name}.set`, d])),
    clear: vi.fn(async (d: unknown) => void calls.push([`${name}.clear`, d])),
  };
}

beforeEach(() => {
  calls = [];
  vi.stubGlobal('chrome', {
    proxy: { settings: setting('proxy') },
    privacy: { network: { webRTCIPHandlingPolicy: setting('webrtc') } },
  });
});

describe('Chrome settings scope', () => {
  it('routes Incognito windows with a scope that works with none open', async () => {
    await applyChromeRoute(9150);
    await applyChromeRoute(null);
    expect(calls).toEqual([
      ['proxy.set', { value: { mode: 'fixed_servers', rules: { singleProxy: { scheme: 'socks5', host: '127.0.0.1', port: 9150 } } }, scope: 'incognito_persistent' }],
      ['proxy.clear', { scope: 'incognito_persistent' }],
    ]);
  });

  it('applies and releases the WebRTC rule with the same scope', async () => {
    await applyPrivacy(true);
    await applyPrivacy(false);
    expect(calls).toEqual([
      ['webrtc.set', { value: 'disable_non_proxied_udp', scope: 'incognito_persistent' }],
      ['webrtc.clear', { scope: 'incognito_persistent' }],
    ]);
  });
});
