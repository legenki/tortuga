// The Downloads tab: add a torrent (link or file), and one row per download
// with progress, pause / resume and remove (keeping or deleting the files).
import { activeCount, isDone, isTorrentLink, percent, rowLine } from '../lib/downloads';
import type { DlMessage, DownloadsState } from '../lib/messages';
import type { TorrentRow } from '../lib/protocol';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const rows = $<HTMLUListElement>('rows');
const empty = $('empty');
const error = $('dlError');
const folder = $('folder');
const badge = $('badge');
const addForm = $<HTMLFormElement>('addForm');
const addInput = $<HTMLInputElement>('addInput');
const addFile = $<HTMLInputElement>('addFile');

/** The row whose Remove asked "keep or delete files?", if any. */
let removing: string | null = null;
let last: DownloadsState | null = null;

function send(msg: DlMessage): Promise<unknown> {
  return chrome.runtime.sendMessage(msg);
}

function showError(text: string | null): void {
  error.textContent = text ?? '';
  error.hidden = !text;
}

function button(label: string, title: string, onClick: () => void, cls = 'icon'): HTMLButtonElement {
  const b = Object.assign(document.createElement('button'), { type: 'button', className: `btn ${cls}`, textContent: label, title });
  b.setAttribute('aria-label', title);
  b.addEventListener('click', onClick);
  return b;
}

function rowNode(r: TorrentRow): HTMLLIElement {
  const li = document.createElement('li');
  li.className = `row row-${r.state}`;
  const head = document.createElement('div');
  head.className = 'row-head';
  const name = Object.assign(document.createElement('span'), { className: 'row-name', textContent: r.name, title: r.name });
  const actions = document.createElement('span');
  actions.className = 'row-actions';
  if (r.state === 'paused') {
    const label = isDone(r) ? 'Share again (one more copy, from your IP)' : 'Resume';
    actions.append(button('▶', label, () => void send({ type: 'TORRENT_RESUME', id: r.id })));
  } else if (r.state !== 'error') {
    actions.append(button('⏸', r.state === 'seeding' ? 'Stop sharing' : 'Pause', () => void send({ type: 'TORRENT_PAUSE', id: r.id })));
  }
  actions.append(button('✕', 'Remove', () => { removing = r.id; redraw(); }));
  head.append(name, actions);

  const bar = document.createElement('div');
  bar.className = 'progress';
  const fill = document.createElement('i');
  fill.style.width = `${percent(r)}%`;
  bar.append(fill);

  const line = Object.assign(document.createElement('div'), { className: 'row-line', textContent: rowLine(r) });
  li.append(head, bar, line);

  if (removing === r.id) {
    const ask = document.createElement('div');
    ask.className = 'row-remove';
    ask.append(
      Object.assign(document.createElement('span'), { textContent: 'Remove and stop sharing?' }),
      button('Keep files', 'Remove, keep the files', () => remove(r.id, false), 'small'),
      button('Delete files', 'Remove and delete the files', () => remove(r.id, true), 'small danger'),
      button('Cancel', 'Cancel', () => { removing = null; redraw(); }, 'small'),
    );
    li.append(ask);
  }
  return li;
}

function remove(id: string, deleteFiles: boolean): void {
  removing = null;
  void send({ type: 'TORRENT_REMOVE', id, deleteFiles });
}

function redraw(): void {
  if (!last) return;
  rows.replaceChildren(...last.rows.map(rowNode));
  empty.hidden = last.rows.length > 0;
  folder.textContent = last.folder ? `Saved to ${last.folder}` : '';
  folder.hidden = !last.folder;
  const n = activeCount(last.rows);
  badge.textContent = String(n);
  badge.hidden = n === 0;
  showError(last.helperMissing ? 'The Tortuga helper is not installed.' : last.error);
}

export function renderDownloads(state: DownloadsState): void {
  last = state;
  if (removing && !state.rows.some(r => r.id === removing)) removing = null;
  redraw();
}

addForm.addEventListener('submit', e => {
  e.preventDefault();
  const url = addInput.value.trim();
  if (!isTorrentLink(url)) return showError('That is not a magnet or .torrent link.');
  showError(null);
  addInput.value = '';
  void send({ type: 'TORRENT_OPEN', source: { url } });
});

addFile.addEventListener('change', () => {
  const file = addFile.files?.[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    // A data: URL; the helper wants the base64 after the comma.
    const torrentFile = String(reader.result).split(',', 2)[1] ?? '';
    addFile.value = '';
    void send({ type: 'TORRENT_OPEN', source: { torrentFile } });
  };
  reader.readAsDataURL(file);
});
