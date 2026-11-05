import type { BridgeKind, Circuit, Stage } from './protocol';

/**
 * off: Tortuga does nothing. connecting / failed: traffic that would go
 * through Tor is blocked. on: traffic goes through the helper's SOCKS port.
 */
export type Phase = 'off' | 'connecting' | 'on' | 'failed';

export interface TorState {
  phase: Phase;
  bridge: BridgeKind;
  percent: number;
  /** Last bootstrap stage while connecting; drives the connecting diagram. */
  stage: Stage | null;
  /** Arti's reason when it thinks bootstrap is stuck. */
  blocked: string | null;
  socksPort: number | null;
  error: string | null;
  /** The helper isn't installed (or not registered for this browser). */
  helperMissing: boolean;
  /** The helper's version, from its hello reply. */
  helperVersion: string | null;
  /** Last circuit per site. */
  circuits: Record<string, Circuit>;
}

export type TorEvent =
  | { type: 'turnOn'; bridge: BridgeKind }
  | { type: 'turnOff' }
  | { type: 'choose'; bridge: BridgeKind }
  | { type: 'hello'; version: string }
  | { type: 'status'; stage: Stage; percent: number; blocked: string | null }
  | { type: 'ready'; socksPort: number }
  | { type: 'circuit'; circuit: Circuit }
  | { type: 'failed'; error: string; helperMissing?: boolean };

export function initialState(bridge: BridgeKind = 'none'): TorState {
  return { phase: 'off', bridge, percent: 0, stage: null, blocked: null, socksPort: null, error: null, helperMissing: false, helperVersion: null, circuits: {} };
}

export function reduce(s: TorState, e: TorEvent): TorState {
  switch (e.type) {
    case 'turnOn':
      return { ...initialState(e.bridge), phase: 'connecting', helperVersion: s.helperVersion };
    case 'turnOff':
      return { ...initialState(s.bridge), helperVersion: s.helperVersion };
    case 'choose':
      return s.phase === 'off' ? { ...s, bridge: e.bridge } : s;
    case 'hello':
      return { ...s, helperVersion: e.version };
    case 'status':
      return s.phase === 'connecting' ? { ...s, stage: e.stage, percent: e.percent, blocked: e.blocked } : s;
    case 'ready':
      return s.phase === 'connecting' ? { ...s, phase: 'on', percent: 100, stage: 'ready', blocked: null, socksPort: e.socksPort } : s;
    case 'circuit':
      return s.phase === 'on' ? { ...s, circuits: { ...s.circuits, [e.circuit.site]: e.circuit } } : s;
    case 'failed':
      return {
        ...s,
        phase: s.phase === 'off' ? 'off' : 'failed',
        socksPort: null,
        error: e.error,
        helperMissing: e.helperMissing ?? false,
      };
  }
}

/**
 * Nothing listens on TCP port 1 on desktop systems, so a proxy pointing there
 * makes every request fail at once: the way to block traffic while Tor isn't
 * ready, without letting it out directly.
 */
export const BLACKHOLE_PORT = 1;

/** Where traffic goes: null = the browser's own setting (Tortuga off). */
export function routedPort(s: TorState): number | null {
  if (s.phase === 'off') return null;
  if (s.phase === 'on' && s.socksPort !== null) return s.socksPort;
  return BLACKHOLE_PORT;
}
