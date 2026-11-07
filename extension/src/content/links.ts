// Runs in every page: a plain left click on a magnet link or a link to a
// .torrent file opens Tortuga's confirm window instead of the browser's own
// handling. Nothing is downloaded until the user confirms there. Only real
// clicks count: a page calling link.click() must not open windows or make the
// helper reach out on its own.
import { isTorrentLink } from '../lib/downloads';
import type { DlMessage } from '../lib/messages';

document.addEventListener('click', e => {
  if (!e.isTrusted || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
  const link = (e.target as Element | null)?.closest?.('a[href]') as HTMLAnchorElement | null;
  if (!link || !isTorrentLink(link.href)) return;
  e.preventDefault();
  e.stopPropagation();
  const msg: DlMessage = { type: 'TORRENT_OPEN', source: { url: link.href } };
  void chrome.runtime.sendMessage(msg);
}, true);
