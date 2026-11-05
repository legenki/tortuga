/** Replaced at build time with the browser the build is for (see vite.target.ts). */
declare const __TARGET__: 'chrome' | 'firefox';

// Firefox-only parts of the proxy API, which @types/chrome doesn't describe.
declare namespace chrome.proxy {
  interface FirefoxProxyInfo {
    type: 'direct' | 'http' | 'https' | 'socks' | 'socks4';
    host?: string;
    port?: number;
    /** SOCKS only. */
    username?: string;
    password?: string;
    /** SOCKS only: resolve host names through the proxy. */
    proxyDNS?: boolean;
  }

  interface FirefoxRequestDetails {
    requestId: string;
    url: string;
    tabId: number;
    type: string;
    documentUrl?: string;
    /** Ancestor frames, nearest first; the last one is the top-level page. */
    frameAncestors?: { url: string; frameId: number }[];
  }

  /**
   * undefined: the browser's own setting. A list: proxies to try in order,
   * where a trailing null means "no failover" (fail closed).
   */
  type FirefoxProxyAnswer = FirefoxProxyInfo | (FirefoxProxyInfo | null)[] | null | undefined;

  const onRequest: {
    addListener(
      listener: (details: FirefoxRequestDetails) => FirefoxProxyAnswer | Promise<FirefoxProxyAnswer>,
      filter: { urls: string[] },
    ): void;
  };
}

// Firefox-only privacy settings.
declare namespace chrome.privacy {
  interface Websites {
    resistFingerprinting: chrome.types.ChromeSetting;
  }
  interface Network {
    peerConnectionEnabled: chrome.types.ChromeSetting;
  }
}
