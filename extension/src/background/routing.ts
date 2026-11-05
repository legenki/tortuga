import { topSiteOf } from '../lib/site';

const LOCALHOST = '127.0.0.1';

/**
 * Firefox: the answer for one request. No port: the browser's own setting.
 * Otherwise the helper's SOCKS port with the site as login, so each site gets
 * its own circuits, and no failover, so nothing goes out directly.
 */
export function firefoxAnswer(port: number | null, details: chrome.proxy.FirefoxRequestDetails): chrome.proxy.FirefoxProxyAnswer {
  if (port === null) return undefined;
  return [{ type: 'socks', host: LOCALHOST, port, proxyDNS: true, username: topSiteOf(details), password: 'x' }, null];
}

/** Chrome: one SOCKS5 server for the incognito session (Chrome can't send a SOCKS login). */
export function chromeConfig(port: number): chrome.proxy.ProxyConfig {
  return { mode: 'fixed_servers', rules: { singleProxy: { scheme: 'socks5', host: LOCALHOST, port } } };
}

/**
 * Chrome: the settings scope for Incognito windows. Not 'incognito_session_only':
 * Chrome refuses it while no Incognito window is open, which is where Tor gets
 * turned on, and drops it when the last one closes, which would let the next
 * Incognito window go out directly.
 */
export const INCOGNITO_SCOPE = 'incognito_persistent';

/** Chrome: route incognito windows through `port`, or release the setting. */
export async function applyChromeRoute(port: number | null): Promise<void> {
  if (port === null) await chrome.proxy.settings.clear({ scope: INCOGNITO_SCOPE });
  else await chrome.proxy.settings.set({ value: chromeConfig(port), scope: INCOGNITO_SCOPE });
}
