import { describe, it, expect } from 'vitest';
import { HelperClient, HelperError, HOST_FORBIDDEN, explainHostError, isMissingHost } from '../src/background/helper';
import { FakePort } from './fake-port';

describe('HelperClient', () => {
  it('matches replies to requests by id', async () => {
    const port = new FakePort();
    const client = new HelperClient(port, () => {}, () => {});
    const hello = client.request({ type: 'hello', payload: { protocol: 1 } });
    expect(port.sent[0]).toEqual({ id: 1, type: 'hello', payload: { protocol: 1 } });
    port.emit({ id: 1, type: 'hello', payload: { protocol: 1, version: '0.1.0' } });
    await expect(hello).resolves.toMatchObject({ type: 'hello' });
  });

  it('rejects on an error reply', async () => {
    const port = new FakePort();
    const client = new HelperClient(port, () => {}, () => {});
    const start = client.request({ type: 'tor.start', payload: { bridge: { kind: 'none' } } });
    port.emit({ id: 1, type: 'error', payload: { code: 'tor_failed', message: 'no network' } });
    await expect(start).rejects.toEqual(new HelperError('tor_failed', 'no network'));
  });

  it('passes messages without an id to onEvent', () => {
    const port = new FakePort();
    const events: string[] = [];
    new HelperClient(port, m => events.push(m.type), () => {});
    port.emit({ type: 'tor.status', payload: { phase: 'directory', percent: 30, blocked: null } });
    expect(events).toEqual(['tor.status']);
  });

  it('on disconnect rejects pending requests and reports why', async () => {
    const port = new FakePort();
    const gone: string[] = [];
    const client = new HelperClient(port, () => {}, r => gone.push(r), () => 'Specified native messaging host not found.');
    const hello = client.request({ type: 'hello', payload: { protocol: 1 } });
    port.die();
    await expect(hello).rejects.toThrow('Specified native messaging host not found.');
    expect(gone).toEqual(['Specified native messaging host not found.']);
  });

  it('close() does not report the helper as gone', () => {
    const port = new FakePort();
    const gone: string[] = [];
    const client = new HelperClient(port, () => {}, r => gone.push(r));
    client.close();
    port.die();
    expect(port.disconnected).toBe(true);
    expect(gone).toEqual([]);
  });
});

describe('isMissingHost', () => {
  it('recognises both browsers', () => {
    expect(isMissingHost('Specified native messaging host not found.')).toBe(true);
    expect(isMissingHost('No such native application org.tortuga.helper')).toBe(true);
    expect(isMissingHost('Native host has exited.')).toBe(false);
  });
});

describe('explainHostError', () => {
  it('turns Chrome\'s "forbidden" (an extension ID the helper wasn\'t installed for) into what to do', () => {
    expect(explainHostError('Access to the specified native messaging host is forbidden.')).toBe(HOST_FORBIDDEN);
  });
  it('leaves other reasons as they are', () => {
    expect(explainHostError('Native host has exited.')).toBe('Native host has exited.');
  });
});
