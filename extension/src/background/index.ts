import { STORAGE_KEY, type BgBroadcast, type BgMessage, type Stored } from '../lib/messages';
import type { TorState } from '../lib/state';
import { Controller } from './controller';
import { connectHelper } from './helper';
import { applyPrivacy } from './privacy';
import { applyChromeRoute, firefoxAnswer } from './routing';

const controller = new Controller({
  connect: connectHelper,
  // Firefox asks proxy.onRequest about each request (below); Chrome has one setting.
  applyRoute: port => (__TARGET__ === 'firefox' ? Promise.resolve() : applyChromeRoute(port)),
  applyPrivacy,
  save: stored => chrome.storage.local.set({ [STORAGE_KEY]: stored }),
  broadcast: (state: TorState) => {
    const msg: BgBroadcast = { type: 'STATE', state };
    chrome.runtime.sendMessage(msg).catch(() => { /* no popup open */ });
  },
  incognitoAllowed: () => (__TARGET__ === 'firefox' ? Promise.resolve(true) : chrome.extension.isAllowedIncognitoAccess()),
});

// If Tortuga was on when the background last stopped, start again. Until Tor
// is ready, routedPort() blocks traffic instead of letting it out directly.
const restored = chrome.storage.local.get(STORAGE_KEY).then(async r => {
  const stored = r[STORAGE_KEY] as Stored | undefined;
  if (stored?.enabled) await controller.turnOn(stored.bridge);
});

if (__TARGET__ === 'firefox') {
  // A persistent listener: Firefox wakes the background for it. Requests wait
  // for the stored state, so none slips out before Tortuga knows it is on.
  chrome.proxy.onRequest.addListener(async details => {
    await restored;
    return firefoxAnswer(controller.port, details);
  }, { urls: ['<all_urls>'] });
}

chrome.runtime.onMessage.addListener((msg: BgMessage, _sender, sendResponse) => {
  const reply = (p: Promise<TorState>) => {
    p.then(sendResponse, () => sendResponse(controller.current));
    return true;
  };
  switch (msg.type) {
    case 'GET_STATE':
      return reply(restored.then(() => controller.current));
    case 'TOR_ON':
      return reply(controller.turnOn(msg.bridge));
    case 'TOR_OFF':
      return reply(controller.turnOff());
    case 'NEW_CIRCUIT':
      return reply(controller.newCircuit(msg.site));
  }
  return false;
});
