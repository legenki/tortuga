import type { TorState } from '../lib/state';

/** What the settings page says about the helper. */
export function helperText(s: TorState): string {
  if (s.helperMissing) return 'Not installed. Install the Tortuga helper, then turn Tor on.';
  if (s.helperVersion) return `Version ${s.helperVersion}, connected.`;
  return 'Starts when you turn Tor on.';
}
