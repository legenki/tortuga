import { describe, it, expect } from 'vitest';
import { DEFAULT_SITE, siteOf, topSiteOf } from '../src/lib/site';

describe('siteOf', () => {
  it('reduces a host to its registrable domain', () => {
    expect(siteOf('https://api.github.com/repos')).toBe('github.com');
    expect(siteOf('https://www.bbc.co.uk/news')).toBe('bbc.co.uk');
  });

  it('keeps private suffixes apart', () => {
    expect(siteOf('https://alice.github.io/')).toBe('alice.github.io');
  });

  it('uses the bare host for IPs and single labels', () => {
    expect(siteOf('http://192.168.1.1/')).toBe('192.168.1.1');
    expect(siteOf('http://[::1]:8080/')).toBe('::1');
    expect(siteOf('http://localhost:3000/')).toBe('localhost');
  });

  it('falls back to the default site', () => {
    expect(siteOf(undefined)).toBe(DEFAULT_SITE);
    expect(siteOf('not a url')).toBe(DEFAULT_SITE);
    expect(siteOf('about:blank')).toBe(DEFAULT_SITE);
  });
});

describe('topSiteOf', () => {
  const base = { requestId: '1', tabId: 1 };

  it('uses the top-level frame for subresources in iframes', () => {
    expect(topSiteOf({
      ...base, type: 'script', url: 'https://cdn.example.net/a.js', documentUrl: 'https://ads.tracker.com/frame',
      frameAncestors: [{ url: 'https://ads.tracker.com/frame', frameId: 5 }, { url: 'https://news.ycombinator.com/', frameId: 0 }],
    })).toBe('ycombinator.com');
  });

  it('uses the request itself for a page load', () => {
    expect(topSiteOf({ ...base, type: 'main_frame', url: 'https://en.wikipedia.org/wiki/Tor' })).toBe('wikipedia.org');
  });

  it('uses the document for a top-level page subresource', () => {
    expect(topSiteOf({ ...base, type: 'image', url: 'https://i.imgur.com/x.png', documentUrl: 'https://www.reddit.com/' })).toBe('reddit.com');
  });
});
