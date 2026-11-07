import { bridgeReady } from '../lib/bridges';
import { LINES_KEY, NO_LINES, type BgBroadcast, type BgMessage, type BridgeLines, type DownloadsState } from '../lib/messages';
import type { BridgeKind } from '../lib/protocol';
import { DEFAULT_SITE, siteOf } from '../lib/site';
import type { TorState } from '../lib/state';
import { renderDownloads } from './downloads';
import { layoutMetro, renderMetro } from './metro';
import { BRIDGE_NAMES, viewFor } from './view';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const connDirect = $<HTMLInputElement>('connDirect');
const connTor = $<HTMLInputElement>('connTor');
const metro = document.getElementById('metro') as unknown as SVGSVGElement;
const status = $('status');
const statusText = $('statusText');
const note = $('note');
const exit = $('exit');
const install = $('install');
const bridgeBtn = $<HTMLButtonElement>('bridgeBtn');
const bridgeName = $('bridgeName');
const bridges = $('bridges');
const restart = $<HTMLButtonElement>('restart');
const newCircuit = $<HTMLButtonElement>('newCircuit');

let site = DEFAULT_SITE;
let state: TorState | null = null;
let lines: BridgeLines = NO_LINES;

function send(msg: BgMessage): Promise<TorState> {
  return chrome.runtime.sendMessage(msg);
}

function capitalized(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function renderBridges(current: BridgeKind): void {
  bridges.querySelectorAll<HTMLButtonElement>('.bridge').forEach(b => {
    const kind = b.dataset.kind as BridgeKind;
    b.disabled = !bridgeReady(kind, lines);
    b.setAttribute('aria-checked', String(kind === current));
  });
  for (const kind of ['obfs4', 'webtunnel'] as const) {
    $(`${kind}State`).textContent = lines[kind].length ? `${lines[kind].length} saved` : 'get lines in Settings';
  }
}

function render(s: TorState): void {
  state = s;
  const v = viewFor(s, site);
  connTor.checked = v.torSelected;
  connDirect.checked = !v.torSelected;
  status.dataset.state = v.tone;
  statusText.textContent = v.status;
  note.textContent = v.note ?? '';
  note.hidden = !v.note;
  exit.textContent = v.exit ?? '';
  exit.hidden = !v.exit;
  restart.hidden = !v.showRestart;
  install.hidden = !v.install;
  newCircuit.disabled = !v.canNewCircuit;
  bridgeName.textContent = capitalized(BRIDGE_NAMES[s.bridge]);
  metro.toggleAttribute('hidden', !v.metro);
  if (v.metro) renderMetro(metro, layoutMetro(v.metro));
  renderBridges(s.bridge);
}

connTor.addEventListener('change', () => send({ type: 'TOR_ON', bridge: state?.bridge ?? 'none' }).then(render));
connDirect.addEventListener('change', () => send({ type: 'TOR_OFF' }).then(render));
restart.addEventListener('click', () => send({ type: 'TOR_ON', bridge: state?.bridge ?? 'none' }).then(render));
newCircuit.addEventListener('click', () => send({ type: 'NEW_CIRCUIT', site }).then(render));

bridgeBtn.addEventListener('click', () => {
  bridges.hidden = !bridges.hidden;
  bridgeBtn.setAttribute('aria-expanded', String(!bridges.hidden));
});
bridges.addEventListener('click', e => {
  const b = (e.target as Element).closest<HTMLButtonElement>('.bridge');
  if (!b || b.disabled) return;
  bridges.hidden = true;
  bridgeBtn.setAttribute('aria-expanded', 'false');
  void send({ type: 'SET_BRIDGE', bridge: b.dataset.kind as BridgeKind }).then(render);
});

$('settings').addEventListener('click', e => {
  e.preventDefault();
  void chrome.runtime.openOptionsPage();
});

chrome.runtime.onMessage.addListener((msg: BgBroadcast) => {
  if (msg.type === 'STATE') render(msg.state);
  else if (msg.type === 'DOWNLOADS') renderDownloads(msg.state);
});

// Route / Downloads tabs; the last one picked opens next time.
const TAB_KEY = 'tortuga-tab';
const tabs = { route: $<HTMLButtonElement>('tabRoute'), downloads: $<HTMLButtonElement>('tabDownloads') };
function showTab(name: keyof typeof tabs): void {
  for (const [key, tab] of Object.entries(tabs)) {
    const on = key === name;
    tab.setAttribute('aria-selected', String(on));
    $(key).hidden = !on;
  }
  try { localStorage.setItem(TAB_KEY, name); } catch { /* storage off */ }
}
tabs.route.addEventListener('click', () => showTab('route'));
tabs.downloads.addEventListener('click', () => showTab('downloads'));
try { if (localStorage.getItem(TAB_KEY) === 'downloads') showTab('downloads'); } catch { /* storage off */ }
chrome.storage.onChanged.addListener(changes => {
  if (LINES_KEY in changes && state) {
    lines = (changes[LINES_KEY].newValue as BridgeLines | undefined) ?? NO_LINES;
    renderBridges(state.bridge);
  }
});

async function init(): Promise<void> {
  if (__TARGET__ === 'firefox') {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    site = siteOf(tab?.url);
  }
  lines = ((await chrome.storage.local.get(LINES_KEY))[LINES_KEY] as BridgeLines | undefined) ?? NO_LINES;
  render(await send({ type: 'GET_STATE' }));
  renderDownloads(await chrome.runtime.sendMessage({ type: 'GET_DOWNLOADS' }) as DownloadsState);
}

void init();
