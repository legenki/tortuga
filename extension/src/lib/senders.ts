/**
 * Who may send what to the background. Content scripts run in every page and
 * only ever ask to put a torrent link up for confirmation; everything else
 * (Tor on / off, bridges, removing downloads…) comes from Tortuga's own pages.
 */
export const PAGE_MESSAGES: ReadonlySet<string> = new Set(['TORRENT_OPEN']);

export interface SenderLike {
  id?: string;
  url?: string;
}

/** `ownId` / `ownUrl`: chrome.runtime.id and chrome.runtime.getURL(''). */
export function senderAllowed(type: string, sender: SenderLike, ownId: string, ownUrl: string): boolean {
  if (sender.id !== ownId) return false;
  if (PAGE_MESSAGES.has(type)) return true;
  return sender.url !== undefined && sender.url.startsWith(ownUrl);
}
