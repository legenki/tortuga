import { linesFor } from '../lib/bridges';
import { isTorrentLink } from '../lib/downloads';
import {
  DOWNLOADS_KEY, LINES_KEY, NO_LINES, STORAGE_KEY,
  type BgBroadcast, type BgMessage, type BridgeLines, type BridgesMessage, type BridgesResult, type DlMessage, type DlResult, type Stored,
} from '../lib/messages';
import type { BridgeKind, TorrentInfo, TorrentSource } from '../lib/protocol';
import { senderAllowed } from '../lib/senders';
import { DEFAULT_SITE, siteOf } from '../lib/site';
import type { TorState } from '../lib/state';
import { TOR_NOT_READY, torrentRoute, type PendingTorrent } from '../lib/torrent-route';
import { Controller } from './controller';
import { Downloads } from './downloads';
import { connectHelper } from './helper';
import { applyPrivacy } from './privacy';
import { applyChromeRoute, firefoxAnswer } from './routing';

const controller = new Controller({
  connect: connectHelper,
  // Firefox asks proxy.onRequest about each request (below); Chrome has one setting.
  applyRoute: port => (__TARGET__ === 'firefox' ? Promise.resolve() : applyChromeRoute(port)),
  applyPrivacy,
  save: stored => chrome.storage.local.set({ [STORAGE_KEY]: stored }),
  broadcast: (state: TorState) => broadcast({ type: 'STATE', state }),
  incognitoAllowed: () => (__TARGET__ === 'firefox' ? Promise.resolve(true) : chrome.extension.isAllowedIncognitoAccess()),
});

function broadcast(msg: BgBroadcast): void {
  chrome.runtime.sendMessage(msg).catch(() => { /* no popup open */ });
}

const downloads = new Downloads({
  connect: connectHelper,
  broadcast: state => broadcast({ type: 'DOWNLOADS', state }),
  saveActive: active => chrome.storage.local.set({ [DOWNLOADS_KEY]: active }),
});

// Downloads stop with the browser; if there were some, pick them up again.
void chrome.storage.local.get(DOWNLOADS_KEY).then(r => {
  if (r[DOWNLOADS_KEY]) void downloads.resume();
});

/** Torrents waiting in a confirm window, by the window's token. */
const pending = new Map<string, PendingTorrent>();

/**
 * Put a torrent up for confirmation in a small window of its own. `tab`: where
 * the link was clicked (none when pasted in the popup). Nothing is fetched yet.
 */
async function openConfirm(source: TorrentSource, tab?: chrome.tabs.Tab): Promise<void> {
  const token = crypto.randomUUID();
  // Firefox gives each site its own circuits; Chrome has one for all.
  const site = __TARGET__ === 'firefox' ? siteOf(tab?.url) : DEFAULT_SITE;
  pending.set(token, { source, site, incognito: tab ? tab.incognito : null, direct: false });
  const win = await chrome.windows.create({ url: chrome.runtime.getURL(`confirm.html?t=${token}`), type: 'popup', width: 440, height: 420 });
  if (win?.id !== undefined) confirmWindows.set(win.id, token);
}

/** Confirm windows by id, so closing one forgets its torrent. */
const confirmWindows = new Map<number, string>();
chrome.windows.onRemoved.addListener(id => {
  const token = confirmWindows.get(id);
  if (token === undefined) return;
  confirmWindows.delete(id);
  pending.delete(token);
});

async function result(run: () => Promise<TorrentInfo>): Promise<DlResult> {
  try {
    return { ok: true, info: await run() };
  } catch (e) {
    return { ok: false, error: (e as Error).message };
  }
}

function pendingOf(token: string): PendingTorrent {
  const p = pending.get(token);
  if (!p) throw new Error('This link has expired. Click it again.');
  return p;
}

/**
 * Inspect or add a pending torrent the way Tor allows: while Tor covers the
 * link, a `.torrent` link is fetched only through Tor, and a magnet is looked
 * up (from the user's own IP, it can't be otherwise) only once they agree.
 */
async function runPending(token: string, run: typeof downloads.inspect, direct = false): Promise<DlResult> {
  let p: PendingTorrent;
  try {
    p = pendingOf(token);
  } catch (e) {
    return { ok: false, error: (e as Error).message };
  }
  if (direct) p.direct = true;
  const route = torrentRoute(p, controller.current, __TARGET__);
  switch (route.kind) {
    case 'ask':
      return { ok: false, askDirect: true, error: 'Looking up a magnet link reveals your IP.' };
    case 'wait':
      return { ok: false, error: TOR_NOT_READY };
    case 'tor':
      return result(() => run.call(downloads, p.source, route.via));
    case 'direct':
      return result(() => run.call(downloads, p.source));
  }
}

