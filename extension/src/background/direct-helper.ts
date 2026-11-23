import { PROTOCOL_VERSION, type FetchedLines, type HelperMessage } from '../lib/protocol';
import { linesOf } from './controller';
import type { HelperClient } from './helper';

/** What DirectHelper needs from the outside world (a fake port in tests). */
export interface DirectDeps {
  connect(onEvent: (m: HelperMessage) => void, onGone: (reason: string) => void): HelperClient;
}

/**
 * A helper on a native port of its own that never runs Tor: while Tor is off,
 * it asks Moat for bridge lines directly. Opened on first use and kept while
 * the browser runs; a new one is opened if it goes away.
 */
export class DirectHelper {
  private ready: Promise<HelperClient> | null = null;

  constructor(private readonly deps: DirectDeps) {}

  async fetchBridges(kind: 'obfs4' | 'webtunnel'): Promise<FetchedLines> {
    const helper = await this.client();
    return linesOf(await helper.request({ type: 'bridges.fetch', payload: { kind } }));
  }

  private client(): Promise<HelperClient> {
    if (!this.ready) {
      const ready = (async () => {
        const helper = this.deps.connect(() => undefined, () => {
          if (this.ready === ready) this.ready = null;
        });
        try {
          await helper.request({ type: 'hello', payload: { protocol: PROTOCOL_VERSION } });
        } catch (e) {
          helper.close(); // else every retry would leave another helper process running
          throw e;
        }
        return helper;
      })();
      this.ready = ready;
      ready.catch(() => {
        if (this.ready === ready) this.ready = null;
      });
    }
    return this.ready;
  }
}
