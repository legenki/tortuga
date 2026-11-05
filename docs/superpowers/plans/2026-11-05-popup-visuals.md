# Popup Visuals and Settings Implementation Plan (3b)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The popup draws the active tab's route as a metro line (flags, bridge transport, connecting steps, new-circuit animation) with a bridge picker of mini diagrams and the exit relay's address, and a settings page holds bridge lines, helper status and theme.

**Architecture:** `metro.ts` splits into `layoutMetro()` (pure: stations, segments, lit / pending, keys) and `renderMetro()` (SVG). The state gains the bootstrap stage, the helper's version and a bridge chosen while off; `bridges.ts` parses pasted bridge lines. The helper adds each hop's address. A preview page (`extension/dev/`) draws every diagram state for design checks; the Firefox live check from 3a still runs end to end.

**Tech Stack:** as in 3a (TypeScript 5, Vite 5, Vitest 1, `tldts`), Rust for the helper change; Nomada's Twemoji flag font.

Spec: `docs/superpowers/specs/2026-11-05-tortuga-design.md` (*Popup*, *Settings page*). Mockups: `docs/mockups/route-style.html` (A), `popup-layout.html` (A), `bridges.html`.

## Global Constraints

- Plain TypeScript and DOM; colours only from `tokens.css` variables; light and dark.
- `[hidden]` always wins (`[hidden] { display: none !important; }`) — layout classes otherwise override it, SVG included.
- Station keys are `role:relayId`: a station animates only when its relay changes.
- obfs4 / WebTunnel are selectable only with saved lines; lines are stored as `Bridge …` (the form the helper parses) under `tortugaBridgeLines`.
- Anything that isn't an http(s) / ws(s) URL is `DEFAULT_SITE`: shown as "Incognito" in Chrome, "No site" in Firefox.
- The protocol stays version 1: `addr` is a new field the extension reads, nothing else changes.
- Not in this plan: the Downloads tab (torrents plan), Moat "Get a bridge" (Moat plan).

## File Structure

| File | Change |
|---|---|
| `helper/tortuga-helper/src/{hops,protocol,tor}.rs` | `Hop.addr` |
| `extension/src/lib/protocol.ts`, `state.ts`, `messages.ts`, `site.ts` | stage, helper version, chosen bridge, bridge lines, non-web URLs |
| `extension/src/background/controller.ts`, `index.ts` | hello version, stages, `chooseBridge`, lines from storage, `SET_BRIDGE` |
| `extension/src/lib/bridges.ts` (new) | Parse and check bridge lines |
| `extension/src/lib/flags.ts` (new), `src/styles/flags.css`, `public/fonts/*` (from Nomada) | Flag emoji in the Twemoji font |
| `extension/src/popup/metro.ts` (new) | Metro layout and SVG |
| `extension/src/popup/view.ts`, `index.html`, `index.ts`, `style.css` | Popup with the diagram and picker |
| `extension/src/options/*` (new), `vite.config.options.ts` (new), `src/lib/theme.ts` | Settings page |
| `extension/dev/*`, `vite.config.preview.ts` (new) | Metro preview page |
| `extension/manifest*.json`, `package.json`, `tsconfig.json`, `.gitignore` | options page, scripts, dev folder |
| `extension/scripts/live-check/check.mjs` | Bridge via `SET_BRIDGE`; Restart waits for `on` |

Listings are final content: write the file as shown (for changed files, replace the whole file).

---

### Task 1: Hop addresses in the helper

**Files:**
- Modify: `helper/tortuga-helper/src/hops.rs`, `helper/tortuga-helper/src/protocol.rs`, `helper/tortuga-helper/src/tor.rs`

- [ ] **Step 1: Change the tests first**

In `protocol.rs` the `serializes_replies_and_events` test builds `Hop { role: Role::Bridge, id: "abc".into(), addr: Some("192.0.2.3".into()), country: None }` and expects `{"role": "bridge", "id": "abc", "addr": "192.0.2.3", "country": null}`; in `hops.rs` the test helper `hop()` returns `Hop { role, id: id.into(), addr: Some("192.0.2.1".into()), country: Some("DE".into()) }`.
Run: `cd helper && cargo test -p tortuga-helper`
Expected: compile error `struct Hop has no field named addr`.

- [ ] **Step 2: Implement**

`helper/tortuga-helper/src/hops.rs`:

```rust
//! Circuit hops as the popup shows them, and change detection per site.

use std::collections::HashMap;

use serde::Serialize;

/// What a hop does in a circuit, as the popup's metro diagram names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Guard,
    Bridge,
    Middle,
    Exit,
}

/// One hop: its role, the relay's Ed25519 identity, its address and its
/// country when known (a Snowflake bridge has a placeholder address and no
/// country).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Hop {
    pub role: Role,
    pub id: String,
    pub addr: Option<String>,
    pub country: Option<String>,
}

/// Roles of a circuit's hops in order. The first hop is the bridge when
/// bridges are in use, the guard otherwise; the last is the exit.
pub fn roles_for(n_hops: usize, via_bridge: bool) -> Vec<Role> {
    (0..n_hops)
        .map(|i| match i {
            0 if via_bridge => Role::Bridge,
            0 => Role::Guard,
            i if i + 1 == n_hops => Role::Exit,
            _ => Role::Middle,
        })
        .collect()
}

/// Remembers the last path sent for each site, so a `circuit` event goes out
/// only when a site's path changes.
#[derive(Default)]
pub struct CircuitTracker {
    last: HashMap<String, Vec<Hop>>,
}

impl CircuitTracker {
    /// Record `hops` for `site`; true if they differ from the last ones.
    pub fn observe(&mut self, site: &str, hops: &[Hop]) -> bool {
        if self.last.get(site).is_some_and(|prev| prev == hops) {
            return false;
        }
        self.last.insert(site.to_owned(), hops.to_vec());
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hop(role: Role, id: &str) -> Hop {
        Hop { role, id: id.into(), addr: Some("192.0.2.1".into()), country: Some("DE".into()) }
    }

    #[test]
    fn three_hops_without_bridge() {
        assert_eq!(roles_for(3, false), vec![Role::Guard, Role::Middle, Role::Exit]);
    }

    #[test]
    fn three_hops_through_bridge() {
        assert_eq!(roles_for(3, true), vec![Role::Bridge, Role::Middle, Role::Exit]);
    }

    #[test]
    fn four_hops_have_two_middles() {
        assert_eq!(roles_for(4, false), vec![Role::Guard, Role::Middle, Role::Middle, Role::Exit]);
    }

    #[test]
    fn tracker_reports_only_changes() {
        let mut t = CircuitTracker::default();
        let a = vec![hop(Role::Guard, "g"), hop(Role::Middle, "m"), hop(Role::Exit, "e1")];
        let b = vec![hop(Role::Guard, "g"), hop(Role::Middle, "m"), hop(Role::Exit, "e2")];
        assert!(t.observe("github.com", &a));
        assert!(!t.observe("github.com", &a));
        assert!(t.observe("wikipedia.org", &a));
        assert!(t.observe("github.com", &b));
    }
}
```

`helper/tortuga-helper/src/protocol.rs`:

```rust
//! Messages between the extension and the helper (spec: "Protocol").
//! Every message is `{ id?, type, payload? }`; replies carry the request's id.

use serde::{Deserialize, Serialize};

use crate::hops::Hop;

/// Bumped whenever a message changes incompatibly.
pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Deserialize, PartialEq)]
pub struct Request {
    pub id: u64,
    #[serde(flatten)]
    pub body: RequestBody,
}

#[derive(Debug, Deserialize, PartialEq)]
#[serde(tag = "type", content = "payload")]
pub enum RequestBody {
    #[serde(rename = "hello")]
    Hello { protocol: u32 },
    #[serde(rename = "tor.start")]
    TorStart { bridge: BridgeChoice },
    #[serde(rename = "tor.stop")]
    TorStop,
    #[serde(rename = "tor.newCircuit")]
    TorNewCircuit { site: String },
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct BridgeChoice {
    pub kind: BridgeKind,
    #[serde(default)]
    pub lines: Vec<String>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BridgeKind {
    None,
    Snowflake,
    Obfs4,
    Webtunnel,
}

/// Where bootstrap is, for the connecting animation.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Phase {
    /// Reaching the first hop (bridge or guard).
    Bridge,
    /// Downloading the network directory.
    Directory,
    Ready,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct Message {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    #[serde(flatten)]
    pub body: Outgoing,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(tag = "type", content = "payload")]
pub enum Outgoing {
    #[serde(rename = "hello")]
    Hello { protocol: u32, version: String },
    #[serde(rename = "ok")]
    Ok,
    #[serde(rename = "tor.status")]
    TorStatus { phase: Phase, percent: u8, blocked: Option<String> },
    #[serde(rename = "tor.ready", rename_all = "camelCase")]
    TorReady { socks_port: u16 },
    #[serde(rename = "circuit")]
    Circuit { site: String, bridge: Option<BridgeKind>, hops: Vec<Hop> },
    #[serde(rename = "error")]
    Error { code: ErrorCode, message: String },
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    BadRequest,
    HelloRequired,
    ProtocolMismatch,
    TorFailed,
    NotRunning,
}

impl Message {
    pub fn reply(id: u64, body: Outgoing) -> Self {
        Self { id: Some(id), body }
    }

    pub fn event(body: Outgoing) -> Self {
        Self { id: None, body }
    }

    pub fn error(id: Option<u64>, code: ErrorCode, message: impl ToString) -> Self {
        Self { id, body: Outgoing::Error { code, message: message.to_string() } }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hops::Role;
    use serde_json::json;

    fn parse(v: serde_json::Value) -> Request {
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn parses_requests() {
        assert_eq!(
            parse(json!({"id": 1, "type": "hello", "payload": {"protocol": 1}})),
            Request { id: 1, body: RequestBody::Hello { protocol: 1 } }
        );
        assert_eq!(
            parse(json!({"id": 2, "type": "tor.start", "payload": {"bridge": {"kind": "snowflake"}}})),
            Request { id: 2, body: RequestBody::TorStart { bridge: BridgeChoice { kind: BridgeKind::Snowflake, lines: vec![] } } }
        );
        assert_eq!(parse(json!({"id": 3, "type": "tor.stop"})), Request { id: 3, body: RequestBody::TorStop });
        assert_eq!(
            parse(json!({"id": 4, "type": "tor.newCircuit", "payload": {"site": "github.com"}})),
            Request { id: 4, body: RequestBody::TorNewCircuit { site: "github.com".into() } }
        );
    }

    #[test]
    fn rejects_unknown_type() {
        assert!(serde_json::from_value::<Request>(json!({"id": 1, "type": "tor.explode"})).is_err());
    }

    #[test]
    fn serializes_replies_and_events() {
        let ok = serde_json::to_value(Message::reply(3, Outgoing::Ok)).unwrap();
        assert_eq!(ok, json!({"id": 3, "type": "ok"}));

        let ready = serde_json::to_value(Message::reply(2, Outgoing::TorReady { socks_port: 9150 })).unwrap();
        assert_eq!(ready, json!({"id": 2, "type": "tor.ready", "payload": {"socksPort": 9150}}));

        let status = serde_json::to_value(Message::event(Outgoing::TorStatus { phase: Phase::Directory, percent: 40, blocked: None })).unwrap();
        assert_eq!(status, json!({"type": "tor.status", "payload": {"phase": "directory", "percent": 40, "blocked": null}}));

        let circuit = serde_json::to_value(Message::event(Outgoing::Circuit {
            site: "github.com".into(),
            bridge: Some(BridgeKind::Snowflake),
            hops: vec![Hop { role: Role::Bridge, id: "abc".into(), addr: Some("192.0.2.3".into()), country: None }],
        }))
        .unwrap();
        assert_eq!(
            circuit,
            json!({"type": "circuit", "payload": {"site": "github.com", "bridge": "snowflake",
                   "hops": [{"role": "bridge", "id": "abc", "addr": "192.0.2.3", "country": null}]}})
        );

        let err = serde_json::to_value(Message::error(Some(5), ErrorCode::ProtocolMismatch, "want 1")).unwrap();
        assert_eq!(err, json!({"id": 5, "type": "error", "payload": {"code": "protocol_mismatch", "message": "want 1"}}));
    }
}
```

`helper/tortuga-helper/src/tor.rs`:

