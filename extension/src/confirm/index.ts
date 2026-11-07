// The confirm window: opened by the background for a torrent put up with
// TORRENT_OPEN, it shows what the torrent is and starts it only on Download.
import { formatBytes } from '../lib/downloads';
import type { BgBroadcast, DlMessage, DlResult } from '../lib/messages';

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

/**
 * Look the torrent up. While Tor is on, the background refuses to look up a
 * magnet (it reveals the user's IP) until `direct` says they agreed here.
 */
async function inspect(direct = false): Promise<void> {
  $('ask').hidden = true;
  $('looking').hidden = false;
  // Magnet links need peers to describe the torrent: say so if it takes a while.
  const slow = setTimeout(() => {
    $('lookingText').textContent = 'Still looking — a magnet link needs other peers to describe the torrent…';
  }, 8000);
  const r = await send({ type: 'TORRENT_INSPECT', token, ...(direct ? { direct } : {}) });
  clearTimeout(slow);
  if (!r.ok && r.askDirect) {
    $('looking').hidden = true;
    $('ask').hidden = false;
    $('lookup').focus();
    return;
  }
  if (!r.ok && r.waitTor) return waitForTor(() => void inspect(direct));
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

/**
 * The link goes through Tor, which is still connecting: wait for it, then
 * `retry`. If Tor stops instead, say so.
 */
function waitForTor(retry: () => void): void {
  $('looking').hidden = false;
  $('lookingText').textContent = 'Waiting for Tor to connect: this link is fetched through Tor, never directly…';
  const listener = (msg: BgBroadcast) => {
    if (msg.type !== 'STATE') return;
    if (msg.state.phase === 'on') {
      chrome.runtime.onMessage.removeListener(listener);
      $('lookingText').textContent = 'Looking up the torrent…';
      retry();
    } else if (msg.state.phase === 'off' || msg.state.phase === 'failed') {
      chrome.runtime.onMessage.removeListener(listener);
      fail('Tor stopped before it connected. Turn it on, then click the link again.');
    }
  };
  chrome.runtime.onMessage.addListener(listener);
}

async function confirm(): Promise<void> {
  download.disabled = true;
  const r = await send({ type: 'TORRENT_CONFIRM', token });
  if (!r.ok && r.waitTor) return waitForTor(() => void confirm());
  if (!r.ok) return fail(r.error);
  $('done').hidden = false;
  cancel.hidden = true;
  setTimeout(() => window.close(), 1200);
}

download.addEventListener('click', () => void confirm());

$('lookup').addEventListener('click', () => void inspect(true));

cancel.addEventListener('click', () => {
  void send({ type: 'TORRENT_CANCEL', token }).finally(() => window.close());
});

void inspect();
