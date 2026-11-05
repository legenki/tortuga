import { linesFor } from '../lib/bridges';
import { isTorrentLink } from '../lib/downloads';
import {
  DOWNLOADS_KEY, LINES_KEY, NO_LINES, STORAGE_KEY,
  type BgBroadcast, type BgMessage, type BridgeLines, type BridgesMessage, type BridgesResult, type DlMessage, type DlResult, type Stored,
} from '../lib/messages';
import type { BridgeKind, TorrentInfo, TorrentSource } from '../lib/protocol';
import type { TorState } from '../lib/state';
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
const pending = new Map<string, TorrentSource>();

/** Put a torrent up for confirmation in a small window of its own. */
async function openConfirm(source: TorrentSource): Promise<void> {
  const token = crypto.randomUUID();
  pending.set(token, source);
  await chrome.windows.create({ url: chrome.runtime.getURL(`confirm.html?t=${token}`), type: 'popup', width: 440, height: 420 });
}

async function result(run: () => Promise<TorrentInfo>): Promise<DlResult> {
  try {
    return { ok: true, info: await run() };
  } catch (e) {
    return { ok: false, error: (e as Error).message };
  }
}

function sourceOf(token: string): TorrentSource {
  const source = pending.get(token);
  if (!source) throw new Error('This link has expired. Click it again.');
  return source;
}

const MENU_ID = 'tortuga-download';
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: MENU_ID, title: 'Download with Tortuga', contexts: ['link'] });
});
chrome.contextMenus.onClicked.addListener(info => {
  if (info.menuItemId === MENU_ID && info.linkUrl) void openConfirm({ url: info.linkUrl });
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

chrome.runtime.onMessage.addListener((msg: BgMessage | DlMessage | BridgesMessage, _sender, sendResponse) => {
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
      return answer(openConfirm(msg.source).then(() => ({ ok: true })));
    case 'TORRENT_INSPECT':
      return answer(result(() => downloads.inspect(sourceOf(msg.token))));
    case 'TORRENT_CONFIRM':
      return answer(result(async () => {
        const info = await downloads.add(sourceOf(msg.token));
        pending.delete(msg.token);
        return info;
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