```rust
//! The Tor side: one Arti client per helper process, its bootstrap progress,
//! and SOCKS connections through it, isolated per site.

use std::io;
use std::sync::{Arc, Mutex};

use arti_client::config::Reconfigure;
use arti_client::status::BootstrapStatus;
use arti_client::{DataStream, DormantMode, StreamPrefs, TorClient, TorClientConfig};
use futures::StreamExt;
use tokio::sync::mpsc::UnboundedSender;
use tor_geoip::GeoipDb;
use tor_linkspec::{HasAddrs, HasRelayIds};
use tor_proto::client::stream::ClientStreamCtrl;
use tor_rtcompat::PreferredRuntime;

use crate::hops::{CircuitTracker, Hop, roles_for};
use crate::isolation::IsolationMap;
use crate::protocol::{BridgeKind, Message, Outgoing, Phase};
use crate::socks::{Connector, SocksRequest};

pub type Events = UnboundedSender<Message>;

/// Arti reports one fraction: 15 % for reaching the first hop, 85 % for the
/// directory. The phases follow that split.
pub fn phase_for(frac: f32, ready: bool) -> Phase {
    if ready {
        Phase::Ready
    } else if frac < 0.15 {
        Phase::Bridge
    } else {
        Phase::Directory
    }
}

fn status_event(s: &BootstrapStatus) -> Outgoing {
    let frac = s.as_frac().clamp(0.0, 1.0);
    Outgoing::TorStatus {
        phase: phase_for(frac, s.ready_for_traffic()),
        percent: (frac * 100.0).round() as u8,
        blocked: s.blocked().map(|b| b.message().to_string()),
    }
}

pub struct Tor {
    client: Arc<TorClient<PreferredRuntime>>,
    bridge: Mutex<BridgeKind>,
    geoip: Arc<GeoipDb>,
    isolation: Mutex<IsolationMap>,
    tracker: Mutex<CircuitTracker>,
    events: Events,
}

impl Tor {
    /// Create the client and bootstrap it, sending `tor.status` events.
    pub async fn start(config: TorClientConfig, bridge: BridgeKind, events: Events) -> anyhow::Result<Arc<Self>> {
        let client = TorClient::builder().config(config).create_unbootstrapped()?;
        let tor = Arc::new(Self {
            client,
            bridge: Mutex::new(bridge),
            geoip: GeoipDb::new_embedded(),
            isolation: Mutex::default(),
            tracker: Mutex::default(),
            events,
        });
        tor.bootstrap().await?;
        Ok(tor)
    }

    /// Switch an existing client to a new bridge choice and wake it up.
    pub async fn restart(&self, config: &TorClientConfig, bridge: BridgeKind) -> anyhow::Result<()> {
        self.client.reconfigure(config, Reconfigure::AllOrNothing)?;
        *self.bridge.lock().unwrap() = bridge;
        self.client.set_dormant(DormantMode::Normal);
        self.bootstrap().await
    }

    /// Stop building circuits until the next `restart`.
    pub fn sleep(&self) {
        self.client.set_dormant(DormantMode::Soft);
    }

    pub fn new_circuit(&self, site: &str) {
        self.isolation.lock().unwrap().renew(site);
    }

    async fn bootstrap(&self) -> anyhow::Result<()> {
        let mut statuses = self.client.bootstrap_events();
        let events = self.events.clone();
        let forward = tokio::spawn(async move {
            while let Some(s) = statuses.next().await {
                if events.send(Message::event(status_event(&s))).is_err() || s.ready_for_traffic() {
                    break;
                }
            }
        });
        let result = self.client.bootstrap().await;
        forward.abort();
        result?;
        let _ = self.events.send(Message::event(Outgoing::TorStatus { phase: Phase::Ready, percent: 100, blocked: None }));
        Ok(())
    }

    /// The path of the tunnel `stream` runs on.
    fn hops_of(&self, stream: &DataStream) -> Option<Vec<Hop>> {
        let tunnel = stream.client_stream_ctrl()?.tunnel()?;
        let path = tunnel.all_paths().into_iter().next()?;
        let via_bridge = *self.bridge.lock().unwrap() != BridgeKind::None;
        let roles = roles_for(path.n_hops(), via_bridge);
        Some(
            path.iter()
                .zip(roles)
                .filter_map(|(hop, role)| {
                    let target = hop.as_chan_target()?;
                    let ip = target.addrs().next().map(|a| a.ip());
                    let country = ip
                        .and_then(|ip| self.geoip.lookup_country_code(ip))
                        .map(|c| c.get().to_string());
                    let id = target.ed_identity().map(|e| e.to_string()).unwrap_or_default();
                    Some(Hop { role, id, addr: ip.map(|ip| ip.to_string()), country })
                })
                .collect(),
        )
    }
}

impl Connector for Arc<Tor> {
    type Stream = DataStream;

    fn connect(&self, req: SocksRequest) -> impl Future<Output = io::Result<DataStream>> + Send {
        let tor = self.clone();
        async move {
            let token = tor.isolation.lock().unwrap().token_for(&req.site);
            let mut prefs = StreamPrefs::new();
            prefs.set_isolation(token);
            let stream = tor
                .client
                .connect_with_prefs((req.host.as_str(), req.port), &prefs)
                .await
                .map_err(io::Error::other)?;
            if let Some(hops) = tor.hops_of(&stream) {
                if tor.tracker.lock().unwrap().observe(&req.site, &hops) {
                    let bridge = *tor.bridge.lock().unwrap();
                    let bridge = (bridge != BridgeKind::None).then_some(bridge);
                    let _ = tor.events.send(Message::event(Outgoing::Circuit { site: req.site.clone(), bridge, hops }));
                }
            }
            Ok(stream)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phases_follow_arti_fraction() {
        assert_eq!(phase_for(0.0, false), Phase::Bridge);
        assert_eq!(phase_for(0.14, false), Phase::Bridge);
        assert_eq!(phase_for(0.15, false), Phase::Directory);
        assert_eq!(phase_for(0.99, false), Phase::Directory);
        assert_eq!(phase_for(0.5, true), Phase::Ready);
    }
}
```

- [ ] **Step 3: Run the tests and rebuild**

Run: `cd helper && cargo test -p tortuga-helper && cargo build --release -p tortuga-helper`
Expected: `test result: ok. 25 passed`; no warnings.

- [ ] **Step 4: Commit**

```bash
git add helper/tortuga-helper/src
git commit -m "helper: report each hop's address"
```

---

### Task 2: State for stages, helper version and the chosen bridge

**Files:**
- Modify: `extension/src/lib/protocol.ts`, `extension/src/lib/state.ts`, `extension/src/lib/messages.ts`, `extension/src/background/controller.ts`
- Test: `extension/tests/state.test.ts`, `extension/tests/controller.test.ts`

**Interfaces:**
- Produces: `Hop.addr: string | null`; `Stage = 'bridge' | 'directory' | 'ready'`; `TorState.stage`, `TorState.helperVersion`; events `hello { version }`, `status { stage, … }`, `choose { bridge }`; `BgMessage` `SET_BRIDGE { bridge }`; `BridgeLines { obfs4: string[]; webtunnel: string[] }`, `LINES_KEY = 'tortugaBridgeLines'`, `NO_LINES`; `Controller.turnOn(bridge, lines = [])`, `Controller.chooseBridge(bridge, lines = [])`.

- [ ] **Step 1: Write the tests**

`extension/tests/state.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { BLACKHOLE_PORT, initialState, reduce, routedPort, type TorState } from '../src/lib/state';
import type { Circuit } from '../src/lib/protocol';

const circuit: Circuit = { site: 'github.com', bridge: null, hops: [{ role: 'guard', id: 'g', addr: '192.0.2.1', country: 'DE' }] };

function on(): TorState {
  return reduce(reduce(initialState(), { type: 'turnOn', bridge: 'snowflake' }), { type: 'ready', socksPort: 9150 });
}

describe('reduce', () => {
  it('off → connecting → on', () => {
    const connecting = reduce(initialState(), { type: 'turnOn', bridge: 'snowflake' });
    expect(connecting).toMatchObject({ phase: 'connecting', bridge: 'snowflake', percent: 0 });
    const progressed = reduce(connecting, { type: 'status', stage: 'directory', percent: 40, blocked: null });
    expect(progressed).toMatchObject({ percent: 40, stage: 'directory' });
    expect(reduce(progressed, { type: 'ready', socksPort: 9150 })).toMatchObject({ phase: 'on', socksPort: 9150, percent: 100, stage: 'ready' });
  });

  it('keeps the helper version across on and off', () => {
    const hello = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'none' }), { type: 'hello', version: '0.1.0' });
    expect(reduce(hello, { type: 'turnOff' }).helperVersion).toBe('0.1.0');
    expect(reduce(reduce(hello, { type: 'turnOff' }), { type: 'turnOn', bridge: 'none' }).helperVersion).toBe('0.1.0');
  });

  it('keeps circuits per site while on', () => {
    expect(reduce(on(), { type: 'circuit', circuit }).circuits['github.com']).toEqual(circuit);
    expect(reduce(initialState(), { type: 'circuit', circuit }).circuits).toEqual({});
  });

  it('a failure while on drops the port', () => {
    const failed = reduce(on(), { type: 'failed', error: 'The helper stopped' });
    expect(failed).toMatchObject({ phase: 'failed', socksPort: null, error: 'The helper stopped' });
  });

  it('a failure while off stays off', () => {
    expect(reduce(initialState(), { type: 'failed', error: 'x' }).phase).toBe('off');
  });

  it('ignores late events from an older start', () => {
    expect(reduce(initialState(), { type: 'ready', socksPort: 9150 }).phase).toBe('off');
  });

  it('a bridge chosen while off is kept, ignored while on', () => {
    expect(reduce(initialState(), { type: 'choose', bridge: 'obfs4' }).bridge).toBe('obfs4');
    expect(reduce(on(), { type: 'choose', bridge: 'obfs4' }).bridge).toBe('snowflake');
  });

  it('turning off keeps the bridge choice', () => {
    expect(reduce(on(), { type: 'turnOff' })).toEqual(initialState('snowflake'));
    expect(reduce(on(), { type: 'turnOff' }).stage).toBeNull();
  });
});

describe('routedPort', () => {
  it('lets traffic go its own way only when off', () => {
    expect(routedPort(initialState())).toBeNull();
  });

  it('uses the SOCKS port when on', () => {
    expect(routedPort(on())).toBe(9150);
  });

  it('blocks while connecting or failed', () => {
    expect(routedPort(reduce(initialState(), { type: 'turnOn', bridge: 'none' }))).toBe(BLACKHOLE_PORT);
    expect(routedPort(reduce(on(), { type: 'failed', error: 'x' }))).toBe(BLACKHOLE_PORT);
  });
});
```

