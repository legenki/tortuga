import type { TorState } from '../lib/state';
import type { MetroInput } from './metro';

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
  /** The metro diagram, or null when there is no route to draw. */
  metro: MetroInput | null;
  /** "Exit relay 185.220.101.3 · DE" for the active tab's circuit. */
  exit: string | null;
}

export const BRIDGE_NAMES = { none: 'no bridge', snowflake: 'Snowflake', obfs4: 'obfs4', webtunnel: 'WebTunnel' } as const;

export function viewFor(s: TorState, site: string): View {
  const base: View = { torSelected: s.phase !== 'off', tone: 'off', status: '', note: null, showRestart: false, canNewCircuit: false, metro: null, exit: null };
  switch (s.phase) {
    case 'off':
      return { ...base, status: 'Direct — Tortuga is off', note: s.error };
    case 'connecting':
      return {
        ...base,
        tone: 'busy',
        status: `Connecting via ${BRIDGE_NAMES[s.bridge]}… ${s.percent}%`,
        note: s.blocked ?? 'Traffic waits until Tor is ready.',
        metro: { bridge: s.bridge, site, hops: null, stage: s.stage, connecting: true },
      };
    case 'on': {
      const hops = s.circuits[site]?.hops ?? null;
      const exitHop = hops?.find(h => h.role === 'exit');
      return {
        ...base,
        tone: 'on',
        status: `Tor on via ${BRIDGE_NAMES[s.bridge]}`,
        note: __TARGET__ === 'chrome' ? 'Only incognito windows use Tor in Chrome, all through one circuit.' : null,
        canNewCircuit: true,
        metro: { bridge: s.bridge, site, hops, stage: 'ready', connecting: false },
        exit: exitHop?.addr ? `Exit relay ${exitHop.addr}${exitHop.country ? ` · ${exitHop.country}` : ''}` : null,
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
