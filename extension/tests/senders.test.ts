import { describe, it, expect } from 'vitest';
import { senderAllowed } from '../src/lib/senders';

const ID = 'abcdefghijklmnop';
const URL = `chrome-extension://${ID}/`;

describe('senderAllowed', () => {
  it('lets Tortuga’s own pages send anything', () => {
    expect(senderAllowed({ id: ID, url: `${URL}popup.html` }, ID, URL)).toBe(true);
    expect(senderAllowed({ id: ID, url: `${URL}options.html` }, ID, URL)).toBe(true);
  });

  it('refuses web pages, even with the extension’s id', () => {
    expect(senderAllowed({ id: ID, url: 'https://example.org/' }, ID, URL)).toBe(false);
  });

  it('refuses other extensions', () => {
    expect(senderAllowed({ id: 'other', url: `${URL}popup.html` }, ID, URL)).toBe(false);
  });

  it('does not take a look-alike origin for its own', () => {
    expect(senderAllowed({ id: ID, url: `https://evil.example/?${URL}` }, ID, URL)).toBe(false);
  });
});
