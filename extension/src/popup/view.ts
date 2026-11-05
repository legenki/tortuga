import type { Circuit } from '../lib/protocol';
import type { TorState } from '../lib/state';

/** What the popup shows for a state: pure, so it can be tested. */
export interface View {
  /** Tor side of the switch is selected. */
  torSelected: boolean;
  /** data-state on the status line: colours the dot. */
  tone: 'off' | 'busy' | 'on' | 'alert';
  status: string;
  /** A longer explanation under the status, or null. */
  note: string | null;
  showRestart: boolean;
  canNewCircuit: boolean;
  /** One line per hop of the active tab's circuit. */
  hops: string[];
}

const BRIDGE_NAMES = { none: 'no bridge', snowflake: 'Snowflake', obfs4: 'obfs4', webtunnel: 'WebTunnel' } as const;

function hopLine(h: Circuit['hops'][number]): string {
  const role = { guard: 'Guard', bridge: 'Bridge', middle: 'Middle', exit: 'Exit' }[h.role];
  return `${role} · ${h.country ?? '—'} · ${h.id.slice(0, 8)}`;
}

export function viewFor(s: TorState, site: string): View {
  const base: View = { torSelected: s.phase !== 'off', tone: 'off', status: '', note: null, showRestart: false, canNewCircuit: false, hops: [] };
  switch (s.phase) {
    case 'off':
      return { ...base, status: 'Direct — Tortuga is off', note: s.error };
    case 'connecting':
      return {
        ...base,
        tone: 'busy',
        status: `Connecting via ${BRIDGE_NAMES[s.bridge]}… ${s.percent}%`,
        note: s.blocked ?? 'Traffic waits until Tor is ready.',
      };
    case 'on': {
      const circuit = s.circuits[site];
      return {
        ...base,
        tone: 'on',
        status: `Tor on via ${BRIDGE_NAMES[s.bridge]}`,
        note: __TARGET__ === 'chrome' ? 'Only incognito windows use Tor in Chrome, all through one circuit.' : null,
        canNewCircuit: true,
        hops: circuit ? circuit.hops.map(hopLine) : [],
      };
    }
    case 'failed':
      return {
        ...base,
        tone: 'alert',
        status: s.helperMissing ? 'Helper not installed' : 'Tor stopped — traffic is blocked',
        note: s.error,
        showRestart: !s.helperMissing,
      };
  }
}
