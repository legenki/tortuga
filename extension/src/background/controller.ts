import type { BridgeKind, FetchedLines, HelperMessage } from '../lib/protocol';
import { PROTOCOL_VERSION } from '../lib/protocol';
import type { Stored } from '../lib/messages';
import { initialState, reduce, routedPort, type TorEvent, type TorState } from '../lib/state';
import { HelperError, isMissingHost, type HelperClient } from './helper';

/** Everything the controller does to the outside world (fakes in tests). */
export interface Deps {
  connect(onEvent: (m: HelperMessage) => void, onGone: (reason: string) => void): HelperClient;
  applyRoute(port: number | null): Promise<void>;
  applyPrivacy(on: boolean): Promise<void>;
  save(stored: Stored): Promise<void>;
  broadcast(state: TorState): void;
  /** Chrome: may Tortuga touch incognito windows? Firefox: always true. */
  incognitoAllowed(): Promise<boolean>;
}

/** The lines in a `bridges.lines` reply. */
export function linesOf(m: HelperMessage): FetchedLines {
  if (m.type !== 'bridges.lines') throw new Error(`unexpected reply ${m.type}`);
  return m.payload;
}

export const INCOGNITO_NEEDED = 'Allow Tortuga in Incognito (Manage extension → Allow in Incognito), then try again.';
export const HELPER_MISSING = 'The Tortuga helper is not installed.';

/**
 * Owns the Tor state. Every change goes through `commit`, which applies the
 * route and privacy settings only when they change. Changes are serialized.
 */
export class Controller {
  private state: TorState = initialState();
  private helper: HelperClient | null = null;
  private appliedPort: number | null = null;
  private privacyOn = false;
  private queue: Promise<unknown> = Promise.resolve();
  /** Bumped on every turn on / off, so a stale start can't overwrite a newer one. */
  private generation = 0;

  constructor(private readonly deps: Deps) {}

  get current(): TorState {
    return this.state;
  }

  /** The SOCKS port traffic goes to right now (null: browser's own setting). */
  get port(): number | null {
    return routedPort(this.state);
  }

  /** `lines`: bridge lines for obfs4 / WebTunnel (Snowflake uses the bundled defaults). */
  turnOn(bridge: BridgeKind, lines: string[] = []): Promise<TorState> {
    return this.serial(async () => {
      const gen = ++this.generation;
      this.helper?.close();
      this.helper = null;
      await this.commit({ type: 'turnOn', bridge });
      await this.deps.save({ enabled: true, bridge });
      if (!(await this.deps.incognitoAllowed())) {
        await this.commit({ type: 'failed', error: INCOGNITO_NEEDED });
        return this.state;
      }
      const helper = this.deps.connect(
        m => void this.serial(() => this.onEvent(m)),
        reason => void this.serial(() => this.onGone(helper, reason)),
      );
      this.helper = helper;
      void this.start(helper, bridge, lines, gen);
      return this.state;
    });
  }

  turnOff(): Promise<TorState> {
    return this.serial(async () => {
      this.generation++;
      this.helper?.close();
      this.helper = null;
      await this.commit({ type: 'turnOff' });
      await this.deps.save({ enabled: false, bridge: this.state.bridge });
      return this.state;
    });
  }

  /** Pick a bridge: remembered while off, applied by restarting Tor while on. */
  chooseBridge(bridge: BridgeKind, lines: string[] = []): Promise<TorState> {
    if (this.state.phase !== 'off') return this.turnOn(bridge, lines);
    return this.serial(async () => {
      await this.commit({ type: 'choose', bridge });
      await this.deps.save({ enabled: false, bridge });
      return this.state;
    });
  }

  /**
   * Bridge lines from Moat through the Tor helper, which can retry through Tor
   * when the direct way is blocked. Null when Tor is off (no helper to ask).
   */
  fetchBridges(kind: 'obfs4' | 'webtunnel'): Promise<FetchedLines> | null {
    if (this.state.phase !== 'on' || !this.helper) return null;
    return this.helper.request({ type: 'bridges.fetch', payload: { kind } }).then(linesOf);
  }

  newCircuit(site: string): Promise<TorState> {
    return this.serial(async () => {
      if (this.state.phase === 'on' && this.helper) {
        await this.helper.request({ type: 'tor.newCircuit', payload: { site } }).catch(() => undefined);
      }
      return this.state;
    });
  }

  private async start(helper: HelperClient, bridge: BridgeKind, lines: string[], gen: number): Promise<void> {
    try {
      const hello = await helper.request({ type: 'hello', payload: { protocol: PROTOCOL_VERSION } });
      if (hello.type === 'hello') {
        await this.serial(async () => {
          if (gen === this.generation) await this.commit({ type: 'hello', version: hello.payload.version });
        });
      }
      const kind = { kind: bridge, ...(lines.length ? { lines } : {}) };
      const reply = await helper.request({ type: 'tor.start', payload: { bridge: kind } });
      if (reply.type !== 'tor.ready') throw new Error(`unexpected reply ${reply.type}`);
      await this.serial(async () => {
        if (gen === this.generation) await this.commit({ type: 'ready', socksPort: reply.payload.socksPort });
      });
    } catch (e) {
      await this.serial(async () => {
        if (gen !== this.generation) return;
        const err = e as Error;
        const missing = isMissingHost(err.message);
        const message = missing
          ? HELPER_MISSING
          : err instanceof HelperError && err.code === 'protocol_mismatch'
            ? `Update the Tortuga helper: ${err.message}`
            : err.message;
        await this.commit({ type: 'failed', error: message, helperMissing: missing });
      });
    }
  }

  private async onEvent(m: HelperMessage): Promise<void> {
    if (m.type === 'tor.status') {
      await this.commit({ type: 'status', stage: m.payload.phase, percent: m.payload.percent, blocked: m.payload.blocked });
    }
    else if (m.type === 'circuit') await this.commit({ type: 'circuit', circuit: m.payload });
  }

  private async onGone(helper: HelperClient, reason: string): Promise<void> {
    if (helper !== this.helper) return;
    this.helper = null;
    const missing = isMissingHost(reason);
    await this.commit({ type: 'failed', error: missing ? HELPER_MISSING : reason, helperMissing: missing });
  }

  private async commit(e: TorEvent): Promise<void> {
    this.state = reduce(this.state, e);
    const port = routedPort(this.state);
    if (port !== this.appliedPort) {
      await this.deps.applyRoute(port);
      this.appliedPort = port;
    }
    const privacy = this.state.phase !== 'off';
    if (privacy !== this.privacyOn) {
      await this.deps.applyPrivacy(privacy);
      this.privacyOn = privacy;
    }
    this.deps.broadcast(this.state);
  }

  private serial<T>(fn: () => Promise<T>): Promise<T> {
    const next = this.queue.then(fn, fn);
    this.queue = next.catch(() => undefined);
    return next;
  }
}
