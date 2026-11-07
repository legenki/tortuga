import type { DownloadsState } from '../lib/messages';
import {
  FEATURE_TORRENT_OPEN, FEATURE_TORRENT_VIA_TOR, PROTOCOL_VERSION,
  type FetchedLines, type HelperMessage, type TorrentInfo, type TorrentSource, type TorrentVia,
} from '../lib/protocol';
import { HELPER_MISSING, linesOf } from './controller';
import { isMissingHost, type HelperClient } from './helper';

/** Everything the downloads controller does to the outside world (fakes in tests). */
export interface DlDeps {
  connect(onEvent: (m: HelperMessage) => void, onGone: (reason: string) => void): HelperClient;
  broadcast(state: DownloadsState): void;
  /** Remember whether there are downloads, so a restarted browser resumes them. */
  saveActive(active: boolean): Promise<void>;
}

/** An older helper would ignore `via` and fetch the link from the user's own IP. */
export const UPDATE_FOR_TOR = 'Update the Tortuga helper to fetch .torrent links through Tor. Until then, turn Tor off to fetch this one directly.';

export const NO_DOWNLOADS: DownloadsState = { rows: [], folder: null, error: null, helperMissing: false };

/**
 * Torrents run in their own helper process, on a native port of their own:
 * Tor can be on or off without touching downloads. The port is opened on the
 * first request and kept while the browser runs.
 */
export class Downloads {
  private state: DownloadsState = NO_DOWNLOADS;
  private ready: Promise<HelperClient> | null = null;
  /** What the connected helper said it understands, beyond protocol 1. */
  private features: string[] = [];
  private active = false;

  constructor(private readonly deps: DlDeps) {}

  get current(): DownloadsState {
    return this.state;
  }

  /**
   * On startup, when there were downloads: connect and have the helper open
   * its torrent list, which it otherwise does only on the first torrent request.
   */
  async resume(): Promise<void> {
    try {
      const helper = await this.client();
      if (this.features.includes(FEATURE_TORRENT_OPEN)) await helper.request({ type: 'torrent.open' });
    } catch (e) {
      this.update({ error: (e as Error).message });
    }
  }

  /** `via`: fetch the `.torrent` link through Tor, never directly. */
  async inspect(source: TorrentSource, via?: TorrentVia): Promise<TorrentInfo> {
    return this.info(await this.request({ type: 'torrent.inspect', payload: { source, ...(await this.viaPart(via)) } }));
  }

  async add(source: TorrentSource, via?: TorrentVia): Promise<TorrentInfo> {
    const info = this.info(await this.request({ type: 'torrent.add', payload: { source, ...(await this.viaPart(via)) } }));
    await this.setActive(true);
    return info;
  }

  async pause(id: string): Promise<void> {
    await this.request({ type: 'torrent.pause', payload: { id } });
  }

  async resumeOne(id: string): Promise<void> {
    await this.request({ type: 'torrent.resume', payload: { id } });
  }

  async remove(id: string, deleteFiles: boolean): Promise<void> {
    await this.request({ type: 'torrent.remove', payload: { id, deleteFiles } });
  }

  /** Bridge lines from Moat, directly (this helper never runs Tor). */
  async fetchBridges(kind: 'obfs4' | 'webtunnel'): Promise<FetchedLines> {
    return linesOf(await this.request({ type: 'bridges.fetch', payload: { kind } }));
  }

  /** `{ via }` for a request, refused when the helper wouldn't honour it. */
  private async viaPart(via: TorrentVia | undefined): Promise<{ via?: TorrentVia }> {
    if (!via) return {};
    await this.client();
    if (!this.features.includes(FEATURE_TORRENT_VIA_TOR)) throw new Error(UPDATE_FOR_TOR);
    return { via };
  }

  private info(m: HelperMessage): TorrentInfo {
    if (m.type !== 'torrent.info') throw new Error(`unexpected reply ${m.type}`);
    this.update({ folder: m.payload.folder });
    return m.payload;
  }

  private async request(req: Parameters<HelperClient['request']>[0]): Promise<HelperMessage> {
    const helper = await this.client();
    return helper.request(req);
  }

  private client(): Promise<HelperClient> {
    if (!this.ready) {
      const ready = (async () => {
        const helper = this.deps.connect(m => this.onEvent(m), reason => this.onGone(reason));
        const hello = await helper.request({ type: 'hello', payload: { protocol: PROTOCOL_VERSION } });
        this.features = hello.type === 'hello' ? hello.payload.features ?? [] : [];
        this.update({ error: null, helperMissing: false });
        return helper;
      })();
      this.ready = ready;
      ready.catch(() => {
        if (this.ready === ready) this.ready = null;
      });
    }
    return this.ready;
  }

  private onEvent(m: HelperMessage): void {
    if (m.type !== 'torrent.progress') return;
    this.update({ rows: m.payload.torrents });
    void this.setActive(m.payload.torrents.length > 0);
  }

  private onGone(reason: string): void {
    this.ready = null;
    const missing = isMissingHost(reason);
    // The rows are stale once the helper is gone; they come back when it does.
    this.update({ rows: [], error: missing ? HELPER_MISSING : reason, helperMissing: missing });
  }

  private async setActive(active: boolean): Promise<void> {
    if (active === this.active) return;
    this.active = active;
    await this.deps.saveActive(active);
  }

  private update(change: Partial<DownloadsState>): void {
    this.state = { ...this.state, ...change };
    this.deps.broadcast(this.state);
  }
}