`extension/tests/controller.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { Controller, HELPER_MISSING, INCOGNITO_NEEDED, type Deps } from '../src/background/controller';
import { HelperClient } from '../src/background/helper';
import type { Stored } from '../src/lib/messages';
import { BLACKHOLE_PORT, type TorState } from '../src/lib/state';
import { FakePort, flush } from './fake-port';

function setup(opts: { incognito?: boolean; lastError?: string } = {}) {
  const ports: FakePort[] = [];
  const routes: (number | null)[] = [];
  const privacy: boolean[] = [];
  const saved: Stored[] = [];
  const states: TorState[] = [];
  const deps: Deps = {
    connect: (onEvent, onGone) => {
      const port = new FakePort();
      ports.push(port);
      return new HelperClient(port, onEvent, onGone, () => opts.lastError);
    },
    applyRoute: async p => void routes.push(p),
    applyPrivacy: async on => void privacy.push(on),
    save: async s => void saved.push(s),
    broadcast: s => void states.push(s),
    incognitoAllowed: async () => opts.incognito ?? true,
  };
  return { c: new Controller(deps), ports, routes, privacy, saved, states };
}

/** Answer hello and tor.start the way a healthy helper does. */
async function boot(port: FakePort, socksPort = 9150) {
  await flush();
  port.emit({ id: port.idOf('hello'), type: 'hello', payload: { protocol: 1, version: '0.1.0' } });
  await flush();
  port.emit({ id: port.idOf('tor.start'), type: 'tor.ready', payload: { socksPort } });
  await flush();
}

describe('Controller', () => {
  it('blocks traffic while connecting, then routes through the SOCKS port', async () => {
    const { c, ports, routes, privacy, saved } = setup();
    await c.turnOn('snowflake');
    expect(routes).toEqual([BLACKHOLE_PORT]);
    expect(privacy).toEqual([true]);
    expect(saved).toEqual([{ enabled: true, bridge: 'snowflake' }]);
    await boot(ports[0]);
    expect(ports[0].sent[1]).toMatchObject({ type: 'tor.start', payload: { bridge: { kind: 'snowflake' } } });
    expect(c.current.phase).toBe('on');
    expect(routes).toEqual([BLACKHOLE_PORT, 9150]);
  });

  it('records the helper version and sends bridge lines', async () => {
    const { c, ports } = setup();
    await c.turnOn('obfs4', ['obfs4 192.0.2.55:443 AAAA cert=x iat-mode=0']);
    await boot(ports[0]);
    expect(c.current.helperVersion).toBe('0.1.0');
    expect(ports[0].sent[1]).toMatchObject({ type: 'tor.start', payload: { bridge: { kind: 'obfs4', lines: ['obfs4 192.0.2.55:443 AAAA cert=x iat-mode=0'] } } });
  });

  it('remembers a bridge chosen while off, restarts Tor with one chosen while on', async () => {
    const { c, ports, saved } = setup();
    await c.chooseBridge('webtunnel');
    expect(c.current).toMatchObject({ phase: 'off', bridge: 'webtunnel' });
    expect(saved.at(-1)).toEqual({ enabled: false, bridge: 'webtunnel' });
    expect(ports).toEqual([]);
    await c.turnOn('none');
    await boot(ports[0]);
    await c.chooseBridge('snowflake');
    expect(ports).toHaveLength(2);
    expect(ports[0].disconnected).toBe(true);
    expect(c.current).toMatchObject({ phase: 'connecting', bridge: 'snowflake' });
  });

  it('passes bootstrap stages on', async () => {
    const { c, ports } = setup();
    await c.turnOn('snowflake');
    await flush();
    ports[0].emit({ type: 'tor.status', payload: { phase: 'directory', percent: 42, blocked: null } });
    await flush();
    expect(c.current).toMatchObject({ phase: 'connecting', stage: 'directory', percent: 42 });
  });

  it('turning off releases the route and privacy settings and the helper', async () => {
    const { c, ports, routes, privacy, saved } = setup();
    await c.turnOn('none');
    await boot(ports[0]);
    await c.turnOff();
    expect(routes.at(-1)).toBeNull();
    expect(privacy.at(-1)).toBe(false);
    expect(saved.at(-1)).toEqual({ enabled: false, bridge: 'none' });
    expect(ports[0].disconnected).toBe(true);
  });

  it('keeps traffic blocked when the helper dies', async () => {
    const { c, ports, routes } = setup({ lastError: 'Native host has exited.' });
    await c.turnOn('none');
    await boot(ports[0]);
    ports[0].die();
    await flush();
    expect(c.current).toMatchObject({ phase: 'failed', error: 'Native host has exited.', helperMissing: false });
    expect(routes.at(-1)).toBe(BLACKHOLE_PORT);
  });

  it('reports a missing helper', async () => {
    const { c, ports } = setup({ lastError: 'Specified native messaging host not found.' });
    await c.turnOn('none');
    ports[0].die();
    await flush();
    await flush();
    expect(c.current).toMatchObject({ phase: 'failed', helperMissing: true, error: HELPER_MISSING });
  });

  it('asks to update an older helper', async () => {
    const { c, ports } = setup();
    await c.turnOn('none');
    await flush();
    ports[0].emit({ id: ports[0].idOf('hello'), type: 'error', payload: { code: 'protocol_mismatch', message: 'helper speaks protocol 2, extension 1' } });
    await flush();
    await flush();
    expect(c.current.phase).toBe('failed');
    expect(c.current.error).toMatch(/^Update the Tortuga helper/);
  });

  it('Chrome without incognito access fails before starting the helper', async () => {
    const { c, ports } = setup({ incognito: false });
    await c.turnOn('none');
    expect(ports).toEqual([]);
    expect(c.current).toMatchObject({ phase: 'failed', error: INCOGNITO_NEEDED });
  });

  it('stores circuits and asks for new ones', async () => {
    const { c, ports } = setup();
    await c.turnOn('none');
    await boot(ports[0]);
    ports[0].emit({ type: 'circuit', payload: { site: 'github.com', bridge: null, hops: [{ role: 'guard', id: 'g', addr: '192.0.2.1', country: 'DE' }] } });
    await flush();
    expect(c.current.circuits['github.com'].hops[0].id).toBe('g');
    const renewed = c.newCircuit('github.com');
    await flush();
    ports[0].emit({ id: ports[0].idOf('tor.newCircuit'), type: 'ok' });
    await renewed;
    expect(ports[0].sent.at(-1)).toMatchObject({ type: 'tor.newCircuit', payload: { site: 'github.com' } });
  });

  it('a reply to an older start does not turn Tor on', async () => {
    const { c, ports } = setup();
    await c.turnOn('none');
    await flush();
    await c.turnOff();
    ports[0].emit({ id: ports[0].idOf('hello'), type: 'hello', payload: { protocol: 1, version: '0.1.0' } });
    await flush();
    expect(c.current.phase).toBe('off');
  });
});
```

Run: `cd extension && npx vitest run tests/state.test.ts tests/controller.test.ts`
Expected: FAIL (`stage` / `helperVersion` undefined, `chooseBridge is not a function`).

- [ ] **Step 2: Implement**

`extension/src/lib/protocol.ts`:

```ts
// The helper's messages (helper/tortuga-helper/src/protocol.rs), as the
// extension sees them. Keep PROTOCOL_VERSION equal to the helper's.

export const PROTOCOL_VERSION = 1;
/** Native messaging host name, registered by the helper's installer. */
export const HOST_NAME = 'org.tortuga.helper';

export type BridgeKind = 'none' | 'snowflake' | 'obfs4' | 'webtunnel';
export type Role = 'guard' | 'bridge' | 'middle' | 'exit';

export interface Hop {
  role: Role;
  id: string;
  /** The relay's address; a Snowflake bridge's is a placeholder. */
  addr: string | null;
  country: string | null;
}

/** Bootstrap stage reported by `tor.status`. */
export type Stage = 'bridge' | 'directory' | 'ready';

export interface Circuit {
  site: string;
  bridge: Exclude<BridgeKind, 'none'> | null;
  hops: Hop[];
}

export type ErrorCode = 'bad_request' | 'hello_required' | 'protocol_mismatch' | 'tor_failed' | 'not_running';

/** Anything the helper sends: a reply (with id) or an event (without). */
export type HelperMessage =
  | { id?: number; type: 'hello'; payload: { protocol: number; version: string } }
  | { id?: number; type: 'ok' }
  | { id?: number; type: 'tor.status'; payload: { phase: Stage; percent: number; blocked: string | null } }
  | { id?: number; type: 'tor.ready'; payload: { socksPort: number } }
  | { id?: number; type: 'circuit'; payload: Circuit }
  | { id?: number; type: 'error'; payload: { code: ErrorCode; message: string } };

/** What the extension asks the helper. */
export type HelperRequest =
  | { type: 'hello'; payload: { protocol: number } }
  | { type: 'tor.start'; payload: { bridge: { kind: BridgeKind; lines?: string[] } } }
  | { type: 'tor.stop' }
  | { type: 'tor.newCircuit'; payload: { site: string } };
```

`extension/src/lib/state.ts`:

```ts
import type { BridgeKind, Circuit, Stage } from './protocol';

/**
 * off: Tortuga does nothing. connecting / failed: traffic that would go
 * through Tor is blocked. on: traffic goes through the helper's SOCKS port.
 */
export type Phase = 'off' | 'connecting' | 'on' | 'failed';

export interface TorState {
  phase: Phase;
  bridge: BridgeKind;
  percent: number;
  /** Last bootstrap stage while connecting; drives the connecting diagram. */
  stage: Stage | null;
  /** Arti's reason when it thinks bootstrap is stuck. */
  blocked: string | null;
  socksPort: number | null;
  error: string | null;
  /** The helper isn't installed (or not registered for this browser). */
  helperMissing: boolean;
  /** The helper's version, from its hello reply. */
  helperVersion: string | null;
  /** Last circuit per site. */
  circuits: Record<string, Circuit>;
}

export type TorEvent =
  | { type: 'turnOn'; bridge: BridgeKind }
  | { type: 'turnOff' }
  | { type: 'choose'; bridge: BridgeKind }
  | { type: 'hello'; version: string }
  | { type: 'status'; stage: Stage; percent: number; blocked: string | null }
  | { type: 'ready'; socksPort: number }
  | { type: 'circuit'; circuit: Circuit }
  | { type: 'failed'; error: string; helperMissing?: boolean };

export function initialState(bridge: BridgeKind = 'none'): TorState {
  return { phase: 'off', bridge, percent: 0, stage: null, blocked: null, socksPort: null, error: null, helperMissing: false, helperVersion: null, circuits: {} };
}

export function reduce(s: TorState, e: TorEvent): TorState {
  switch (e.type) {
    case 'turnOn':
      return { ...initialState(e.bridge), phase: 'connecting', helperVersion: s.helperVersion };
    case 'turnOff':
      return { ...initialState(s.bridge), helperVersion: s.helperVersion };
    case 'choose':
      return s.phase === 'off' ? { ...s, bridge: e.bridge } : s;
    case 'hello':
      return { ...s, helperVersion: e.version };
    case 'status':
      return s.phase === 'connecting' ? { ...s, stage: e.stage, percent: e.percent, blocked: e.blocked } : s;
    case 'ready':
      return s.phase === 'connecting' ? { ...s, phase: 'on', percent: 100, stage: 'ready', blocked: null, socksPort: e.socksPort } : s;
    case 'circuit':
      return s.phase === 'on' ? { ...s, circuits: { ...s.circuits, [e.circuit.site]: e.circuit } } : s;
    case 'failed':
      return {
        ...s,
        phase: s.phase === 'off' ? 'off' : 'failed',
        socksPort: null,
        error: e.error,
        helperMissing: e.helperMissing ?? false,
      };
  }
}

/**
 * Nothing listens on TCP port 1 on desktop systems, so a proxy pointing there
 * makes every request fail at once: the way to block traffic while Tor isn't
 * ready, without letting it out directly.
 */
export const BLACKHOLE_PORT = 1;

/** Where traffic goes: null = the browser's own setting (Tortuga off). */
export function routedPort(s: TorState): number | null {
  if (s.phase === 'off') return null;
  if (s.phase === 'on' && s.socksPort !== null) return s.socksPort;
  return BLACKHOLE_PORT;
}
```

`extension/src/lib/messages.ts`:

```ts
import type { BridgeKind } from './protocol';
import type { TorState } from './state';

/** Popup → background. Each is answered with the current TorState. */
export type BgMessage =
  | { type: 'GET_STATE' }
  | { type: 'TOR_ON'; bridge: BridgeKind }
  | { type: 'TOR_OFF' }
  | { type: 'SET_BRIDGE'; bridge: BridgeKind }
  | { type: 'NEW_CIRCUIT'; site: string };

/** Background → popup, after every change. */
export type BgBroadcast = { type: 'STATE'; state: TorState };

/** What survives the background being restarted. */
export interface Stored {
  enabled: boolean;
  bridge: BridgeKind;
}

/** Bridge lines the user saved on the settings page, per transport. */
export interface BridgeLines {
  obfs4: string[];
  webtunnel: string[];
}

export const LINES_KEY = 'tortugaBridgeLines';
export const NO_LINES: BridgeLines = { obfs4: [], webtunnel: [] };

export const STORAGE_KEY = 'tortuga';
```

`extension/src/background/controller.ts`:

