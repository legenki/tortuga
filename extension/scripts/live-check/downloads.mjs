// Downloads end to end, run by `run.sh downloads` against headless Firefox
// (BiDi :9222) with site/links.html served on 127.0.0.1:8765: a click on a
// magnet link → confirm window → Download → progress in the popup → pause,
// resume → remove with files; a .torrent link → confirm → Cancel; a normal
// link is left alone. Downloads go to DL_DIR (argument 2), never ~/Downloads.
import { readdirSync, writeFileSync } from 'node:fs';

const [, , SHOTS, DL_DIR] = process.argv;
const t0 = Date.now();
const log = (...a) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1).padStart(5)}s]`, ...a);
const sleep = ms => new Promise(r => setTimeout(r, ms));
let failures = 0;
const check = (ok, what) => { log(ok ? 'PASS' : 'FAIL', what); if (!ok) failures++; };

const ws = new WebSocket('ws://127.0.0.1:9222/session');
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let nextId = 1;
const waiting = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); } };
const cmd = (method, params = {}) => new Promise((res, rej) => {
  const id = nextId++;
  waiting.set(id, m => (m.type === 'error' ? rej(new Error(`${method}: ${m.message}`)) : res(m.result)));
  ws.send(JSON.stringify({ id, method, params }));
});
const ev = async (context, expression) => {
  const r = await cmd('script.evaluate', { expression, target: { context }, awaitPromise: true });
  if (r.type === 'exception') throw new Error(r.exceptionDetails.text);
  return r.result.value;
};
const contexts = async () => (await cmd('browsingContext.getTree', {})).contexts;
async function waitFor(pred, ms, what) {
  for (let i = 0; i < ms / 250; i++) { const v = await pred(); if (v) return v; await sleep(250); }
  throw new Error(`timed out: ${what}`);
}
async function shot(context, name) {
  const width = Math.ceil(await ev(context, 'document.body.getBoundingClientRect().width'));
  const height = Math.ceil(await ev(context, 'document.documentElement.scrollHeight'));
  const { data } = await cmd('browsingContext.captureScreenshot', { context, clip: { type: 'box', x: 0, y: 0, width, height } });
  writeFileSync(`${SHOTS}/${name}.png`, Buffer.from(data, 'base64'));
}

await cmd('session.new', { capabilities: {} });
const win = (await cmd('browsingContext.getTree', { 'moz:scope': 'chrome' })).contexts[0].context;
const host = await ev(win, `WebExtensionPolicy.getByID('tortuga@legenki.com').mozExtensionHostname`);

// 1. A page with torrent links.
const { context: page } = await cmd('browsingContext.create', { type: 'tab' });
await cmd('browsingContext.navigate', { context: page, url: 'http://127.0.0.1:8765/links.html', wait: 'complete' });
await sleep(500);
const known = new Set((await contexts()).map(c => c.context));
await ev(page, `document.getElementById('magnet').click(); 1`);
const confirmCtx = await waitFor(async () => (await contexts()).find(c => !known.has(c.context) && c.url.includes('confirm.html'))?.context, 10000, 'confirm window');
check(true, 'magnet click opened the confirm window');
check((await ev(page, 'location.href')) === 'http://127.0.0.1:8765/links.html', 'the page did not follow the magnet link');

// 2. Confirm window: details, then Download.
await waitFor(() => ev(confirmCtx, `!document.getElementById('details').hidden`), 60000, 'torrent details');
const name = await ev(confirmCtx, `document.getElementById('name').textContent`);
const size = await ev(confirmCtx, `document.getElementById('size').textContent`);
log('confirm shows:', name, size, await ev(confirmCtx, `document.getElementById('folder').textContent`));
check(name === 'debian-13.7.0-amd64-netinst.iso' && size === '756 MB', 'name and size before downloading');
await shot(confirmCtx, 'confirm');
await ev(confirmCtx, `document.getElementById('download').click(); 1`);
await waitFor(async () => !(await contexts()).some(c => c.context === confirmCtx), 10000, 'confirm window closes').catch(e => check(false, e.message));
check(true, 'confirm window closed after Download');

// 3. Popup → Downloads tab.
const before = new Set((await contexts()).map(c => c.context));
await ev(win, `(gBrowser.selectedTab = gBrowser.addTrustedTab('moz-extension://${host}/popup.html'), 1)`);
const popup = await waitFor(async () => (await contexts()).find(c => !before.has(c.context) && c.url.includes('popup.html'))?.context, 10000, 'popup');
await sleep(800);
await ev(popup, `document.getElementById('tabDownloads').click(); 1`);
const row = await waitFor(async () => {
  const d = await ev(popup, `chrome.runtime.sendMessage({ type: 'GET_DOWNLOADS' }).then(d => JSON.stringify(d))`).then(JSON.parse);
  const r = d.rows[0];
  return r && r.state === 'downloading' && r.done > 20e6 ? r : null;
}, 60000, 'download progress');
log('row:', JSON.stringify(row));
check(row.name === name, 'the download shows in the Downloads tab');
await sleep(1200);
log('popup says:', await ev(popup, `document.querySelector('.row-line')?.textContent`), '| badge', await ev(popup, `document.getElementById('badge').textContent`));
await shot(popup, 'downloads');

// 4. Pause, resume.
await ev(popup, `document.querySelector('.row-actions button[title="Pause"]').click(); 1`);
await waitFor(() => ev(popup, `!!document.querySelector('.row-paused')`), 10000, 'paused row');
check(true, 'Pause works');
await ev(popup, `document.querySelector('.row-actions button[title="Resume"]').click(); 1`);
await waitFor(() => ev(popup, `!!document.querySelector('.row-downloading, .row-starting')`), 10000, 'resumed row');
check(true, 'Resume works');

// 5. Remove with files.
await ev(popup, `document.querySelector('.row-actions button[title="Remove"]').click(); 1`);
await sleep(300);
await shot(popup, 'remove-ask');
await ev(popup, `document.querySelector('.row-remove button[title="Remove and delete the files"]').click(); 1`);
await waitFor(() => ev(popup, `document.querySelectorAll('#rows > li').length === 0`), 10000, 'row gone');
await sleep(1000);
check(readdirSync(DL_DIR).length === 0, `files deleted (left: ${readdirSync(DL_DIR).join(', ') || 'none'})`);

// 6. A .torrent link, then Cancel.
const known2 = new Set((await contexts()).map(c => c.context));
await cmd('browsingContext.activate', { context: page });
await ev(page, `document.getElementById('file').click(); 1`);
const confirm2 = await waitFor(async () => (await contexts()).find(c => !known2.has(c.context) && c.url.includes('confirm.html'))?.context, 10000, 'second confirm window');
await waitFor(() => ev(confirm2, `!document.getElementById('details').hidden`), 60000, 'details from the .torrent link');
check(true, '.torrent link opens the confirm window with details');
await ev(confirm2, `document.getElementById('cancel').click(); 1`);
await waitFor(async () => !(await contexts()).some(c => c.context === confirm2), 10000, 'cancel closes');
await sleep(1500);
const after = await ev(popup, `chrome.runtime.sendMessage({ type: 'GET_DOWNLOADS' }).then(d => d.rows.length)`);
check(after === 0, 'Cancel downloads nothing');

// 7. A plain link is left alone.
await ev(page, `document.getElementById('plain').addEventListener('click', e => e.preventDefault()); document.getElementById('plain').click(); 1`);
await sleep(800);
check(!(await contexts()).some(c => c.url.includes('confirm.html')), 'a normal link opens no confirm window');

log(failures ? `${failures} FAILED` : 'ALL PASSED');
await Promise.race([cmd('session.end', {}).catch(() => {}), sleep(1000)]);
process.exit(failures ? 1 : 0);
