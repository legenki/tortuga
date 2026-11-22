import { linesFor, linesToApply } from '../lib/bridges';
import { LINES_KEY, NO_LINES, STORAGE_KEY, type BgBroadcast, type BgMessage, type BridgeLines, type BridgesMessage, type BridgesResult, type Stored } from '../lib/messages';
import type { BridgeKind } from '../lib/protocol';
import { senderAllowed } from '../lib/senders';
import type { TorState } from '../lib/state';
import { Controller } from './controller';
import { DirectHelper } from './direct-helper';
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

/** Moat while Tor is off, on a helper of its own. */
const direct = new DirectHelper({ connect: connectHelper });

// Lines saved on the settings page for the bridge Tor runs on (or tried to)
// take effect at once, as choosing the bridge again would.
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !(LINES_KEY in changes)) return;
  const { oldValue, newValue } = changes[LINES_KEY];
  const lines = linesToApply(controller.current, (oldValue as BridgeLines | undefined) ?? NO_LINES, (newValue as BridgeLines | undefined) ?? NO_LINES);
  if (lines) void controller.turnOn(controller.current.bridge, lines);
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
    const fetched = await (controller.fetchBridges(kind) ?? direct.fetchBridges(kind));
    return { ok: true, ...fetched };
  } catch (e) {
    return { ok: false, error: (e as Error).message };
  }
}

chrome.runtime.onMessage.addListener((msg: BgMessage | BridgesMessage, sender, sendResponse) => {
  if (!senderAllowed(sender, chrome.runtime.id, chrome.runtime.getURL(''))) {
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
    case 'FETCH_BRIDGES':
      return answer(fetchBridges(msg.kind));
  }
  return false;
});