```ts
import type { BridgeKind, HelperMessage } from '../lib/protocol';
import { PROTOCOL_VERSION } from '../lib/protocol';
import type { Stored } from '../lib/messages';
import { initialState, reduce, routedPort, type TorEvent, type TorState } from '../lib/state';
import { HelperError, isMissingHost, type HelperClient } from './helper';

/** Everything the controller does to the outside world (fakes in tests). */
export interface Deps {
  connect(onEvent: (m: HelperMessage) => void, onGone: (reason: string) => void): HelperClient;
  applyRoute(port: number | null): Promise<void>;
  applyPrivacy(on: boolean): Promise<void>;
  save(stored: Stored): Promise<void>;
  broadcast(state: TorState): void;
  /** Chrome: may Tortuga touch incognito windows? Firefox: always true. */
  incognitoAllowed(): Promise<boolean>;
}

export const INCOGNITO_NEEDED = 'Allow Tortuga in Incognito (Manage extension → Allow in Incognito), then try again.';
export const HELPER_MISSING = 'The Tortuga helper is not installed.';

/**
 * Owns the Tor state. Every change goes through `commit`, which applies the
 * route and privacy settings only when they change. Changes are serialized.
 */
export class Controller {
  private state: TorState = initialState();
  private helper: HelperClient | null = null;
  private appliedPort: number | null = null;
  private privacyOn = false;
  private queue: Promise<unknown> = Promise.resolve();
  /** Bumped on every turn on / off, so a stale start can't overwrite a newer one. */
  private generation = 0;

  constructor(private readonly deps: Deps) {}

  get current(): TorState {
    return this.state;
  }

  /** The SOCKS port traffic goes to right now (null: browser's own setting). */
  get port(): number | null {
    return routedPort(this.state);
  }

  /** `lines`: bridge lines for obfs4 / WebTunnel (Snowflake uses the bundled defaults). */
  turnOn(bridge: BridgeKind, lines: string[] = []): Promise<TorState> {
    return this.serial(async () => {
      const gen = ++this.generation;
      this.helper?.close();
      this.helper = null;
      await this.commit({ type: 'turnOn', bridge });
      await this.deps.save({ enabled: true, bridge });
      if (!(await this.deps.incognitoAllowed())) {
        await this.commit({ type: 'failed', error: INCOGNITO_NEEDED });
        return this.state;
      }
      const helper = this.deps.connect(
        m => void this.serial(() => this.onEvent(m)),
        reason => void this.serial(() => this.onGone(helper, reason)),
      );
      this.helper = helper;
      void this.start(helper, bridge, lines, gen);
      return this.state;
    });
  }

  turnOff(): Promise<TorState> {
    return this.serial(async () => {
      this.generation++;
      this.helper?.close();
      this.helper = null;
      await this.commit({ type: 'turnOff' });
      await this.deps.save({ enabled: false, bridge: this.state.bridge });
      return this.state;
    });
  }

  /** Pick a bridge: remembered while off, applied by restarting Tor while on. */
  chooseBridge(bridge: BridgeKind, lines: string[] = []): Promise<TorState> {
    if (this.state.phase !== 'off') return this.turnOn(bridge, lines);
    return this.serial(async () => {
      await this.commit({ type: 'choose', bridge });
      await this.deps.save({ enabled: false, bridge });
      return this.state;
    });
  }

  newCircuit(site: string): Promise<TorState> {
    return this.serial(async () => {
      if (this.state.phase === 'on' && this.helper) {
        await this.helper.request({ type: 'tor.newCircuit', payload: { site } }).catch(() => undefined);
      }
      return this.state;
    });
  }

  private async start(helper: HelperClient, bridge: BridgeKind, lines: string[], gen: number): Promise<void> {
    try {
      const hello = await helper.request({ type: 'hello', payload: { protocol: PROTOCOL_VERSION } });
      if (hello.type === 'hello') {
        await this.serial(async () => {
          if (gen === this.generation) await this.commit({ type: 'hello', version: hello.payload.version });
        });
      }
      const kind = { kind: bridge, ...(lines.length ? { lines } : {}) };
      const reply = await helper.request({ type: 'tor.start', payload: { bridge: kind } });
      if (reply.type !== 'tor.ready') throw new Error(`unexpected reply ${reply.type}`);
      await this.serial(async () => {
        if (gen === this.generation) await this.commit({ type: 'ready', socksPort: reply.payload.socksPort });
      });
    } catch (e) {
      await this.serial(async () => {
        if (gen !== this.generation) return;
        const err = e as Error;
        const missing = isMissingHost(err.message);
        const message = missing
          ? HELPER_MISSING
          : err instanceof HelperError && err.code === 'protocol_mismatch'
            ? `Update the Tortuga helper: ${err.message}`
            : err.message;
        await this.commit({ type: 'failed', error: message, helperMissing: missing });
      });
    }
  }

  private async onEvent(m: HelperMessage): Promise<void> {
    if (m.type === 'tor.status') {
      await this.commit({ type: 'status', stage: m.payload.phase, percent: m.payload.percent, blocked: m.payload.blocked });
    }
    else if (m.type === 'circuit') await this.commit({ type: 'circuit', circuit: m.payload });
  }

  private async onGone(helper: HelperClient, reason: string): Promise<void> {
    if (helper !== this.helper) return;
    this.helper = null;
    const missing = isMissingHost(reason);
    await this.commit({ type: 'failed', error: missing ? HELPER_MISSING : reason, helperMissing: missing });
  }

  private async commit(e: TorEvent): Promise<void> {
    this.state = reduce(this.state, e);
    const port = routedPort(this.state);
    if (port !== this.appliedPort) {
      await this.deps.applyRoute(port);
      this.appliedPort = port;
    }
    const privacy = this.state.phase !== 'off';
    if (privacy !== this.privacyOn) {
      await this.deps.applyPrivacy(privacy);
      this.privacyOn = privacy;
    }
    this.deps.broadcast(this.state);
  }

  private serial<T>(fn: () => Promise<T>): Promise<T> {
    const next = this.queue.then(fn, fn);
    this.queue = next.catch(() => undefined);
    return next;
  }
}
```

- [ ] **Step 3: Run the tests**

Run: `cd extension && npx vitest run tests/state.test.ts tests/controller.test.ts`
Expected: `11 passed` and `11 passed`.

- [ ] **Step 4: Commit**

```bash
git add extension/src extension/tests
git commit -m "extension: bootstrap stage, helper version, chosen bridge, bridge lines"
```

---

### Task 3: Non-web pages have no site

**Files:**
- Modify: `extension/src/lib/site.ts`
- Test: `extension/tests/site.test.ts`

- [ ] **Step 1: Write the test**

`extension/tests/site.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { DEFAULT_SITE, siteOf, topSiteOf } from '../src/lib/site';

describe('siteOf', () => {
  it('reduces a host to its registrable domain', () => {
    expect(siteOf('https://api.github.com/repos')).toBe('github.com');
    expect(siteOf('https://www.bbc.co.uk/news')).toBe('bbc.co.uk');
  });

  it('keeps private suffixes apart', () => {
    expect(siteOf('https://alice.github.io/')).toBe('alice.github.io');
  });

  it('keeps WebSocket hosts', () => {
    expect(siteOf('wss://ws.example.co.uk/socket')).toBe('example.co.uk');
  });

  it('uses the bare host for IPs and single labels', () => {
    expect(siteOf('http://192.168.1.1/')).toBe('192.168.1.1');
    expect(siteOf('http://[::1]:8080/')).toBe('::1');
    expect(siteOf('http://localhost:3000/')).toBe('localhost');
  });

  it('falls back to the default site', () => {
    expect(siteOf(undefined)).toBe(DEFAULT_SITE);
    expect(siteOf('not a url')).toBe(DEFAULT_SITE);
    expect(siteOf('about:blank')).toBe(DEFAULT_SITE);
    expect(siteOf('moz-extension://2d73f80d-c4aa-4b8b/popup.html')).toBe(DEFAULT_SITE);
    expect(siteOf('chrome://newtab/')).toBe(DEFAULT_SITE);
  });
});

describe('topSiteOf', () => {
  const base = { requestId: '1', tabId: 1 };

  it('uses the top-level frame for subresources in iframes', () => {
    expect(topSiteOf({
      ...base, type: 'script', url: 'https://cdn.example.net/a.js', documentUrl: 'https://ads.tracker.com/frame',
      frameAncestors: [{ url: 'https://ads.tracker.com/frame', frameId: 5 }, { url: 'https://news.ycombinator.com/', frameId: 0 }],
    })).toBe('ycombinator.com');
  });

  it('uses the request itself for a page load', () => {
    expect(topSiteOf({ ...base, type: 'main_frame', url: 'https://en.wikipedia.org/wiki/Tor' })).toBe('wikipedia.org');
  });

  it('uses the document for a top-level page subresource', () => {
    expect(topSiteOf({ ...base, type: 'image', url: 'https://i.imgur.com/x.png', documentUrl: 'https://www.reddit.com/' })).toBe('reddit.com');
  });
});
```

Run: `cd extension && npx vitest run tests/site.test.ts`
Expected: FAIL — `moz-extension://…` gives `2d73f80d-c4aa-4b8b` instead of `default`.

- [ ] **Step 2: Implement**

`extension/src/lib/site.ts`:

```ts
import { getDomain } from 'tldts';

/** The circuit key Chrome uses: it can't tell sites apart (no SOCKS login). */
export const DEFAULT_SITE = 'default';

/**
 * The registrable domain of `url` ("github.com" for "https://api.github.com/x"),
 * or the bare host for IPs and single-label names, or DEFAULT_SITE for
 * anything that isn't a web address (about:, extension pages, files).
 */
export function siteOf(url: string | undefined): string {
  if (!url) return DEFAULT_SITE;
  let host: string;
  try {
    const u = new URL(url);
    if (!/^(https?|wss?):$/.test(u.protocol)) return DEFAULT_SITE;
    host = u.hostname;
  } catch {
    return DEFAULT_SITE;
  }
  if (!host) return DEFAULT_SITE;
  return getDomain(host, { allowPrivateDomains: true }) ?? host.replace(/^\[|\]$/g, '');
}

/** The site of the top-level page a Firefox request belongs to. */
export function topSiteOf(details: chrome.proxy.FirefoxRequestDetails): string {
  const ancestors = details.frameAncestors;
  if (ancestors && ancestors.length > 0) return siteOf(ancestors[ancestors.length - 1].url);
  if (details.type === 'main_frame') return siteOf(details.url);
  return siteOf(details.documentUrl ?? details.url);
}
```

Run: `cd extension && npx vitest run tests/site.test.ts`
Expected: `8 passed`

- [ ] **Step 3: Commit**

```bash
git add extension/src/lib/site.ts extension/tests/site.test.ts
git commit -m "extension: only web addresses are sites"
```

---

### Task 4: Bridge lines

**Files:**
- Create: `extension/src/lib/bridges.ts`
- Test: `extension/tests/bridges.test.ts`

**Interfaces:**
- Produces: `parseLines(kind: 'obfs4' | 'webtunnel', text): { lines: string[]; errors: string[] }`; `bridgeReady(kind, saved): boolean`; `linesFor(kind, saved): string[]`.

- [ ] **Step 1: Write the failing test**

`extension/tests/bridges.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { bridgeReady, linesFor, parseLines } from '../src/lib/bridges';
import { NO_LINES } from '../src/lib/messages';

const OBFS4 = 'obfs4 192.0.2.55:38114 316E643333645F6D79216558614D3931657A5F5F cert=YXJlIGZyZXF1ZW50bHkgZnVsbA iat-mode=0';
const WEBTUNNEL = 'webtunnel [2001:db8::1]:443 8838024498816A039FCBBAB14E6F40A0843051FA url=https://example.org/path ver=0.0.1';

describe('parseLines', () => {
  it('accepts lines with or without "Bridge" and normalises them', () => {
    const text = `# from bridges.torproject.org\n${OBFS4}\n\nBridge ${OBFS4}\n`;
    expect(parseLines('obfs4', text)).toEqual({ lines: [`Bridge ${OBFS4}`, `Bridge ${OBFS4}`], errors: [] });
  });

  it('accepts WebTunnel lines with IPv6 addresses', () => {
    expect(parseLines('webtunnel', WEBTUNNEL)).toEqual({ lines: [`Bridge ${WEBTUNNEL}`], errors: [] });
  });

  it('names the line and the problem', () => {
    const { lines, errors } = parseLines('obfs4', `${WEBTUNNEL}\nobfs4 nowhere\nobfs4 192.0.2.1:443 notafingerprint`);
    expect(lines).toEqual([]);
    expect(errors).toEqual([
      'Line 1: starts with “webtunnel”, expected “obfs4”',
      'Line 2: no address:port after “obfs4”',
      'Line 3: no 40-character fingerprint after the address',
    ]);
  });
});

describe('bridgeReady / linesFor', () => {
  const saved = { ...NO_LINES, obfs4: [`Bridge ${OBFS4}`] };

  it('needs saved lines only for obfs4 and WebTunnel', () => {
    expect(bridgeReady('none', NO_LINES)).toBe(true);
    expect(bridgeReady('snowflake', NO_LINES)).toBe(true);
    expect(bridgeReady('obfs4', NO_LINES)).toBe(false);
    expect(bridgeReady('obfs4', saved)).toBe(true);
    expect(bridgeReady('webtunnel', saved)).toBe(false);
  });

  it('sends lines only for the transports that need them', () => {
    expect(linesFor('obfs4', saved)).toEqual([`Bridge ${OBFS4}`]);
    expect(linesFor('snowflake', saved)).toEqual([]);
  });
});
```

Run: `cd extension && npx vitest run tests/bridges.test.ts`
Expected: FAIL — `Failed to load url ../src/lib/bridges`.

- [ ] **Step 2: Implement**

`extension/src/lib/bridges.ts`:

```ts
import type { BridgeLines } from './messages';
import type { BridgeKind } from './protocol';

export type LineKind = keyof BridgeLines;

const ADDR = /^(\[[0-9a-f:]+\]|[0-9.]+|[a-z0-9.-]+):\d{1,5}$/i;
const FINGERPRINT = /^[0-9A-F]{40}$/i;

/**
 * Bridge lines pasted on the settings page, as from bridges.torproject.org:
 * `obfs4 1.2.3.4:443 <40 hex> cert=… iat-mode=0`, with or without a leading
 * `Bridge`. Blank lines and `#` comments are skipped. Lines come back as
 * `Bridge …`, the form the helper parses.
 */
export function parseLines(kind: LineKind, text: string): { lines: string[]; errors: string[] } {
  const lines: string[] = [];
  const errors: string[] = [];
  text.split('\n').forEach((raw, i) => {
    const line = raw.trim().replace(/^Bridge\s+/i, '');
    if (!line || line.startsWith('#')) return;
    const [transport, addr, fingerprint] = line.split(/\s+/);
    const where = `Line ${i + 1}`;
    if (transport !== kind) errors.push(`${where}: starts with “${transport}”, expected “${kind}”`);
    else if (!addr || !ADDR.test(addr)) errors.push(`${where}: no address:port after “${kind}”`);
    else if (!fingerprint || !FINGERPRINT.test(fingerprint)) errors.push(`${where}: no 40-character fingerprint after the address`);
    else lines.push(`Bridge ${line}`);
  });
  return { lines, errors };
}

/** Can Tor start with this bridge kind? obfs4 and WebTunnel need saved lines. */
export function bridgeReady(kind: BridgeKind, saved: BridgeLines): boolean {
  return kind === 'none' || kind === 'snowflake' || saved[kind].length > 0;
}

