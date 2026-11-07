import { fetchedText, parseLines, type LineKind } from '../lib/bridges';
import {
  LINES_KEY, NO_LINES,
  type BgBroadcast, type BgMessage, type BridgeLines, type BridgesMessage, type BridgesResult, type DlMessage, type DownloadsState,
} from '../lib/messages';
import type { TorState } from '../lib/state';
import { chooseTheme, chosenTheme, clearTheme } from '../lib/theme';
import { helperText } from './helper-text';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const KINDS: LineKind[] = ['obfs4', 'webtunnel'];

function renderHelper(s: TorState): void {
  $('helper').textContent = helperText(s);
  $('installHelper').hidden = !s.helperMissing;
}

function renderDownloads(d: DownloadsState): void {
  if (d.folder) $('downloads').textContent = `Torrents are saved in ${d.folder}.`;
}

async function showHelper(): Promise<void> {
  renderHelper(await chrome.runtime.sendMessage({ type: 'GET_STATE' } satisfies BgMessage));
}

async function showDownloads(): Promise<void> {
  renderDownloads(await chrome.runtime.sendMessage({ type: 'GET_DOWNLOADS' } satisfies DlMessage));
}

// Keep up with Tor turned on or off, and downloads, while this page is open.
chrome.runtime.onMessage.addListener((msg: BgBroadcast) => {
  if (msg.type === 'STATE') renderHelper(msg.state);
  else if (msg.type === 'DOWNLOADS') renderDownloads(msg.state);
});

async function loadLines(): Promise<void> {
  const saved = ((await chrome.storage.local.get(LINES_KEY))[LINES_KEY] as BridgeLines | undefined) ?? NO_LINES;
  for (const kind of KINDS) $<HTMLTextAreaElement>(kind).value = saved[kind].map(l => l.replace(/^Bridge /, '')).join('\n');
}

async function saveLines(): Promise<void> {
  const next: BridgeLines = { obfs4: [], webtunnel: [] };
  let bad = false;
  for (const kind of KINDS) {
    const { lines, errors } = parseLines(kind, $<HTMLTextAreaElement>(kind).value);
    const list = $(`${kind}Errors`);
    list.replaceChildren(...errors.map(text => Object.assign(document.createElement('li'), { textContent: text })));
    list.hidden = errors.length === 0;
    bad ||= errors.length > 0;
    next[kind] = lines;
  }
  if (bad) {
    $('saved').textContent = 'Fix the lines marked above.';
    return;
  }
  await chrome.storage.local.set({ [LINES_KEY]: next });
  $('saved').textContent = `Saved: ${next.obfs4.length} obfs4, ${next.webtunnel.length} WebTunnel.`;
}

/** Ask bridges.torproject.org for lines, put them in the box and save them. */
async function getLines(kind: LineKind, button: HTMLButtonElement): Promise<void> {
  const label = button.textContent;
  button.disabled = true;
  button.textContent = 'Asking bridges.torproject.org…';
  const fetched = $('fetched');
  try {
    const r: BridgesResult = await chrome.runtime.sendMessage({ type: 'FETCH_BRIDGES', kind } satisfies BridgesMessage);
    if (!r.ok) {
      fetched.textContent = r.error;
      fetched.classList.add('bad');
    } else {
      $<HTMLTextAreaElement>(kind).value = r.lines.join('\n');
      // Save these lines whatever state the other box is in.
      const { lines } = parseLines(kind, r.lines.join('\n'));
      const saved = ((await chrome.storage.local.get(LINES_KEY))[LINES_KEY] as BridgeLines | undefined) ?? NO_LINES;
      await chrome.storage.local.set({ [LINES_KEY]: { ...saved, [kind]: lines } });
      $(`${kind}Errors`).hidden = true;
      fetched.textContent = `${fetchedText(kind, r)} Saved.`;
      fetched.classList.remove('bad');
    }
    fetched.hidden = false;
  } finally {
    button.disabled = false;
    button.textContent = label;
  }
}

function initTheme(): void {
  const current = chosenTheme() ?? 'system';
  document.querySelectorAll<HTMLInputElement>('input[name="theme"]').forEach(input => {
    input.checked = input.value === current;
    input.addEventListener('change', () => {
      if (input.value === 'system') clearTheme();
      else chooseTheme(input.value as 'light' | 'dark');
    });
  });
}

$('save').addEventListener('click', () => void saveLines());
for (const id of ['getObfs4', 'getWebtunnel']) {
  const button = $<HTMLButtonElement>(id);
  button.addEventListener('click', () => void getLines(button.dataset.kind as LineKind, button));
}
initTheme();
void loadLines();
void showHelper();
void showDownloads();
