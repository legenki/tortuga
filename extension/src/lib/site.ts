import { getDomain } from 'tldts';

/** The circuit key Chrome uses: it can't tell sites apart (no SOCKS login). */
export const DEFAULT_SITE = 'default';

/**
 * The registrable domain of `url` ("github.com" for "https://api.github.com/x"),
 * or the bare host for IPs and single-label names, or DEFAULT_SITE for URLs
 * without a host.
 */
export function siteOf(url: string | undefined): string {
  if (!url) return DEFAULT_SITE;
  let host: string;
  try {
    host = new URL(url).hostname;
  } catch {
    return DEFAULT_SITE;
  }
  if (!host) return DEFAULT_SITE;
  return getDomain(host, { allowPrivateDomains: true }) ?? host.replace(/^\[|\]$/g, '');
}

/** The site of the top-level page a Firefox request belongs to. */
export function topSiteOf(details: chrome.proxy.FirefoxRequestDetails): string {
  const ancestors = details.frameAncestors;
  if (ancestors && ancestors.length > 0) return siteOf(ancestors[ancestors.length - 1].url);
  if (details.type === 'main_frame') return siteOf(details.url);
  return siteOf(details.documentUrl ?? details.url);
}