/** The lines to send to the helper for `kind` (Snowflake uses the helper's defaults). */
export function linesFor(kind: BridgeKind, saved: BridgeLines): string[] {
  return kind === 'obfs4' || kind === 'webtunnel' ? saved[kind] : [];
}
```

Run: `cd extension && npx vitest run tests/bridges.test.ts`
Expected: `5 passed`

- [ ] **Step 3: Commit**

```bash
git add extension/src/lib/bridges.ts extension/tests/bridges.test.ts
git commit -m "extension: parse and check pasted bridge lines"
```

---

### Task 5: Metro diagram and its preview page

**Files:**
- Create: `extension/src/lib/flags.ts`, `extension/src/popup/metro.ts`, `extension/dev/index.html`, `extension/dev/preview.ts`, `extension/vite.config.preview.ts`
- Copy from Nomada: `extension/public/fonts/TwemojiCountryFlags.woff2`, `extension/public/fonts/LICENSE.md`, `extension/src/styles/flags.css`
- Modify: `extension/package.json`, `extension/tsconfig.json`, `extension/.gitignore`
- Test: `extension/tests/metro.test.ts`

**Interfaces:**
- Produces: `flagEmoji(code)`; `WIDTH`, `HEIGHT`, `LINE_Y`, `SITE_CHARS = 12`; types `Station`, `Segment`, `MetroModel`, `MetroInput { bridge, site, hops, stage, connecting }`; `shortSite(site)`, `layoutMetro(input): MetroModel`, `renderMetro(svg, model)`.

- [ ] **Step 1: Copy the flag font**

Run: `mkdir -p extension/public/fonts && cp ../nomada/public/fonts/* extension/public/fonts/ && cp ../nomada/src/styles/flags.css extension/src/styles/`

- [ ] **Step 2: Write the failing test**

`extension/tests/metro.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { layoutMetro, type MetroInput } from '../src/popup/metro';
import type { Hop } from '../src/lib/protocol';

const hops: Hop[] = [
  { role: 'bridge', id: 'bridgeid1', addr: '192.0.2.3', country: null },
  { role: 'middle', id: 'middleid', addr: '176.123.3.35', country: 'MD' },
  { role: 'exit', id: 'exitid', addr: '185.220.101.3', country: 'DE' },
];
const on: MetroInput = { bridge: 'snowflake', site: 'github.com', hops, stage: 'ready', connecting: false };

describe('layoutMetro', () => {
  it('draws five stations, the bridge as its transport', () => {
    const { stations } = layoutMetro(on);
    expect(stations.map(s => s.label)).toEqual(['You', 'Bridge', 'Middle', 'Exit', 'github.com']);
    expect(stations[1]).toMatchObject({ kind: 'bridge', sub: 'Snowflake', flag: '' });
    expect(stations[3]).toMatchObject({ sub: 'DE', flag: '🇩🇪' });
    expect(stations.every(s => s.lit)).toBe(true);
  });

  it('styles only the segment the bridge covers', () => {
    expect(layoutMetro(on).segments.map(s => s.style)).toEqual(['snowflake', 'plain', 'plain', 'plain']);
    expect(layoutMetro({ ...on, bridge: 'obfs4' }).segments[0].style).toBe('obfs4');
    expect(layoutMetro({ ...on, bridge: 'none', hops: [{ ...hops[0], role: 'guard', country: 'US' }, hops[1], hops[2]] }).segments[0].style).toBe('plain');
  });

  it('without a bridge the first station is the guard with its flag', () => {
    const s = layoutMetro({ ...on, bridge: 'none', hops: [{ ...hops[0], role: 'guard', country: 'US' }, hops[1], hops[2]] }).stations[1];
    expect(s).toMatchObject({ kind: 'relay', label: 'Guard', sub: 'US', flag: '🇺🇸' });
  });

  it('keys stations by relay, so a new circuit changes the keys', () => {
    const a = layoutMetro(on).stations.map(s => s.key);
    const b = layoutMetro({ ...on, hops: [hops[0], hops[1], { ...hops[2], id: 'otherexit' }] }).stations.map(s => s.key);
    expect(a.filter((k, i) => k !== b[i])).toEqual(['exit:exitid']);
  });

  it('lights up step by step while connecting', () => {
    const connecting = { ...on, hops: null, connecting: true };
    const first = layoutMetro({ ...connecting, stage: 'bridge' });
    expect(first.stations.map(s => s.lit)).toEqual([true, false, false, false, false]);
    expect(first.segments.map(s => s.pending)).toEqual([true, false, false, false]);
    const dir = layoutMetro({ ...connecting, stage: 'directory' });
    expect(dir.stations.map(s => s.lit)).toEqual([true, true, false, false, false]);
    expect(dir.segments.map(s => [s.lit, s.pending])).toEqual([[true, false], [false, true], [false, false], [false, false]]);
    expect(dir.stations[2].sub).toBe('…');
  });

  it('shortens long site names to fit the end of the line', () => {
    const label = (site: string) => layoutMetro({ ...on, site }).stations[4];
    expect(label('github.com')).toMatchObject({ label: 'github.com', title: 'github.com' });
    expect(label('wikipedia.org')).toMatchObject({ label: 'wikipedia', title: 'wikipedia.org' });
    expect(label('ycombinator.com').label).toBe('ycombinator');
    expect(label('averyveryverylongname.org').label).toBe('averyveryve…');
  });

  it('calls Chrome’s shared circuit Incognito', () => {
    expect(layoutMetro({ ...on, site: 'default' }).stations[4].label).toBe('Incognito');
  });
});
```

Run: `cd extension && npx vitest run tests/metro.test.ts`
Expected: FAIL — `Failed to load url ../src/popup/metro`.

- [ ] **Step 3: Implement**

`extension/src/lib/flags.ts`:

```ts
// Flags are emoji drawn with a bundled font (src/styles/flags.css): Windows has
// no flag emoji of its own. Twemoji, CC-BY 4.0 — see public/fonts/LICENSE.md.
// From Nomada's src/lib/flags.ts.

/** The flag emoji for an ISO 3166-1 alpha-2 code, or '' for anything else. */
export function flagEmoji(code: string | null | undefined): string {
  const c = (code ?? '').toUpperCase();
  return /^[A-Z]{2}$/.test(c) ? String.fromCodePoint(...[...c].map(ch => 0x1f1e6 + ch.charCodeAt(0) - 65)) : '';
}
```

`extension/src/popup/metro.ts`:

```ts
// The route as a metro line: You → bridge or guard → middle → exit → site.
// layoutMetro() decides what is drawn (pure, tested); renderMetro() draws it
// as SVG. Colours come from CSS classes in style.css.

import { flagEmoji } from '../lib/flags';
import type { BridgeKind, Hop, Stage } from '../lib/protocol';
import { DEFAULT_SITE } from '../lib/site';

export const WIDTH = 312;
export const HEIGHT = 92;
export const LINE_Y = 34;
const STEP = 68;
export const SITE_CHARS = 12;
const X0 = 20;

export type SegmentStyle = 'plain' | 'snowflake' | 'obfs4' | 'webtunnel';

export interface Station {
  /** Stays the same while the same relay holds the place, so a change animates. */
  key: string;
  kind: 'you' | 'relay' | 'bridge' | 'site';
  /** Full text for the tooltip. */
  title: string;
  x: number;
  label: string;
  sub: string;
  flag: string;
  lit: boolean;
}

export interface Segment {
  x1: number;
  x2: number;
  style: SegmentStyle;
  lit: boolean;
  /** The step that is happening now while connecting. */
  pending: boolean;
}

export interface MetroModel {
  stations: Station[];
  segments: Segment[];
}

export interface MetroInput {
  bridge: BridgeKind;
  site: string;
  /** The site's circuit, or null before one is known. */
  hops: Hop[] | null;
  /** null: off. While connecting, the last bootstrap stage. */
  stage: Stage | null;
  connecting: boolean;
}

/** The end station without a site: Chrome's shared incognito circuit, or a tab that isn't a web page. */
const DEFAULT_LABEL = {
  chrome: { label: 'Incognito', title: 'Incognito windows' },
  firefox: { label: 'No site', title: 'This tab isn’t a web page' },
} as const;

const BRIDGE_NAMES: Record<BridgeKind, string> = { none: 'No bridge', snowflake: 'Snowflake', obfs4: 'obfs4', webtunnel: 'WebTunnel' };

function short(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

/** A site name that fits: whole, else without its last label ("wikipedia"), else cut. */
export function shortSite(site: string): string {
  if (site.length <= SITE_CHARS) return site;
  const name = site.slice(0, site.lastIndexOf('.'));
  return name && name.length <= SITE_CHARS ? name : short(site, SITE_CHARS);
}

/** How many stations are lit, and which segment is pending, for a stage. */
function progress(input: MetroInput): { lit: number; pending: number | null } {
  if (!input.connecting) return { lit: 5, pending: null };
  if (input.stage === 'directory') return { lit: 2, pending: 1 };
  if (input.stage === 'ready') return { lit: 5, pending: null };
  return { lit: 1, pending: 0 };
}

export function layoutMetro(input: MetroInput): MetroModel {
  const { lit, pending } = progress(input);
  const [first, middle, exit] = input.hops ?? [];
  const viaBridge = input.bridge !== 'none';
  const relay = (h: Hop | undefined, role: string, fallback: string) => ({
    key: h ? `${role}:${h.id}` : role,
    title: h ? `${fallback} ${h.addr ?? ''} ${h.country ?? ''} ${h.id}`.replace(/\s+/g, ' ').trim() : fallback,
    label: fallback,
    sub: h ? (h.country ?? short(h.id, 8)) : '…',
    flag: flagEmoji(h?.country),
  });

  const stations: Omit<Station, 'x' | 'lit'>[] = [
    { key: 'you', kind: 'you', title: 'You — sites don’t see your IP', label: 'You', sub: 'hidden', flag: '' },
    viaBridge
      ? { key: first ? `bridge:${first.id}` : 'bridge', kind: 'bridge', title: `${BRIDGE_NAMES[input.bridge]} bridge`, label: 'Bridge', sub: BRIDGE_NAMES[input.bridge], flag: '' }
      : { ...relay(first, 'guard', 'Guard'), kind: 'relay' },
    { ...relay(middle, 'middle', 'Middle'), kind: 'relay' },
    { ...relay(exit, 'exit', 'Exit'), kind: 'relay' },
    // The site's name sits above the end of the line, right-aligned, where
    // no flag is drawn; 12 characters fit without reaching the exit's flag.
    input.site === DEFAULT_SITE
      ? { key: 'site:default', kind: 'site', ...DEFAULT_LABEL[__TARGET__], sub: '', flag: '' }
      : { key: `site:${input.site}`, kind: 'site', title: input.site, label: shortSite(input.site), sub: '', flag: '' },
  ];

  return {
    stations: stations.map((s, i) => ({ ...s, x: X0 + i * STEP, lit: i < lit })),
    segments: [0, 1, 2, 3].map(i => ({
      x1: X0 + i * STEP,
      x2: X0 + (i + 1) * STEP,
      style: i === 0 && viaBridge ? (input.bridge as SegmentStyle) : 'plain',
      lit: i < lit - 1,
      pending: i === pending,
    })),
  };
}

const NS = 'http://www.w3.org/2000/svg';

function el<K extends keyof SVGElementTagNameMap>(tag: K, attrs: Record<string, string | number>, text?: string): SVGElementTagNameMap[K] {
  const node = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, String(v));
  if (text !== undefined) node.textContent = text;
  return node;
}

function segmentNode(s: Segment): SVGGElement {
  const g = el('g', { class: `seg seg-${s.style}${s.lit ? ' lit' : ''}${s.pending ? ' pending' : ''}` });
  const y = LINE_Y;
  if (s.style === 'obfs4') {
    const n = 6;
    const w = (s.x2 - s.x1) / n;
    let d = `M${s.x1} ${y}`;
    for (let i = 0; i < n; i++) d += ` q${w / 2} ${i % 2 ? 7 : -7} ${w} 0`;
    g.append(el('path', { d, class: 'stroke' }));
  } else if (s.style === 'webtunnel') {
    g.append(el('rect', { x: s.x1, y: y - 7, width: s.x2 - s.x1, height: 14, rx: 7, class: 'tube' }));
    g.append(el('line', { x1: s.x1, y1: y, x2: s.x2, y2: y, class: 'stroke thin' }));
  } else {
    g.append(el('line', { x1: s.x1, y1: y, x2: s.x2, y2: y, class: 'stroke' }));
  }
  return g;
}

function stationNode(s: Station, entering: boolean): SVGGElement {
  // The outer group places the station; the inner one is what animates, so a
  // CSS transform never fights the placement.
  const g = el('g', { class: `st st-${s.kind}${s.lit ? ' lit' : ''}${entering ? ' enter' : ''}`, transform: `translate(${s.x} 0)` });
  const inner = el('g', { class: 'in' });
  inner.append(el('title', {}, s.title));
  if (s.kind === 'bridge') inner.append(el('rect', { x: -10, y: LINE_Y - 10, width: 20, height: 20, rx: 6, class: 'dot' }));
  else if (s.kind === 'site') inner.append(el('circle', { cx: 0, cy: LINE_Y, r: 10, class: 'dot' }));
  else inner.append(el('circle', { cx: 0, cy: LINE_Y, r: 8, class: 'dot' }));
  if (s.flag) inner.append(el('text', { x: 0, y: 14, class: 'flag-emoji' }, s.flag));
  inner.append(s.kind === 'site'
    ? el('text', { x: 11, y: 14, class: 'label site-label' }, s.label)
    : el('text', { x: 0, y: 66, class: 'label' }, s.label));
  if (s.sub) inner.append(el('text', { x: 0, y: 80, class: 'sub' }, s.sub));
  g.append(inner);
  return g;
}

