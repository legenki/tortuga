import type { BgBroadcast, BgMessage } from '../lib/messages';
import type { BridgeKind } from '../lib/protocol';
import { DEFAULT_SITE, siteOf } from '../lib/site';
import type { TorState } from '../lib/state';
import { viewFor } from './view';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const connDirect = $<HTMLInputElement>('connDirect');
const connTor = $<HTMLInputElement>('connTor');
const bridge = $<HTMLSelectElement>('bridge');
const status = $('status');
const statusText = $('statusText');
const note = $('note');
const hops = $('hops');
const restart = $<HTMLButtonElement>('restart');
const newCircuit = $<HTMLButtonElement>('newCircuit');

let site = DEFAULT_SITE;
let state: TorState | null = null;

function send(msg: BgMessage): Promise<TorState> {
  return chrome.runtime.sendMessage(msg);
}

function render(s: TorState): void {
  state = s;
  const v = viewFor(s, site);
  connTor.checked = v.torSelected;
  connDirect.checked = !v.torSelected;
  bridge.value = s.bridge;
  status.dataset.state = v.tone;
  statusText.textContent = v.status;
  note.textContent = v.note ?? '';
  note.hidden = !v.note;
  restart.hidden = !v.showRestart;
  newCircuit.disabled = !v.canNewCircuit;
  hops.replaceChildren(...v.hops.map(line => Object.assign(document.createElement('li'), { textContent: line })));
  hops.hidden = v.hops.length === 0;
}

const turnOn = () => send({ type: 'TOR_ON', bridge: bridge.value as BridgeKind }).then(render);

connTor.addEventListener('change', turnOn);
connDirect.addEventListener('change', () => send({ type: 'TOR_OFF' }).then(render));
restart.addEventListener('click', turnOn);
bridge.addEventListener('change', () => { if (state && state.phase !== 'off') void turnOn(); });
newCircuit.addEventListener('click', () => send({ type: 'NEW_CIRCUIT', site }).then(render));

chrome.runtime.onMessage.addListener((msg: BgBroadcast) => {
  if (msg.type === 'STATE') render(msg.state);
});

async function init(): Promise<void> {
  if (__TARGET__ === 'firefox') {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    site = siteOf(tab?.url);
  }
  render(await send({ type: 'GET_STATE' }));
}

void init();
