// The confirm window: opened by the background for a torrent put up with
// TORRENT_OPEN, it shows what the torrent is and starts it only on Download.
import { formatBytes } from '../lib/downloads';
import type { DlMessage, DlResult } from '../lib/messages';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const token = new URLSearchParams(location.search).get('t') ?? '';
const download = $<HTMLButtonElement>('download');
const cancel = $<HTMLButtonElement>('cancel');

function send(msg: DlMessage): Promise<DlResult> {
  return chrome.runtime.sendMessage(msg);
}

function fail(error: string): void {
  $('looking').hidden = true;
  $('error').textContent = error;
  $('error').hidden = false;
  download.disabled = true;
  cancel.textContent = 'Close';
}

// Magnet links need peers to describe the torrent: say so if it takes a while.
const slow = setTimeout(() => {
  $('lookingText').textContent = 'Still looking — a magnet link needs other peers to describe the torrent…';
}, 8000);

async function inspect(): Promise<void> {
  const r = await send({ type: 'TORRENT_INSPECT', token });
  clearTimeout(slow);
  if (!r.ok) return fail(r.error);
  $('looking').hidden = true;
  $('name').textContent = r.info.name;
  $('size').textContent = formatBytes(r.info.size);
  $('files').textContent = String(r.info.files);
  $('folder').textContent = r.info.folder;
  $('details').hidden = false;
  download.disabled = false;
  download.focus();
}

download.addEventListener('click', async () => {
  download.disabled = true;
  const r = await send({ type: 'TORRENT_CONFIRM', token });
  if (!r.ok) return fail(r.error);
  $('done').hidden = false;
  cancel.hidden = true;
  setTimeout(() => window.close(), 1200);
});

cancel.addEventListener('click', () => {
  void send({ type: 'TORRENT_CANCEL', token }).finally(() => window.close());
});

void inspect();