/** Draw `model` into `svg`; stations whose relay changed since the last draw animate in. */
export function renderMetro(svg: SVGSVGElement, model: MetroModel): void {
  const before = new Set((svg.dataset.keys ?? '').split('|').filter(Boolean));
  const firstDraw = before.size === 0;
  svg.setAttribute('viewBox', `0 0 ${WIDTH} ${HEIGHT}`);
  svg.replaceChildren(
    ...model.segments.map(segmentNode),
    ...model.stations.map(s => stationNode(s, !firstDraw && !before.has(s.key))),
  );
  svg.dataset.keys = model.stations.map(s => s.key).join('|');
}
```

Run: `cd extension && npx vitest run tests/metro.test.ts`
Expected: `7 passed`

- [ ] **Step 4: Preview page and build files**

`extension/vite.config.preview.ts`:

```ts
import { defineConfig } from 'vite';
import { resolve } from 'path';

// A page that draws the metro diagram in every state, for design work:
//   npm run preview:metro && npx vite preview --config vite.config.preview.ts
export default defineConfig({
  define: { __TARGET__: JSON.stringify('firefox') },
  root: resolve(__dirname, 'dev'),
  publicDir: resolve(__dirname, 'public'),
  build: { outDir: resolve(__dirname, 'dist-preview'), emptyOutDir: true },
  preview: { port: 4174 },
});
```

`extension/dev/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Tortuga metro preview</title>
  <link rel="stylesheet" href="../src/popup/style.css">
  <style>
    body { width: auto; padding: 16px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, 340px); gap: 16px; }
    .card { padding: 12px 14px; border: 1px solid var(--line); border-radius: 14px; background: var(--surface); }
    .card h3 { font-size: 12px; color: var(--text-3); margin-bottom: 6px; font-weight: 600; }
    .top { display: flex; gap: 12px; align-items: center; margin-bottom: 16px; }
  </style>
</head>
<body>
  <div class="top"><b>Metro preview</b><button class="btn" id="theme" type="button">Toggle dark</button></div>
  <div class="grid" id="grid"></div>
  <script type="module" src="./preview.ts"></script>
</body>
</html>
```

`extension/dev/preview.ts`:

```ts
import { layoutMetro, renderMetro, type MetroInput } from '../src/popup/metro';
import type { Hop } from '../src/lib/protocol';

const hops = (first: Hop['role'], exit = 'exit1'): Hop[] => [
  { role: first, id: `${first}id`, addr: first === 'bridge' ? '192.0.2.3' : '64.65.1.161', country: first === 'bridge' ? null : 'US' },
  { role: 'middle', id: 'middleid', addr: '176.123.3.35', country: 'MD' },
  { role: 'exit', id: exit, addr: '185.220.101.3', country: exit === 'exit1' ? 'DE' : 'NL' },
];

const states: [string, MetroInput][] = [
  ['Connecting — first hop', { bridge: 'snowflake', site: 'github.com', hops: null, stage: 'bridge', connecting: true }],
  ['Connecting — directory', { bridge: 'snowflake', site: 'github.com', hops: null, stage: 'directory', connecting: true }],
  ['On — Snowflake', { bridge: 'snowflake', site: 'github.com', hops: hops('bridge'), stage: 'ready', connecting: false }],
  ['On — obfs4', { bridge: 'obfs4', site: 'wikipedia.org', hops: hops('bridge'), stage: 'ready', connecting: false }],
  ['On — WebTunnel', { bridge: 'webtunnel', site: 'ycombinator.com', hops: hops('bridge'), stage: 'ready', connecting: false }],
  ['On — no bridge', { bridge: 'none', site: 'duckduckgo.com', hops: hops('guard'), stage: 'ready', connecting: false }],
  ['On — tab without a site (Chrome shows “Incognito”)', { bridge: 'none', site: 'default', hops: null, stage: 'ready', connecting: false }],
];

const grid = document.getElementById('grid')!;
for (const [title, input] of states) {
  const card = document.createElement('div');
  card.className = 'card';
  card.innerHTML = `<h3>${title}</h3>`;
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.classList.add('metro');
  card.append(svg);
  grid.append(card);
  renderMetro(svg, layoutMetro(input));
}

// A circuit change: the exit station animates in every 3 s.
const changing = document.createElement('div');
changing.className = 'card';
changing.innerHTML = '<h3>New circuit (exit changes every 3 s)</h3>';
const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
svg.classList.add('metro');
changing.append(svg);
grid.append(changing);
let flip = false;
const draw = () => renderMetro(svg, layoutMetro({ bridge: 'snowflake', site: 'github.com', hops: hops('bridge', flip ? 'exit2' : 'exit1'), stage: 'ready', connecting: false }));
draw();
setInterval(() => { flip = !flip; draw(); }, 3000);

document.getElementById('theme')!.addEventListener('click', () => {
  const root = document.documentElement;
  root.dataset.theme = root.dataset.theme === 'dark' ? 'light' : 'dark';
});
```

`extension/package.json`:

```json
{
  "name": "tortuga-extension",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "npm run typecheck && npm run build:background && npm run build:theme && npm run build:popup && npm run build:options",
    "build:background": "vite build --config vite.config.background.ts",
    "build:theme": "vite build --config vite.config.theme.ts",
    "build:popup": "vite build --config vite.config.popup.ts",
    "build:options": "vite build --config vite.config.options.ts",
    "build:firefox": "TARGET=firefox npm run build",
    "typecheck": "tsc --noEmit",
    "test": "vitest run",
    "lint:firefox": "npx --yes web-ext@10.8.0 lint --source-dir dist-firefox",
    "start:firefox": "npx --yes web-ext@10.8.0 run --source-dir dist-firefox",
    "preview:metro": "vite build --config vite.config.preview.ts"
  },
  "dependencies": {
    "tldts": "^7.4.19"
  },
  "devDependencies": {
    "@types/chrome": "^0.0.268",
    "typescript": "^5.4.5",
    "vite": "^5.2.12",
    "vitest": "^1.6.0"
  }
}
```

`extension/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "lib": [
      "ES2022",
      "DOM"
    ],
    "noEmit": true,
    "skipLibCheck": true,
    "types": [
      "chrome"
    ]
  },
  "include": [
    "src",
    "tests",
    "dev"
  ]
}
```

`extension/.gitignore`:

```
node_modules/
dist/
dist-firefox/
dist-preview/
*.zip
```

The preview imports the popup's `style.css`, written in Task 6; build it after that task.

- [ ] **Step 5: Commit**

```bash
git add extension
git commit -m "extension: metro diagram layout and rendering, preview page"
```

---

### Task 6: Popup

**Files:**
- Modify: `extension/src/popup/view.ts`, `extension/src/popup/index.html`, `extension/src/popup/index.ts`, `extension/src/popup/style.css`
- Test: `extension/tests/view.test.ts`

- [ ] **Step 1: Write the test**

`extension/tests/view.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { viewFor } from '../src/popup/view';
import { initialState, reduce } from '../src/lib/state';

describe('viewFor', () => {
  it('shows progress and the connecting line while connecting', () => {
    const s = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'snowflake' }), { type: 'status', stage: 'directory', percent: 40, blocked: null });
    expect(viewFor(s, 'default')).toMatchObject({
      torSelected: true, tone: 'busy', status: 'Connecting via Snowflake… 40%',
      metro: { bridge: 'snowflake', hops: null, stage: 'directory', connecting: true },
    });
  });

  it('draws the site’s circuit and its exit relay when on', () => {
    let s = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'none' }), { type: 'ready', socksPort: 9150 });
    s = reduce(s, { type: 'circuit', circuit: { site: 'github.com', bridge: null, hops: [
      { role: 'guard', id: 'g', addr: '192.0.2.1', country: 'US' },
      { role: 'middle', id: 'm', addr: '192.0.2.2', country: 'MD' },
      { role: 'exit', id: 'e', addr: '185.220.101.3', country: 'DE' },
    ] } });
    const v = viewFor(s, 'github.com');
    expect(v).toMatchObject({ tone: 'on', canNewCircuit: true, exit: 'Exit relay 185.220.101.3 · DE' });
    expect(v.metro?.hops).toHaveLength(3);
    expect(viewFor(s, 'wikipedia.org')).toMatchObject({ exit: null, metro: { hops: null } });
  });

  it('offers Restart after a failure but not for a missing helper', () => {
    const on = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'none' }), { type: 'ready', socksPort: 1 });
    expect(viewFor(reduce(on, { type: 'failed', error: 'gone' }), 'default')).toMatchObject({ tone: 'alert', showRestart: true, metro: null });
    expect(viewFor(reduce(on, { type: 'failed', error: 'x', helperMissing: true }), 'default')).toMatchObject({ status: 'Helper not installed', showRestart: false });
  });
});
```

Run: `cd extension && npx vitest run tests/view.test.ts`
Expected: FAIL — `metro` / `exit` missing from the view.

- [ ] **Step 2: Implement the view**

`extension/src/popup/view.ts`:

```ts
import type { TorState } from '../lib/state';
import type { MetroInput } from './metro';

/** What the popup shows for a state: pure, so it can be tested. */
export interface View {
  /** Tor side of the switch is selected. */
  torSelected: boolean;
  /** data-state on the status line: colours the dot. */
  tone: 'off' | 'busy' | 'on' | 'alert';
  status: string;
  /** A longer explanation under the status, or null. */
  note: string | null;
  showRestart: boolean;
  canNewCircuit: boolean;
  /** The metro diagram, or null when there is no route to draw. */
  metro: MetroInput | null;
  /** "Exit relay 185.220.101.3 · DE" for the active tab's circuit. */
  exit: string | null;
}

export const BRIDGE_NAMES = { none: 'no bridge', snowflake: 'Snowflake', obfs4: 'obfs4', webtunnel: 'WebTunnel' } as const;

export function viewFor(s: TorState, site: string): View {
  const base: View = { torSelected: s.phase !== 'off', tone: 'off', status: '', note: null, showRestart: false, canNewCircuit: false, metro: null, exit: null };
  switch (s.phase) {
    case 'off':
      return { ...base, status: 'Direct — Tortuga is off', note: s.error };
    case 'connecting':
      return {
        ...base,
        tone: 'busy',
        status: `Connecting via ${BRIDGE_NAMES[s.bridge]}… ${s.percent}%`,
        note: s.blocked ?? 'Traffic waits until Tor is ready.',
        metro: { bridge: s.bridge, site, hops: null, stage: s.stage, connecting: true },
      };
    case 'on': {
      const hops = s.circuits[site]?.hops ?? null;
      const exitHop = hops?.find(h => h.role === 'exit');
      return {
        ...base,
        tone: 'on',
        status: `Tor on via ${BRIDGE_NAMES[s.bridge]}`,
        note: __TARGET__ === 'chrome' ? 'Only incognito windows use Tor in Chrome, all through one circuit.' : null,
        canNewCircuit: true,
        metro: { bridge: s.bridge, site, hops, stage: 'ready', connecting: false },
        exit: exitHop?.addr ? `Exit relay ${exitHop.addr}${exitHop.country ? ` · ${exitHop.country}` : ''}` : null,
      };
    }
    case 'failed':
      return {
        ...base,
        tone: 'alert',
        status: s.helperMissing ? 'Helper not installed' : 'Tor stopped — traffic is blocked',
        note: s.error,
        showRestart: !s.helperMissing,
      };
  }
}
```

Run: `cd extension && npx vitest run tests/view.test.ts`
Expected: `3 passed`

- [ ] **Step 3: Popup page**

`extension/src/popup/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Tortuga</title>
  <script src="/theme.js"></script>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <header class="bar">
    <div class="brand">Tortuga</div>
    <div class="conn" role="radiogroup" aria-label="Connection">
      <label><input type="radio" name="conn" id="connDirect" value="direct"><span>Direct</span></label>
      <label><input type="radio" name="conn" id="connTor" value="tor"><span>Tor</span></label>
    </div>
  </header>

  <main>
    <svg class="metro" id="metro" role="img" aria-label="Route through Tor" hidden></svg>

    <div class="status" id="status" data-state="off" aria-live="polite">
      <span class="status-dot"></span><span id="statusText">…</span>
    </div>
    <p class="note" id="note" hidden></p>
    <p class="exit" id="exit" hidden></p>

    <div class="row">
      <button class="btn" id="bridgeBtn" type="button" aria-expanded="false" aria-controls="bridges">
        <span id="bridgeName">No bridge</span> ▾
      </button>
      <button class="btn" id="newCircuit" type="button" disabled>↻ New circuit</button>
    </div>

    <div class="bridges" id="bridges" role="radiogroup" aria-label="Bridge" hidden>
      <button class="bridge" type="button" data-kind="none" role="radio">
        <span class="bridge-head"><b>No bridge</b><span>fastest</span></span>
        <svg viewBox="0 0 280 24" aria-hidden="true"><line class="mini" x1="8" y1="12" x2="272" y2="12"/><circle class="mini-dot" cx="8" cy="12" r="5"/><circle class="mini-dot" cx="140" cy="12" r="5"/><circle class="mini-end" cx="272" cy="12" r="5"/></svg>
        <span class="bridge-note">Your provider can see you connect to Tor</span>
      </button>
      <button class="bridge" type="button" data-kind="snowflake" role="radio">
        <span class="bridge-head"><b>❄ Snowflake</b><span>for blocked networks</span></span>
        <svg viewBox="0 0 280 24" aria-hidden="true"><line class="mini-bridge dotted" x1="8" y1="12" x2="110" y2="12"/><line class="mini" x1="110" y1="12" x2="272" y2="12"/><circle class="mini-dot" cx="8" cy="12" r="5"/><circle class="mini-dot bridgey" cx="60" cy="12" r="4"/><rect class="mini-dot bridgey" x="100" y="2" width="20" height="20" rx="5"/><circle class="mini-end" cx="272" cy="12" r="5"/></svg>
        <span class="bridge-note">Looks like a video call, through a volunteer’s browser</span>
      </button>
      <button class="bridge" type="button" data-kind="obfs4" role="radio">
        <span class="bridge-head"><b>◆ obfs4</b><span id="obfs4State">needs bridge lines</span></span>
        <svg viewBox="0 0 280 24" aria-hidden="true"><path class="mini-bridge" d="M8 12 q8 -7 16 0 t16 0 t16 0 t16 0 t16 0 t16 0 t16 0"/><line class="mini" x1="120" y1="12" x2="272" y2="12"/><circle class="mini-dot" cx="8" cy="12" r="5"/><rect class="mini-dot bridgey" x="110" y="2" width="20" height="20" rx="5"/><circle class="mini-end" cx="272" cy="12" r="5"/></svg>
        <span class="bridge-note">Traffic looks like random noise</span>
      </button>
      <button class="bridge" type="button" data-kind="webtunnel" role="radio">
        <span class="bridge-head"><b>🔒 WebTunnel</b><span id="webtunnelState">needs bridge lines</span></span>
        <svg viewBox="0 0 280 24" aria-hidden="true"><rect class="mini-tube" x="8" y="6" width="110" height="12" rx="6"/><line class="mini" x1="120" y1="12" x2="272" y2="12"/><circle class="mini-dot" cx="8" cy="12" r="5"/><rect class="mini-dot bridgey" x="110" y="2" width="20" height="20" rx="5"/><circle class="mini-end" cx="272" cy="12" r="5"/></svg>
        <span class="bridge-note">Looks like an ordinary HTTPS website</span>
      </button>
    </div>

    <button class="btn btn-primary" id="restart" type="button" hidden>Restart</button>
  </main>

  <footer class="foot"><a href="#" id="settings">Settings</a><span>Hides your IP. Not Tor Browser.</span></footer>

  <script type="module" src="index.ts"></script>
