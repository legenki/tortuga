// Browser settings that go with Tor mode, set while it's on and released when
// it's off. A setting another extension or a policy controls is left alone.
import { INCOGNITO_SCOPE } from './routing';

type Setting = chrome.types.ChromeSetting<unknown>;

/** Firefox-only settings, which @types/chrome doesn't describe. */
interface FirefoxPrivacy {
  websites: { resistFingerprinting?: Setting };
  network: { peerConnectionEnabled?: Setting };
}
type Scope = 'regular' | typeof INCOGNITO_SCOPE;

async function set(setting: Setting | undefined, value: unknown, scope?: Scope): Promise<void> {
  try {
    await setting?.set(scope ? { value, scope } : { value });
  } catch (e) {
    console.warn('Tortuga: setting not applied', e);
  }
}

async function clear(setting: Setting | undefined, scope?: Scope): Promise<void> {
  try {
    await setting?.clear(scope ? { scope } : {});
  } catch (e) {
    console.warn('Tortuga: setting not released', e);
  }
}

export async function applyPrivacy(on: boolean): Promise<void> {
  if (__TARGET__ === 'firefox') {
    const privacy = chrome.privacy as unknown as FirefoxPrivacy;
    const fingerprint = privacy.websites.resistFingerprinting;
    const webrtc = privacy.network.peerConnectionEnabled;
    if (on) {
      await set(fingerprint, true);
      await set(webrtc, false);
    } else {
      await clear(fingerprint);
      await clear(webrtc);
    }
  } else {
    // Only the incognito session goes through Tor, so only it gets the WebRTC rule.
    const webrtc = chrome.privacy.network.webRTCIPHandlingPolicy as Setting;
    if (on) await set(webrtc, 'disable_non_proxied_udp', INCOGNITO_SCOPE);
    else await clear(webrtc, INCOGNITO_SCOPE);
  }
}
