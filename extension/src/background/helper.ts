import { HOST_NAME, type HelperMessage, type HelperRequest } from '../lib/protocol';

/** The part of chrome.runtime.Port the client uses (a fake in tests). */
export interface PortLike {
  postMessage(message: unknown): void;
  onMessage: { addListener(fn: (message: HelperMessage) => void): void };
  onDisconnect: { addListener(fn: () => void): void };
  disconnect(): void;
}

export class HelperError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
  }
}

/** Chrome: "Specified native messaging host not found." Firefox: "No such native application …". */
export function isMissingHost(reason: string): boolean {
  return /native messaging host not found|no such native application/i.test(reason);
}

type Pending = { resolve: (m: HelperMessage) => void; reject: (e: Error) => void };

/**
 * Request / reply over a native port: each request gets an id, its reply
 * resolves the promise (an `error` reply rejects it), messages without an id
 * are events.
 */
export class HelperClient {
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private closed = false;

  constructor(
    private readonly port: PortLike,
    onEvent: (m: HelperMessage) => void,
    onGone: (reason: string) => void,
    lastError: () => string | undefined = () => undefined,
  ) {
    port.onMessage.addListener(m => {
      const waiting = m.id === undefined ? undefined : this.pending.get(m.id);
      if (!waiting) return onEvent(m);
      this.pending.delete(m.id!);
      if (m.type === 'error') waiting.reject(new HelperError(m.payload.code, m.payload.message));
      else waiting.resolve(m);
    });
    port.onDisconnect.addListener(() => {
      const reason = lastError() ?? 'The helper stopped';
      this.fail(reason);
      if (!this.closed) onGone(reason);
      this.closed = true;
    });
  }

  request(req: HelperRequest): Promise<HelperMessage> {
    if (this.closed) return Promise.reject(new HelperError('closed', 'The helper is not connected'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.port.postMessage({ id, ...req });
    });
  }

  /** Disconnect on purpose: no onGone call. */
  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.fail('Disconnected');
    this.port.disconnect();
  }

  private fail(reason: string): void {
    for (const p of this.pending.values()) p.reject(new HelperError('closed', reason));
    this.pending.clear();
  }
}

export function connectHelper(onEvent: (m: HelperMessage) => void, onGone: (reason: string) => void): HelperClient {
  const port = chrome.runtime.connectNative(HOST_NAME) as unknown as PortLike & { error?: { message?: string } };
  // Chrome reports why a port closed in runtime.lastError, Firefox in port.error.
  return new HelperClient(port, onEvent, onGone, () => chrome.runtime.lastError?.message ?? port.error?.message);
}
