import { describe, it, expect } from 'vitest';
import { senderAllowed } from '../src/lib/senders';

const ID = 'abcdefghijklmnop';
const URL = `chrome-extension://${ID}/`;

describe('senderAllowed', () => {
  it('lets Tortuga’s own pages send anything', () => {
    expect(senderAllowed('TOR_OFF', { id: ID, url: `${URL}popup.html` }, ID, URL)).toBe(true);
    expect(senderAllowed('TORRENT_CONFIRM', { id: ID, url: `${URL}confirm.html?t=x` }, ID, URL)).toBe(true);
  });

  it('lets content scripts only put a torrent up for confirmation', () => {
    const page = { id: ID, url: 'https://example.org/' };
    expect(senderAllowed('TORRENT_OPEN', page, ID, URL)).toBe(true);
    for (const type of ['TOR_OFF', 'TOR_ON', 'SET_BRIDGE', 'TORRENT_REMOVE', 'TORRENT_CONFIRM', 'FETCH_BRIDGES']) {
      expect(senderAllowed(type, page, ID, URL)).toBe(false);
    }
  });

  it('refuses other extensions', () => {
    expect(senderAllowed('TORRENT_OPEN', { id: 'other', url: `${URL}popup.html` }, ID, URL)).toBe(false);
  });

  it('does not take a look-alike origin for its own', () => {
    expect(senderAllowed('TOR_OFF', { id: ID, url: `https://evil.example/?${URL}` }, ID, URL)).toBe(false);
  });
});
