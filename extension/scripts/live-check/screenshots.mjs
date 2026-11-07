// README screenshots, run by `run.sh screenshots`: light theme, Tor on
// through Snowflake with a site's route, the bridge picker, the confirm
// window and the Downloads tab. Paths on this Mac are hidden in the shots.
import { mkdirSync, writeFileSync } from 'node:fs';

const [, , OUT] = process.argv;
mkdirSync(OUT, { recursive: true });
const t0 = Date.now();
const log = (...a) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1).padStart(5)}s]`, ...a);
const sleep = ms => new Promise(r => setTimeout(r, ms));

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
// Lay the page out as wide as the real popup (340) or confirm window (440)
// and clip to its content, below the fold too. SCALE=2 draws it at 2x with CSS
// zoom: text and SVG are rendered sharp, not stretched.
const SCALE = Number(process.env.SCALE ?? 1);
async function shot(context, name, width = 340) {
  await ev(context, `document.documentElement.style.zoom = ''; document.documentElement.style.width = '${width}px'; document.body.style.boxSizing = 'border-box'; document.body.style.width = '${width}px'; 1`);
  await sleep(300);
  const height = Math.ceil(await ev(context, `Math.max(...[...document.body.children].filter(e => e.offsetParent || e === document.body.lastElementChild).map(e => e.getBoundingClientRect().bottom)) + 14`));
  if (SCALE !== 1) await ev(context, `document.documentElement.style.zoom = '${SCALE}'; 1`);
  await sleep(400);
  const { data } = await cmd('browsingContext.captureScreenshot', { context, origin: 'document', clip: { type: 'box', x: 0, y: 0, width: width * SCALE, height: height * SCALE } });
  writeFileSync(`${OUT}/${name}.png`, Buffer.from(data, 'base64'));
  if (SCALE !== 1) await ev(context, `document.documentElement.style.zoom = ''; 1`);
  log('saved', name, `${width}×${height} at ${SCALE}x`);
}
const HIDE_PATHS = `(() => { const s = document.createElement('style');
  s.textContent = '#folder, dd#folder, div:has(> dd#folder) { display: none !important; }';
  document.head.append(s); return 1; })()`;

await cmd('session.new', { capabilities: {} });
const win = (await cmd('browsingContext.getTree', { 'moz:scope': 'chrome' })).contexts[0].context;
const host = await ev(win, `WebExtensionPolicy.getByID('tortuga@legenki.com').mozExtensionHostname`);
async function openPopup(select) {
  const before = new Set((await contexts()).map(c => c.context));
  await ev(win, `(window.__t = gBrowser.addTrustedTab('moz-extension://${host}/popup.html'), ${select ? 'gBrowser.selectedTab = window.__t, ' : ''}1)`);
  const ctx = await waitFor(async () => (await contexts()).find(c => !before.has(c.context) && c.url.includes('popup.html'))?.context, 10000, 'popup');
  await sleep(1200);
  return ctx;
}

// Light theme (localStorage is shared by the extension's pages), then Tor on.
const setup = await openPopup(true);
await ev(setup, `localStorage.setItem('tortuga-theme', '${process.env.THEME ?? 'light'}'); localStorage.setItem('tortuga-tab', 'route'); 1`);
await ev(setup, `chrome.runtime.sendMessage({ type: 'SET_BRIDGE', bridge: 'snowflake' }).then(() => { document.getElementById('connTor').click(); return 1; })`);
const st = () => ev(setup, `chrome.runtime.sendMessage({ type: 'GET_STATE' }).then(s => JSON.stringify(s))`).then(JSON.parse);
await waitFor(async () => (await st()).phase !== 'connecting', 180000, 'Tor');
log('phase:', JSON.stringify(await st()).slice(0, 400));

// A site through Tor, then the popup opened behind it so it reads that site.
const { context: site } = await cmd('browsingContext.create', { type: 'tab' });
await cmd('browsingContext.navigate', { context: site, url: 'https://check.torproject.org/', wait: 'complete' }).catch(e => log(e.message));
await cmd('browsingContext.activate', { context: site });
await sleep(1500);
const popup = await openPopup(false);
await ev(win, `(gBrowser.selectedTab = window.__t, 1)`);
await sleep(1500);
await ev(popup, HIDE_PATHS);
log('status:', await ev(popup, `document.getElementById('statusText').textContent`), '|', await ev(popup, `document.getElementById('exit').textContent`));
await shot(popup, 'route');
await ev(popup, `document.getElementById('bridgeBtn').click(); 1`);
await sleep(500);
await shot(popup, 'bridges');
await ev(popup, `document.getElementById('bridgeBtn').click(); 1`);

// Confirm window from a magnet link.
const { context: page } = await cmd('browsingContext.create', { type: 'tab' });
await cmd('browsingContext.navigate', { context: page, url: 'http://127.0.0.1:8765/links.html', wait: 'complete' });
await sleep(500);
const known = new Set((await contexts()).map(c => c.context));
await ev(page, `document.getElementById('magnet').click(); 1`);
const confirmCtx = await waitFor(async () => (await contexts()).find(c => !known.has(c.context) && c.url.includes('confirm.html'))?.context, 10000, 'confirm window');
await waitFor(() => ev(confirmCtx, `!document.getElementById('details').hidden`), 90000, 'torrent details');
await ev(confirmCtx, HIDE_PATHS);
await sleep(300);
await shot(confirmCtx, 'confirm', 440);
await ev(confirmCtx, `document.getElementById('download').click(); 1`);

// Downloads tab with the row moving.
await cmd('browsingContext.activate', { context: popup }).catch(() => {});
await ev(win, `(gBrowser.selectedTab = window.__t, 1)`);
await ev(popup, `document.getElementById('tabDownloads').click(); 1`);
await waitFor(async () => {
  const d = JSON.parse(await ev(popup, `chrome.runtime.sendMessage({ type: 'GET_DOWNLOADS' }).then(d => JSON.stringify(d))`));
  return d.rows[0] && d.rows[0].state === 'downloading' && d.rows[0].done > 40e6;
}, 90000, 'download progress');
await sleep(1500);
await shot(popup, 'downloads');

// Settings page, with obfs4 lines fetched through the helper.
const before = new Set((await contexts()).map(c => c.context));
await ev(win, `(gBrowser.selectedTab = gBrowser.addTrustedTab('moz-extension://${host}/options.html'), 1)`);
const opts = await waitFor(async () => (await contexts()).find(c => !before.has(c.context) && c.url.includes('options.html'))?.context, 10000, 'settings');
await sleep(1500);
await ev(opts, `document.getElementById('getObfs4').click(); 1`);
await waitFor(() => ev(opts, `document.getElementById('obfs4').value.trim().length > 0`), 90000, 'obfs4 lines').catch(e => log(e.message));
// The run saves to a temp folder: show the real default instead.
await ev(opts, `(() => { const p = document.querySelector('#downloads'); if (p && p.textContent.includes('/')) p.textContent = 'Torrents are saved in Downloads/Tortuga.'; return 1; })()`);
log('helper line:', await ev(opts, `document.getElementById('helper').textContent`));
await shot(opts, 'settings', 760);
await ev(popup, `chrome.runtime.sendMessage({ type: 'GET_DOWNLOADS' }).then(d => Promise.all(d.rows.map(r => chrome.runtime.sendMessage({ type: 'TORRENT_REMOVE', id: r.id, deleteFiles: true })))).then(() => 1)`).catch(() => {});
await ev(setup, `localStorage.removeItem('tortuga-theme'); 1`);
await Promise.race([cmd('session.end', {}).catch(() => {}), sleep(1000)]);
process.exit(0);
