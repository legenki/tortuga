import type { HelperMessage } from '../src/lib/protocol';
import type { PortLike } from '../src/background/helper';

/** An in-memory native port: records what the extension sends, lets tests answer. */
export class FakePort implements PortLike {
  sent: Record<string, unknown>[] = [];
  disconnected = false;
  private messageFns: ((m: HelperMessage) => void)[] = [];
  private disconnectFns: (() => void)[] = [];

  onMessage = { addListener: (fn: (m: HelperMessage) => void) => void this.messageFns.push(fn) };
  onDisconnect = { addListener: (fn: () => void) => void this.disconnectFns.push(fn) };

  postMessage(message: unknown): void {
    this.sent.push(message as Record<string, unknown>);
  }

  disconnect(): void {
    this.disconnected = true;
  }

  /** The helper sends `m`. */
  emit(m: HelperMessage): void {
    for (const fn of this.messageFns) fn(m);
  }

  /** The helper process goes away. */
  die(): void {
    for (const fn of this.disconnectFns) fn();
  }

  /** The id of the last request of `type`. */
  idOf(type: string): number {
    const req = [...this.sent].reverse().find(m => m.type === type);
    if (!req) throw new Error(`no ${type} sent`);
    return req.id as number;
  }
}

/** Let pending promise callbacks run. */
export const flush = () => new Promise(r => setTimeout(r, 0));
