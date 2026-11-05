// Live check of Tor mode in Firefox, run by run.sh against headless Firefox
// with the extension loaded (WebDriver BiDi on :9222). Turns Tor on through
// Snowflake, checks per-site circuits, New circuit, UTC for sites, that
// nothing gets out while the helper is dead, Restart, and Direct.
import { execSync } from 'node:child_process';

const t0 = Date.now();
const log = (...a) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1).padStart(5)}s]`, ...a);
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const ws = new WebSocket('ws://127.0.0.1:9222/session');
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
      return ws;
    } catch { await sleep(1000); }
  }
  throw new Error('no BiDi');
}

const ws = await connect();
let nextId = 1;
const waiting = new Map();
ws.onmessage = e => {
  const m = JSON.parse(e.data);
  if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); }
};
function cmd(method, params = {}) {
  const id = nextId++;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((res, rej) => waiting.set(id, m => (m.type === 'error' ? rej(new Error(`${method}: ${m.error} ${m.message}`)) : res(m.result))));
}
async function evaluate(context, expression) {
  const r = await cmd('script.evaluate', { expression, target: { context }, awaitPromise: true });
  if (r.type === 'exception') throw new Error(r.exceptionDetails.text);
  return r.result.value;
}
async function open(url) {
  const { context } = await cmd('browsingContext.create', { type: 'tab' });
  await cmd('browsingContext.navigate', { context, url, wait: 'complete' }).catch(e => log('navigate:', e.message));
  return context;
}
const state = popup => evaluate(popup, `chrome.runtime.sendMessage({ type: 'GET_STATE' }).then(s => JSON.stringify(s))`).then(JSON.parse);
const statusText = popup => evaluate(popup, `document.getElementById('statusText').textContent`);
async function fetchText(url) {
  const ctx = await open(url);
  const text = await evaluate(ctx, `(document.body ? document.body.innerText.slice(0, 160) : '') + ' [tz ' + new Date().getTimezoneOffset() + ']'`).catch(e => `ERROR ${e.message}`);
  const href = await evaluate(ctx, 'location.href').catch(() => '?');
  await cmd('browsingContext.close', { context: ctx });
  return `${href} :: ${text.replace(/\s+/g, ' ')}`;
}
let failures = 0;
const check = (ok, what) => { log(ok ? 'PASS' : 'FAIL', what); if (!ok) failures++; };

process.on('unhandledRejection', async e => { console.error(e); await Promise.race([cmd('session.end', {}).catch(() => {}), sleep(1000)]); process.exit(2); });
await cmd('session.new', { capabilities: {} });

// BiDi won't navigate a tab to moz-extension://, so open it from the browser
// window's privileged scope (needs --remote-allow-system-access).
async function openExtensionPage(path) {
  const before = new Set((await cmd('browsingContext.getTree', {})).contexts.map(c => c.context));
  const win = (await cmd('browsingContext.getTree', { 'moz:scope': 'chrome' })).contexts[0].context;
  const host = await evaluate(win, `WebExtensionPolicy.getByID('tortuga@legenki.com').mozExtensionHostname`);
  await evaluate(win, `(gBrowser.selectedTab = gBrowser.addTrustedTab('moz-extension://${host}/${path}'), 1)`);
  for (let i = 0; i < 50; i++) {
    const ctx = (await cmd('browsingContext.getTree', {})).contexts.find(c => !before.has(c.context));
    if (ctx && ctx.url.startsWith('moz-extension://')) { await sleep(500); return ctx.context; }
    await sleep(200);
  }
  throw new Error('extension page did not open');
}
const popup = await openExtensionPage('popup.html');
log('1. status:', await statusText(popup));
check((await state(popup)).phase === 'off', 'starts off');
const tzOff = new Date().getTimezoneOffset();

log('2. Snowflake → Tor');
await evaluate(popup, `(() => { const b = document.getElementById('bridge'); b.value = 'snowflake'; document.getElementById('connTor').click(); })()`);
let s;
for (let i = 0; i < 120; i++) {
  s = await state(popup);
  if (i % 5 === 0 || s.phase !== 'connecting') log('   ', await statusText(popup));
  if (s.phase !== 'connecting') break;
  await sleep(1000);
}
check(s.phase === 'on', `Tor on (${s.phase}${s.error ? ': ' + s.error : ''})`);

log('3. check.torproject.org:', await fetchText('https://check.torproject.org/api/ip'));
log('4. wikipedia:', (await fetchText('https://www.wikipedia.org/')).slice(0, 80));
await sleep(1000);
s = await state(popup);
const sites = Object.keys(s.circuits);
log('   circuits for:', sites.join(', '));
const a = s.circuits['torproject.org'], b = s.circuits['wikipedia.org'];
check(a && b, 'circuit events for both sites');
if (a && b) {
  log('   torproject.org:', a.hops.map(h => `${h.role}:${h.country ?? '—'}:${h.id.slice(0, 6)}`).join(' → '));
  log('   wikipedia.org: ', b.hops.map(h => `${h.role}:${h.country ?? '—'}:${h.id.slice(0, 6)}`).join(' → '));
  check(JSON.stringify(a.hops) !== JSON.stringify(b.hops), 'different circuits per site');
  check(a.hops[0].role === 'bridge' && a.bridge === 'snowflake', 'first hop is the Snowflake bridge');
}
const tzOnPage = await fetchText('https://example.com/');
log('   example.com through Tor:', tzOnPage.slice(-12));
check(/\[tz 0\]$/.test(tzOnPage), 'resistFingerprinting: sites see UTC');

log('5. New circuit for torproject.org');
await evaluate(popup, `chrome.runtime.sendMessage({ type: 'NEW_CIRCUIT', site: 'torproject.org' }).then(() => 1)`);
log('   ', await fetchText('https://check.torproject.org/api/ip'));
await sleep(1000);
const renewed = (await state(popup)).circuits['torproject.org'];
check(renewed && JSON.stringify(renewed.hops) !== JSON.stringify(a?.hops), 'new circuit has a new path');

log('6. kill the helper');
execSync("pkill -f 'Tortuga/dev/tortuga-helper' || true");
await sleep(1500);
s = await state(popup);
log('   status:', await statusText(popup), '|', s.error);
check(s.phase === 'failed', 'popup shows failed');
const blocked = await fetchText(`https://check.torproject.org/api/ip?nocache=${Date.now()}`);
log('   check.torproject.org while failed:', blocked.slice(0, 140));
check(!/IsTor/.test(blocked), 'nothing loads (cache-busted) while failed');
const cached = await fetchText('https://example.com/');
log('   example.com (visited before) while failed:', cached.slice(0, 60));

log('   Restart');
await evaluate(popup, `document.getElementById('restart').click()`);
for (let i = 0; i < 120; i++) { s = await state(popup); if (s.phase !== 'connecting') break; await sleep(1000); }
check(s.phase === 'on', `back on after Restart (${s.phase})`);

log('7. Direct');
await evaluate(popup, `document.getElementById('connDirect').click()`);
await sleep(1500);
s = await state(popup);
check(s.phase === 'off', 'off');
const direct = await fetchText('https://example.com/');
check(/documentation examples/.test(direct), 'pages load directly again');
log('   example.com direct:', direct.slice(-12));
check(direct.endsWith(`[tz ${tzOff}]`), 'resistFingerprinting released: real timezone again');

log(failures ? `${failures} FAILED` : 'ALL PASSED');
ws.close();
await Promise.race([cmd('session.end', {}).catch(() => {}), sleep(1000)]); process.exit(failures ? 1 : 0);