</body>
</html>
```

`extension/src/popup/index.ts`:

```ts
import { bridgeReady } from '../lib/bridges';
import { LINES_KEY, NO_LINES, type BgBroadcast, type BgMessage, type BridgeLines } from '../lib/messages';
import type { BridgeKind } from '../lib/protocol';
import { DEFAULT_SITE, siteOf } from '../lib/site';
import type { TorState } from '../lib/state';
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
    $(`${kind}State`).textContent = lines[kind].length ? `${lines[kind].length} saved` : 'add lines in Settings';
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
});
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
}

void init();
```

`extension/src/popup/style.css`:

```css
/* Tortuga popup — Nomada's look, with the route drawn as a metro line. */

@import '../styles/tokens.css';
@import '../styles/flags.css';

*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
/* `hidden` must win over any display rule (and works on SVG too). */
[hidden] { display: none !important; }

body {
  width: 340px;
  background: var(--bg);
  color: var(--text);
  font: 13px/1.45 var(--font);
  -webkit-font-smoothing: antialiased;
}

button { font: inherit; color: inherit; }
:focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }

.bar { display: flex; align-items: center; justify-content: space-between; padding: 14px 16px 10px; }
.brand { font-weight: 700; font-size: 15px; }

.conn { display: inline-grid; grid-auto-flow: column; padding: 3px; border-radius: 999px; background: var(--surface-2); font-size: 12px; font-weight: 600; }
.conn label { position: relative; cursor: pointer; }
.conn input { position: absolute; inset: 0; margin: 0; opacity: 0; cursor: inherit; }
.conn span { display: block; padding: 4px 12px; border-radius: 999px; color: var(--text-3); text-align: center; transition: background 0.15s, color 0.15s; }
.conn input:checked + span { background: var(--surface); color: var(--text); box-shadow: 0 0 0 1px var(--line); }
.conn input#connTor:checked + span { color: var(--accent); }
.conn input:focus-visible + span { outline: 2px solid var(--focus); outline-offset: 1px; }

main { display: grid; gap: 10px; padding: 0 16px 12px; }

/* ── Metro diagram ─────────────────────────────────────────────── */
.metro { width: 100%; height: auto; overflow: visible; }
.metro text { font-family: var(--font); text-anchor: middle; }
.metro .label { font-size: 11px; font-weight: 600; fill: var(--text-2); }
.metro .sub { font-size: 10px; fill: var(--text-3); }
.metro .site-label { text-anchor: end; font-size: 10.5px; }
.metro .flag-emoji { font: 15px/1 "Twemoji Country Flags", "Apple Color Emoji", "Segoe UI Emoji", sans-serif; }

.seg .stroke { fill: none; stroke: var(--line); stroke-width: 6; stroke-linecap: round; transition: stroke 0.3s; }
.seg .stroke.thin { stroke-width: 2; }
.seg .tube { fill: transparent; stroke: var(--line); stroke-width: 2; transition: stroke 0.3s, fill 0.3s; }
.seg-obfs4 .stroke { stroke-width: 3; }
.seg-snowflake .stroke { stroke-dasharray: 1 8; }
.seg.lit .stroke { stroke: var(--accent); }
.seg.lit .tube { stroke: var(--focus); fill: var(--focus-ring); }
.seg-snowflake.lit .stroke, .seg-obfs4.lit .stroke, .seg-webtunnel.lit .stroke { stroke: var(--focus); }
.seg.pending .stroke { stroke: var(--caution); stroke-dasharray: 6 8; animation: flow 0.9s linear infinite; }
@keyframes flow { to { stroke-dashoffset: -14; } }

.st .dot { fill: var(--surface); stroke: var(--line); stroke-width: 3; transition: stroke 0.3s, fill 0.3s; }
.st.lit .dot { stroke: var(--accent); }
.st-you.lit .dot { stroke: var(--text); }
.st-bridge.lit .dot { stroke: var(--focus); }
.st-site.lit .dot { fill: var(--accent); stroke: var(--accent); }
.st.enter .in { animation: enter 0.45s ease-out; }
@keyframes enter { from { opacity: 0; transform: translateY(-8px); } }

@media (prefers-reduced-motion: reduce) {
  .seg.pending .stroke, .st.enter .in { animation: none; }
}

/* ── Status ────────────────────────────────────────────────────── */
.status { display: flex; align-items: center; gap: 8px; font-weight: 600; }
.status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--text-3); }
.status[data-state="busy"] .status-dot { background: var(--caution); }
.status[data-state="on"] .status-dot { background: var(--accent); }
.status[data-state="alert"] { color: var(--warn); }
.status[data-state="alert"] .status-dot { background: var(--warn); }

.note { color: var(--text-2); font-size: 12px; }
.exit { font: 12px/1.4 var(--mono); color: var(--text-2); }

.row { display: flex; align-items: center; justify-content: space-between; gap: 10px; }

.btn { padding: 6px 12px; border: 1px solid var(--line); border-radius: 999px; background: var(--surface); cursor: pointer; font-weight: 600; font-size: 12px; }
.btn:disabled { opacity: 0.45; cursor: not-allowed; }
.btn-primary { background: var(--accent); border-color: var(--accent); color: #fff; }

/* ── Bridge picker ─────────────────────────────────────────────── */
.bridges { display: grid; gap: 6px; }
.bridge { display: grid; gap: 2px; padding: 8px 10px; text-align: left; border: 1px solid var(--line); border-radius: 12px; background: var(--surface); cursor: pointer; }
.bridge[aria-checked="true"] { border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-soft); }
.bridge:disabled { cursor: not-allowed; opacity: 0.55; }
.bridge-head { display: flex; justify-content: space-between; gap: 8px; }
.bridge-head span, .bridge-note { font-size: 11px; color: var(--text-3); }
.bridge svg { width: 100%; height: 22px; }
.mini { stroke: var(--accent); stroke-width: 3; stroke-linecap: round; }
.bridge[data-kind="none"] .mini { stroke: var(--text-3); }
.mini-bridge { fill: none; stroke: var(--focus); stroke-width: 3; stroke-linecap: round; }
.mini-bridge.dotted { stroke-dasharray: 1 6; }
.mini-tube { fill: var(--focus-ring); stroke: var(--focus); stroke-width: 2; }
.mini-dot { fill: var(--surface); stroke: var(--text); stroke-width: 2.5; }
.mini-dot.bridgey { stroke: var(--focus); }
.mini-end { fill: var(--accent); }
.bridge[data-kind="none"] .mini-end { fill: var(--text-3); }

.foot { display: flex; justify-content: space-between; gap: 8px; padding: 10px 16px 14px; border-top: 1px solid var(--line); font-size: 11px; color: var(--text-3); }
.foot a { color: var(--focus); text-decoration: none; font-weight: 600; }
```

- [ ] **Step 4: Look at every diagram state**

Run: `cd extension && npm run preview:metro && npx vite preview --config vite.config.preview.ts --port 4174`, open `http://localhost:4174/`.
Expected: eight cards (the page builds as Firefox) — connecting (first hop: You lit, an amber moving dash; directory: bridge lit, dash on the next segment), Snowflake (dotted blue first segment), obfs4 (wavy), WebTunnel (tube), no bridge (Guard with a US flag), a tab without a site ("No site"; Chrome shows "Incognito"), and a card whose exit station fades in with a new flag every 3 s. Site names sit above the end station without touching the exit's flag (`wikipedia`, `ycombinator`). **Toggle dark** switches all of it to the dark tokens.

- [ ] **Step 5: Commit**

```bash
git add extension/src/popup extension/tests/view.test.ts
git commit -m "extension: popup with the metro diagram, bridge picker and exit relay"
```

---

### Task 7: Background wiring and settings page

**Files:**
- Modify: `extension/src/background/index.ts`, `extension/src/lib/theme.ts`, `extension/manifest.json`, `extension/manifest.firefox.json`
- Create: `extension/vite.config.options.ts`, `extension/src/options/index.html`, `extension/src/options/index.ts`, `extension/src/options/style.css`, `extension/src/options/helper-text.ts`
- Test: `extension/tests/options.test.ts`

- [ ] **Step 1: Write the failing test**

`extension/tests/options.test.ts`:

```ts
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
```

Run: `cd extension && npx vitest run tests/options.test.ts`
Expected: FAIL — `Failed to load url ../src/options/helper-text`.

- [ ] **Step 2: Settings page**

`extension/src/options/helper-text.ts`:

```ts
import type { TorState } from '../lib/state';

/** What the settings page says about the helper. */
export function helperText(s: TorState): string {
  if (s.helperMissing) return 'Not installed. Install the Tortuga helper, then turn Tor on.';
  if (s.helperVersion) return `Version ${s.helperVersion}, connected.`;
  return 'Starts when you turn Tor on.';
}
```

`extension/src/options/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Tortuga settings</title>
  <script src="/theme.js"></script>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <main class="page">
    <h1>Tortuga</h1>
    <p class="lead">Hides your IP and opens .onion sites. It is not Tor Browser: sites can still recognise this browser by its fingerprint.</p>

    <section class="card">
      <h2>Helper</h2>
      <p id="helper" class="muted">Checking…</p>
    </section>

    <section class="card">
      <h2>Bridge lines</h2>
      <p class="muted">obfs4 and WebTunnel need bridge addresses. Get them from bridges.torproject.org (or the Tor Project’s Telegram bot) and paste them here, one per line. Snowflake needs none.</p>
      <label class="field" for="obfs4">obfs4</label>
      <textarea id="obfs4" rows="4" spellcheck="false" placeholder="obfs4 192.0.2.1:443 0123…ABCD cert=… iat-mode=0"></textarea>
      <ul class="errors" id="obfs4Errors" hidden></ul>
      <label class="field" for="webtunnel">WebTunnel</label>
      <textarea id="webtunnel" rows="4" spellcheck="false" placeholder="webtunnel [2001:db8::1]:443 0123…ABCD url=https://… ver=0.0.1"></textarea>
      <ul class="errors" id="webtunnelErrors" hidden></ul>
      <div class="actions"><button class="btn btn-primary" id="save" type="button">Save</button><span id="saved" class="muted" role="status"></span></div>
    </section>

    <section class="card">
      <h2>Theme</h2>
      <div class="conn" role="radiogroup" aria-label="Theme">
        <label><input type="radio" name="theme" value="system"><span>System</span></label>
        <label><input type="radio" name="theme" value="light"><span>Light</span></label>
        <label><input type="radio" name="theme" value="dark"><span>Dark</span></label>
      </div>
    </section>
  </main>
  <script type="module" src="index.ts"></script>
</body>
</html>
```