const MENU_ID = 'tortuga-download';
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: MENU_ID, title: 'Download with Tortuga', contexts: ['link'] });
});
chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === MENU_ID && info.linkUrl) void openConfirm({ url: info.linkUrl }, tab);
});

/** Bridge lines saved on the settings page for `kind`. */
async function savedLines(kind: BridgeKind): Promise<string[]> {
  const r = await chrome.storage.local.get(LINES_KEY);
  return linesFor(kind, (r[LINES_KEY] as BridgeLines | undefined) ?? NO_LINES);
}

// Back to how it was when the background last stopped. If Tortuga was on, it
// starts again; until Tor is ready, routedPort() blocks traffic instead of
// letting it out directly.
const restored = chrome.storage.local.get(STORAGE_KEY).then(async r => {
  const stored = r[STORAGE_KEY] as Stored | undefined;
  if (stored?.enabled) await controller.turnOn(stored.bridge, await savedLines(stored.bridge));
  else if (stored) await controller.chooseBridge(stored.bridge);
});

if (__TARGET__ === 'firefox') {
  // A persistent listener: Firefox wakes the background for it. Requests wait
  // for the stored state, so none slips out before Tortuga knows it is on.
  chrome.proxy.onRequest.addListener(async details => {
    await restored;
    return firefoxAnswer(controller.port, details);
  }, { urls: ['<all_urls>'] });
}

/** Bridge lines from Moat: through the Tor helper while Tor is on (it can retry through Tor), else directly. */
async function fetchBridges(kind: 'obfs4' | 'webtunnel'): Promise<BridgesResult> {
  try {
    const fetched = await (controller.fetchBridges(kind) ?? downloads.fetchBridges(kind));
    return { ok: true, ...fetched };
  } catch (e) {
    return { ok: false, error: (e as Error).message };
  }
}

chrome.runtime.onMessage.addListener((msg: BgMessage | DlMessage | BridgesMessage, sender, sendResponse) => {
  if (!senderAllowed(msg.type, sender, chrome.runtime.id, chrome.runtime.getURL(''))) {
    sendResponse({ ok: false, error: 'Not allowed from this page' });
    return false;
  }
  const reply = (p: Promise<TorState>) => {
    p.then(sendResponse, () => sendResponse(controller.current));
    return true;
  };
  const answer = (p: Promise<unknown>) => {
    p.then(sendResponse, e => sendResponse({ ok: false, error: (e as Error).message }));
    return true;
  };
  switch (msg.type) {
    case 'GET_STATE':
      return reply(restored.then(() => controller.current));
    case 'TOR_ON':
      return reply(savedLines(msg.bridge).then(lines => controller.turnOn(msg.bridge, lines)));
    case 'TOR_OFF':
      return reply(controller.turnOff());
    case 'SET_BRIDGE':
      return reply(savedLines(msg.bridge).then(lines => controller.chooseBridge(msg.bridge, lines)));
    case 'NEW_CIRCUIT':
      return reply(controller.newCircuit(msg.site));
    case 'GET_DOWNLOADS':
      return answer(Promise.resolve(downloads.current));
    case 'TORRENT_OPEN':
      // Pages only ever ask for links that look like torrents; refuse anything else.
      if ('url' in msg.source && !isTorrentLink(msg.source.url)) return answer(Promise.resolve({ ok: false, error: 'Not a magnet or .torrent link' }));
      return answer(openConfirm(msg.source, sender.tab).then(() => ({ ok: true })));
    case 'TORRENT_INSPECT':
      return answer(runPending(msg.token, downloads.inspect, msg.direct));
    case 'TORRENT_CONFIRM':
      return answer(runPending(msg.token, downloads.add).then(r => {
        if (r.ok) pending.delete(msg.token);
        return r;
      }));
    case 'TORRENT_CANCEL':
      pending.delete(msg.token);
      return answer(Promise.resolve({ ok: true }));
    case 'TORRENT_PAUSE':
      return answer(downloads.pause(msg.id).then(() => downloads.current));
    case 'TORRENT_RESUME':
      return answer(downloads.resumeOne(msg.id).then(() => downloads.current));
    case 'TORRENT_REMOVE':
      return answer(downloads.remove(msg.id, msg.deleteFiles).then(() => downloads.current));
    case 'FETCH_BRIDGES':
      return answer(fetchBridges(msg.kind));
  }
  return false;
});
