import { describe, it, expect } from 'vitest';
import { initialState, reduce } from '../src/lib/state';
import { helperText } from '../src/options/helper-text';

describe('helperText', () => {
  it('says when the helper is missing', () => {
    const s = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'none' }), { type: 'failed', error: 'x', helperMissing: true });
    expect(helperText(s)).toMatch(/^Not installed/);
  });

  it('shows the version once the helper answered', () => {
    const s = reduce(initialState(), { type: 'hello', version: '0.1.0' });
    expect(helperText(s)).toBe('Version 0.1.0, connected.');
  });

  it('explains when it starts', () => {
    expect(helperText(initialState())).toBe('Starts when you turn Tor on.');
  });
});
