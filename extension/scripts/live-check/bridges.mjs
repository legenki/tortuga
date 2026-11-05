// "Get … lines" on the settings page, run by `run.sh bridges` against headless
// Firefox (BiDi :9222) with Tor off, so the request goes straight to
// bridges.torproject.org through the downloads helper: obfs4 lines fill the
// box and are saved (the popup's picker then offers obfs4); WebTunnel either
// fills its box too or shows Moat's "none are needed here".
import { writeFileSync } from 'node:fs';

const [, , SHOTS] = process.argv;
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
async function waitFor(pred, ms, what) {
  for (let i = 0; i < ms / 250; i++) { const v = await pred(); if (v) return v; await sleep(250); }
  throw new Error(`timed out: ${what}`);
}
async function shot(context, name) {
  if (!SHOTS) return;
  const width = Math.ceil(await ev(context, 'document.body.getBoundingClientRect().width'));
  const height = Math.ceil(await ev(context, 'document.documentElement.scrollHeight'));
  const { data } = await cmd('browsingContext.captureScreenshot', { context, clip: { type: 'box', x: 0, y: 0, width, height } });
  writeFileSync(`${SHOTS}/${name}.png`, Buffer.from(data, 'base64'));
}

await cmd('session.new', { capabilities: {} });
const win = (await cmd('browsingContext.getTree', { 'moz:scope': 'chrome' })).contexts[0].context;
const host = await ev(win, `WebExtensionPolicy.getByID('tortuga@legenki.com').mozExtensionHostname`);
async function openPage(path) {
  const before = new Set((await cmd('browsingContext.getTree', {})).contexts.map(c => c.context));
  await ev(win, `(gBrowser.selectedTab = gBrowser.addTrustedTab('moz-extension://${host}/${path}'), 1)`);
  const ctx = await waitFor(async () => (await cmd('browsingContext.getTree', {})).contexts.find(c => !before.has(c.context) && c.url.includes(path))?.context, 10000, path);
  await sleep(800);
  return ctx;
}

const options = await openPage('options.html');
await ev(options, `document.getElementById('getObfs4').click(); 1`);
await waitFor(() => ev(options, `!document.getElementById('fetched').hidden`), 60000, 'obfs4 answer');
const obfs4Status = await ev(options, `document.getElementById('fetched').textContent`);
log('obfs4:', obfs4Status);
check(/^Got \d+ obfs4 lines? from bridges\.torproject\.org/.test(obfs4Status), 'Get obfs4 lines fills the box');
const saved = await ev(options, `chrome.storage.local.get('tortugaBridgeLines').then(r => r.tortugaBridgeLines.obfs4.length)`);
check(saved > 0 && (await ev(options, `document.getElementById('obfs4').value.split('\\n').filter(Boolean).length`)) === saved, `lines saved (${saved})`);
check((await ev(options, `document.getElementById('obfs4Errors').hidden`)) === true, 'the fetched lines pass the line check');

await ev(options, `document.getElementById('getWebtunnel').click(); 1`);
await waitFor(() => ev(options, `document.getElementById('fetched').textContent.includes('WebTunnel') || document.getElementById('fetched').textContent.includes('webtunnel')`), 60000, 'webtunnel answer');
const wt = await ev(options, `document.getElementById('fetched').textContent`);
log('webtunnel:', wt);
check(/^Got \d+ WebTunnel/.test(wt) || /no webtunnel bridges for this network/.test(wt), 'WebTunnel: lines, or Moat says none are needed');
await shot(options, 'options-bridges');

const popup = await openPage('popup.html');
await ev(popup, `document.getElementById('bridgeBtn').click(); 1`);
await sleep(300);
check((await ev(popup, `document.querySelector('.bridge[data-kind="obfs4"]').disabled`)) === false, 'the popup offers obfs4 now');
log('obfs4 card says:', await ev(popup, `document.getElementById('obfs4State').textContent`));
await shot(popup, 'popup-bridges');

log(failures ? `${failures} FAILED` : 'ALL PASSED');
await Promise.race([cmd('session.end', {}).catch(() => {}), sleep(1000)]);
process.exit(failures ? 1 : 0);