`extension/src/options/index.ts`:

```ts
import { parseLines, type LineKind } from '../lib/bridges';
import { LINES_KEY, NO_LINES, type BgMessage, type BridgeLines } from '../lib/messages';
import type { TorState } from '../lib/state';
import { chooseTheme, chosenTheme, clearTheme } from '../lib/theme';
import { helperText } from './helper-text';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const KINDS: LineKind[] = ['obfs4', 'webtunnel'];

async function showHelper(): Promise<void> {
  const s: TorState = await chrome.runtime.sendMessage({ type: 'GET_STATE' } satisfies BgMessage);
  $('helper').textContent = helperText(s);
}

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
initTheme();
void loadLines();
void showHelper();
```

`extension/src/options/style.css`:

```css
/* Tortuga settings — the popup's look on a page. */

@import '../styles/tokens.css';

*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
/* `hidden` must win over any display rule (and works on SVG too). */
[hidden] { display: none !important; }

body { background: var(--bg); color: var(--text); font: 14px/1.5 var(--font); -webkit-font-smoothing: antialiased; }
button, textarea { font: inherit; color: inherit; }
:focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }

.page { display: grid; gap: 16px; max-width: 640px; margin: 0 auto; padding: 32px 16px 48px; }
h1 { font-size: 22px; }
h2 { font-size: 15px; margin-bottom: 6px; }
.lead, .muted { color: var(--text-2); }
.muted { font-size: 13px; }

.card { display: grid; gap: 8px; padding: 16px; border: 1px solid var(--line); border-radius: var(--radius); background: var(--surface); }
.field { font-size: 12px; font-weight: 600; color: var(--text-2); margin-top: 4px; }
textarea { width: 100%; padding: 8px 10px; border: 1px solid var(--line); border-radius: 10px; background: var(--bg); font: 12px/1.5 var(--mono); resize: vertical; }
.errors { list-style: none; color: var(--warn); font-size: 12px; }
.actions { display: flex; align-items: center; gap: 12px; }

.btn { padding: 7px 14px; border: 1px solid var(--line); border-radius: 999px; background: var(--surface); cursor: pointer; font-weight: 600; font-size: 13px; }
.btn-primary { background: var(--accent); border-color: var(--accent); color: #fff; }

.conn { display: inline-grid; grid-auto-flow: column; justify-self: start; padding: 3px; border-radius: 999px; background: var(--surface-2); font-size: 12px; font-weight: 600; }
.conn label { position: relative; cursor: pointer; }
.conn input { position: absolute; inset: 0; margin: 0; opacity: 0; cursor: inherit; }
.conn span { display: block; padding: 4px 14px; border-radius: 999px; color: var(--text-3); }
.conn input:checked + span { background: var(--surface); color: var(--text); box-shadow: 0 0 0 1px var(--line); }
.conn input:focus-visible + span { outline: 2px solid var(--focus); outline-offset: 1px; }
```

`extension/vite.config.options.ts`:

```ts
import { defineConfig } from 'vite';
import { resolve } from 'path';
import { renameSync, rmSync } from 'fs';
import { define, outDir } from './vite.target';

export default defineConfig({
  define,
  build: {
    outDir,
    emptyOutDir: false,
    rollupOptions: {
      input: { options: resolve(__dirname, 'src/options/index.html') },
      output: { entryFileNames: '[name].js', assetFileNames: '[name].[ext]' },
    },
  },
  plugins: [
    {
      name: 'flatten-options-html',
      closeBundle() {
        // Vite mirrors the source path (dist/src/options/index.html); the manifest wants dist/options.html.
        renameSync(resolve(__dirname, outDir, 'src/options/index.html'), resolve(__dirname, outDir, 'options.html'));
        rmSync(resolve(__dirname, outDir, 'src'), { recursive: true, force: true });
      },
    },
  ],
});
```

`extension/src/lib/theme.ts`:

```ts
// Light or dark: what the user picked on the settings page, or else the system's.
// The pick lives in localStorage, which the popup and the settings page share,
// so theme.js can read it synchronously and set data-theme before the first paint.

export type Theme = 'light' | 'dark';

export const THEME_KEY = 'tortuga-theme';
const SYSTEM_DARK = '(prefers-color-scheme: dark)';

/** The theme picked on the settings page, if any. */
export function chosenTheme(): Theme | null {
  try {
    const value = localStorage.getItem(THEME_KEY);
    return value === 'light' || value === 'dark' ? value : null;
  } catch {
    return null;
  }
}

export function themeFor(chosen: Theme | null, systemDark: boolean): Theme {
  return chosen ?? (systemDark ? 'dark' : 'light');
}

function applyTheme(): void {
  document.documentElement.dataset.theme = themeFor(chosenTheme(), matchMedia(SYSTEM_DARK).matches);
}

export function chooseTheme(theme: Theme): void {
  try { localStorage.setItem(THEME_KEY, theme); } catch { /* storage off: lasts while the page is open */ }
  document.documentElement.dataset.theme = theme;
}

/** Follow the system again. */
export function clearTheme(): void {
  try { localStorage.removeItem(THEME_KEY); } catch { /* nothing stored */ }
  applyTheme();
}

/** Set the theme now, then follow the system and picks made on another page. */
export function watchTheme(): void {
  applyTheme();
  matchMedia(SYSTEM_DARK).addEventListener('change', applyTheme);
  addEventListener('storage', e => { if (e.key === THEME_KEY) applyTheme(); });
}
```

- [ ] **Step 3: Background and manifests**

`extension/src/background/index.ts`:

```ts
import { linesFor } from '../lib/bridges';
import { LINES_KEY, NO_LINES, STORAGE_KEY, type BgBroadcast, type BgMessage, type BridgeLines, type Stored } from '../lib/messages';
import type { BridgeKind } from '../lib/protocol';
import type { TorState } from '../lib/state';
import { Controller } from './controller';
import { connectHelper } from './helper';
import { applyPrivacy } from './privacy';
import { applyChromeRoute, firefoxAnswer } from './routing';

const controller = new Controller({
  connect: connectHelper,
  // Firefox asks proxy.onRequest about each request (below); Chrome has one setting.
  applyRoute: port => (__TARGET__ === 'firefox' ? Promise.resolve() : applyChromeRoute(port)),
  applyPrivacy,
  save: stored => chrome.storage.local.set({ [STORAGE_KEY]: stored }),
  broadcast: (state: TorState) => {
    const msg: BgBroadcast = { type: 'STATE', state };
    chrome.runtime.sendMessage(msg).catch(() => { /* no popup open */ });
  },
  incognitoAllowed: () => (__TARGET__ === 'firefox' ? Promise.resolve(true) : chrome.extension.isAllowedIncognitoAccess()),
});

/** Bridge lines saved on the settings page for `kind`. */
async function savedLines(kind: BridgeKind): Promise<string[]> {
  const r = await chrome.storage.local.get(LINES_KEY);
  return linesFor(kind, (r[LINES_KEY] as BridgeLines | undefined) ?? NO_LINES);
}

// Back to how it was when the background last stopped. If Tortuga was on, it
// starts again; until Tor is ready, routedPort() blocks traffic instead of
// letting it out directly.
const restored = chrome.storage.local.get(STORAGE_KEY).then(async r => {
  const stored = r[STORAGE_KEY] as Stored | undefined;
  if (stored?.enabled) await controller.turnOn(stored.bridge, await savedLines(stored.bridge));
  else if (stored) await controller.chooseBridge(stored.bridge);
});

if (__TARGET__ === 'firefox') {
  // A persistent listener: Firefox wakes the background for it. Requests wait
  // for the stored state, so none slips out before Tortuga knows it is on.
  chrome.proxy.onRequest.addListener(async details => {
    await restored;
    return firefoxAnswer(controller.port, details);
  }, { urls: ['<all_urls>'] });
}

chrome.runtime.onMessage.addListener((msg: BgMessage, _sender, sendResponse) => {
  const reply = (p: Promise<TorState>) => {
    p.then(sendResponse, () => sendResponse(controller.current));
    return true;
  };
  switch (msg.type) {
    case 'GET_STATE':
      return reply(restored.then(() => controller.current));
    case 'TOR_ON':
      return reply(savedLines(msg.bridge).then(lines => controller.turnOn(msg.bridge, lines)));
    case 'TOR_OFF':
      return reply(controller.turnOff());
    case 'SET_BRIDGE':
      return reply(savedLines(msg.bridge).then(lines => controller.chooseBridge(msg.bridge, lines)));
    case 'NEW_CIRCUIT':
      return reply(controller.newCircuit(msg.site));
  }
  return false;
});
```

`extension/manifest.json`:

```json
{
  "manifest_version": 3,
  "name": "Tortuga — Tor routing",
  "version": "0.1.0",
  "description": "Send incognito windows through Tor with the Tortuga helper. Hides your IP; it is not Tor Browser.",
  "minimum_chrome_version": "120",
  "permissions": [
    "proxy",
    "privacy",
    "storage",
    "nativeMessaging"
  ],
  "background": {
    "service_worker": "background.js",
    "type": "module"
  },
  "action": {
    "default_popup": "popup.html"
  },
  "options_page": "options.html"
}
```

`extension/manifest.firefox.json`:

```json
{
  "manifest_version": 3,
  "name": "Tortuga — Tor routing",
  "version": "0.1.0",
  "description": "Send the browser through Tor with the Tortuga helper, one circuit per site. Hides your IP; it is not Tor Browser.",
  "browser_specific_settings": {
    "gecko": {
      "id": "tortuga@legenki.com",
      "strict_min_version": "140.0",
      "data_collection_permissions": {
        "required": [
          "none"
        ]
      }
    },
    "gecko_android": {
      "strict_min_version": "142.0"
    }
  },
  "permissions": [
    "proxy",
    "privacy",
    "storage",
    "nativeMessaging",
    "tabs"
  ],
  "host_permissions": [
    "<all_urls>"
  ],
  "background": {
    "scripts": [
      "background.js"
    ],
    "type": "module"
  },
  "action": {
    "default_popup": "popup.html"
  },
  "options_ui": {
    "page": "options.html",
    "open_in_tab": true
  }
}
```

- [ ] **Step 4: Everything**

Run: `cd extension && npm test && npm run build && npm run build:firefox && npm run lint:firefox`
Expected: `Tests  57 passed (57)`; `dist/` and `dist-firefox/` hold `background.js fonts manifest.json options.css options.html options.js popup.css popup.html popup.js theme.js`; lint `errors 0, notices 0, warnings 0`.

- [ ] **Step 5: Commit**

```bash
git add extension
git commit -m "extension: settings page, bridge lines and SET_BRIDGE"
```

---

### Task 8: Live check and spec

**Files:**
- Modify: `extension/scripts/live-check/check.mjs`, `docs/superpowers/specs/2026-11-05-tortuga-design.md`

- [ ] **Step 1: Update the live check**

`extension/scripts/live-check/check.mjs`:

```js
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
await evaluate(popup, `chrome.runtime.sendMessage({ type: 'SET_BRIDGE', bridge: 'snowflake' }).then(() => { document.getElementById('connTor').click(); return 1; })`);
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
// The click only sends TOR_ON: the state may still read 'failed' for a moment.
for (let i = 0; i < 120; i++) { s = await state(popup); if (s.phase === 'on') break; await sleep(1000); }
check(s.phase === 'on', `back on after Restart (${s.phase}${s.error ? ': ' + s.error : ''})`);

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
```

(The popup has no `<select id="bridge">` any more, so the check picks Snowflake with `SET_BRIDGE`; after Restart it waits for `on`, because the click only sends `TOR_ON` and the state can still read `failed` for a moment.)

- [ ] **Step 2: Run it**

Run: `(cd helper && cargo build --release -p tortuga-helper) && extension/scripts/live-check/run.sh`
Expected: `ALL PASSED`. A run can fail on one site with `NS_ERROR_UNKNOWN_HOST` after about 60 s when a Tor exit can't resolve the name; run it again. Two runs in a row passed while planning.

- [ ] **Step 3: Spec**

In `docs/superpowers/specs/2026-11-05-tortuga-design.md`:
1. `circuit` payload hops: `{ role, id, addr, country }` — `addr` is the relay's address (a placeholder for Snowflake).
2. *Popup (two tabs)*: the site's name sits above the end station; a tab that isn't a web page shows "No site" (Firefox) / "Incognito" (Chrome); the exit line reads "Exit relay ‹addr› · ‹country›" — the relay's address, which is normally the address sites see.
3. *Settings page*: bridge lines are checked on Save (transport, address:port, 40-character fingerprint) and stored as `Bridge …` lines.

- [ ] **Step 4: Commit**

```bash
git add extension/scripts/live-check/check.mjs docs/superpowers/specs/2026-11-05-tortuga-design.md
git commit -m "dev: live check follows the new popup; spec follows 3b"
```

---

## Next plans

Moat bridges ("Get a bridge"), Torrents (Downloads tab), Installers and release.
