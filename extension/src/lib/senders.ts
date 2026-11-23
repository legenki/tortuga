/**
 * Who may send messages to the background: only Tortuga's own pages (popup,
 * settings). Nothing runs in web pages any more, so nothing there may ask.
 */
export interface SenderLike {
  id?: string;
  url?: string;
}

/** `ownId` / `ownUrl`: chrome.runtime.id and chrome.runtime.getURL(''). */
export function senderAllowed(sender: SenderLike, ownId: string, ownUrl: string): boolean {
  return sender.id === ownId && sender.url !== undefined && sender.url.startsWith(ownUrl);
}
