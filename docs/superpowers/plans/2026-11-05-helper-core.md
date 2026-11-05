# Helper Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working `tortuga-helper` native messaging host: hello handshake, Tor on/off with no bridge or Snowflake / obfs4 / WebTunnel, its own SOCKS5 port with one circuit set per site, `tor.status` progress and `circuit` events — proven end to end by a script that acts as the browser.

**Architecture:** A Cargo workspace in `helper/` with one binary crate, `tortuga-helper`. Pure modules (framing, protocol, hops, isolation, SOCKS5, config) are unit-tested; `tor.rs` wraps one `arti-client` instance per process (reconfigured, not recreated, on each start); `app.rs` routes requests and runs bootstrap in a task so `tor.stop` can cancel it. `scripts/nm_client.py` drives the real binary over stdin/stdout and `curl` through its SOCKS port.

**Tech Stack:** Rust edition 2024 (rustc 1.99), `arti-client` / `tor-*` 0.48.0, `tokio`, `futures`, `serde` / `serde_json`, `directories`, `anyhow`; `lyrebird` and `pt_config.json` from Tor Expert Bundle 16.0; Python 3 and `curl` for the end-to-end check.

Spec: `docs/superpowers/specs/2026-11-05-tortuga-design.md` (sections *Helper*, *Protocol*). Findings this builds on: `docs/spike-findings.md`.

## Global Constraints

- All `arti-client` / `tor-*` crates pinned with `=0.48.0`.
- stdout carries only framed protocol messages; anything else (logs) goes to stderr.
- The SOCKS server listens on `127.0.0.1` only, on a random free port.
- Arti state and cache never use the shared Arti defaults: `TORTUGA_DATA_DIR` if set, else the platform data / cache dirs for `org.Tortuga.tortuga-helper`.
- Transports are found in `TORTUGA_PT_DIR` if set, else `pt/` next to the executable.
- `PROTOCOL_VERSION` is `1`.
- Not in this plan (own plans later): Moat bridge fetching (`bridges.fetch`), torrents, installers and native host registration.

## File Structure

| File | Responsibility |
|---|---|
| `helper/Cargo.toml` | Workspace; excludes `spike/` |
| `helper/tortuga-helper/Cargo.toml` | Binary crate and its pinned dependencies |
| `helper/tortuga-helper/src/framing.rs` | Native messaging length-prefixed frames |
| `helper/tortuga-helper/src/hops.rs` | `Role`, `Hop`, `roles_for`, `CircuitTracker` (moved from the spike) |
| `helper/tortuga-helper/src/protocol.rs` | Request / reply / event types and their JSON shape |
| `helper/tortuga-helper/src/isolation.rs` | Site → `IsolationToken` |
| `helper/tortuga-helper/src/socks.rs` | SOCKS5 handshake, `Connector` trait, relaying |
| `helper/tortuga-helper/src/config.rs` | `Paths`, default Snowflake lines, `tor_config()` |
| `helper/tortuga-helper/src/tor.rs` | Arti client: bootstrap, status, restart, sleep, connect with isolation, circuit events |
| `helper/tortuga-helper/src/app.rs` | Request handling and the start / stop lifecycle |
| `helper/tortuga-helper/src/main.rs` | stdin / stdout loop |
| `helper/scripts/fetch-pt.sh` | Download and verify the Expert Bundle, keep `lyrebird` + `pt_config.json` |
| `helper/scripts/nm_client.py` | End-to-end check acting as the browser |
| `helper/.gitignore` | Ignores `resources/` and `target/` |

Each module's listing below is its final content. Where a task says "stub", copy the listing but replace the body of every non-test function above `#[cfg(test)]` with `todo!()` (keep signatures, types, constants and the whole test module), run the tests to see them fail, then put the real bodies in.

---

### Task 1: Workspace and framing

**Files:**
- Create: `helper/Cargo.toml`, `helper/tortuga-helper/Cargo.toml`, `helper/tortuga-helper/src/framing.rs`, `helper/tortuga-helper/src/main.rs` (temporary), `helper/.gitignore`

**Interfaces:**
- Produces: `framing::read_message<R: AsyncRead + Unpin>(&mut R) -> io::Result<Option<Vec<u8>>>`, `framing::write_message<W: AsyncWrite + Unpin>(&mut W, &[u8]) -> io::Result<()>`, constants `MAX_TO_BROWSER`, `MAX_FROM_BROWSER`.

- [ ] **Step 1: Workspace manifests and ignore file**

`helper/Cargo.toml`:

```toml
[workspace]
resolver = "3"
members = ["tortuga-helper"]
exclude = ["spike"]
```

`helper/tortuga-helper/Cargo.toml`:

```toml
[package]
name = "tortuga-helper"
version = "0.1.0"
edition = "2024"
publish = false

[dependencies]
arti-client = { version = "=0.48.0", features = ["full", "experimental-api", "geoip"] }
tor-proto = { version = "=0.48.0", features = ["stream-ctrl"] }
tor-linkspec = "=0.48.0"
tor-geoip = "=0.48.0"
tor-rtcompat = "=0.48.0"
tokio = { version = "1", features = ["full"] }
futures = "0.3"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
directories = "6"
anyhow = "1"
```

`helper/.gitignore`:

```
/target/
/resources/
```

`helper/tortuga-helper/src/main.rs` (temporary, replaced in Task 7):

```rust
mod framing;

fn main() {}
```

- [ ] **Step 2: Stub `framing.rs` and see the tests fail**

Write `helper/tortuga-helper/src/framing.rs` from the listing in Step 3 as a stub (see *File Structure*).
Run: `cd helper && cargo test -p tortuga-helper framing`
Expected: 4 tests FAIL with `not yet implemented`. The first build compiles Arti — several minutes.

- [ ] **Step 3: Implement**

`helper/tortuga-helper/src/framing.rs`:

```rust
//! Native messaging framing: a 32-bit length in native byte order, then that
//! many bytes of UTF-8 JSON. Browsers cap host → browser messages at 1 MiB.

use std::io;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Largest message the browser accepts from the helper.
pub const MAX_TO_BROWSER: usize = 1024 * 1024;
/// Largest message the browser can send (Chrome and Firefox: 64 MiB).
pub const MAX_FROM_BROWSER: usize = 64 * 1024 * 1024;

/// Read one message. `Ok(None)` when the browser closed the pipe.
pub async fn read_message<R: AsyncRead + Unpin>(r: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut len = [0u8; 4];
    match r.read_exact(&mut len).await {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let n = u32::from_ne_bytes(len) as usize;
    if n > MAX_FROM_BROWSER {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("message of {n} bytes is too large")));
    }
    let mut buf = vec![0u8; n];
    r.read_exact(&mut buf).await?;
    Ok(Some(buf))
}

/// Write one message and flush it.
pub async fn write_message<W: AsyncWrite + Unpin>(w: &mut W, body: &[u8]) -> io::Result<()> {
    if body.len() > MAX_TO_BROWSER {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("message of {} bytes is too large", body.len())));
    }
    w.write_all(&(body.len() as u32).to_ne_bytes()).await?;
    w.write_all(body).await?;
    w.flush().await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn round_trip() {
        let mut wire = Vec::new();
        write_message(&mut wire, br#"{"id":1}"#).await.unwrap();
        write_message(&mut wire, b"{}").await.unwrap();
        let mut r = wire.as_slice();
        assert_eq!(read_message(&mut r).await.unwrap().unwrap(), br#"{"id":1}"#);
        assert_eq!(read_message(&mut r).await.unwrap().unwrap(), b"{}");
        assert!(read_message(&mut r).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn length_is_native_endian_u32() {
        let mut wire = Vec::new();
        write_message(&mut wire, b"abc").await.unwrap();
        assert_eq!(&wire[..4], &3u32.to_ne_bytes());
    }

    #[tokio::test]
    async fn refuses_oversized_outgoing() {
        let mut wire = Vec::new();
        let big = vec![b'x'; MAX_TO_BROWSER + 1];
        assert!(write_message(&mut wire, &big).await.is_err());
        assert!(wire.is_empty());
    }

    #[tokio::test]
    async fn truncated_body_is_an_error() {
        let mut wire = 10u32.to_ne_bytes().to_vec();
        wire.extend_from_slice(b"short");
        assert!(read_message(&mut wire.as_slice()).await.is_err());
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd helper && cargo test -p tortuga-helper framing`
Expected: `test result: ok. 4 passed`

- [ ] **Step 5: Commit**

```bash
git add helper/Cargo.toml helper/Cargo.lock helper/.gitignore helper/tortuga-helper
git commit -m "helper: workspace and native messaging framing"
```

---

### Task 2: Hops and circuit change tracking

**Files:**
- Create: `helper/tortuga-helper/src/hops.rs`
- Modify: `helper/tortuga-helper/src/main.rs` (add `mod hops;`)

**Interfaces:**
- Produces: `enum Role { Guard, Bridge, Middle, Exit }` (serializes lowercase), `struct Hop { role: Role, id: String, country: Option<String> }`, `fn roles_for(n_hops: usize, via_bridge: bool) -> Vec<Role>`, `struct CircuitTracker` with `fn observe(&mut self, site: &str, hops: &[Hop]) -> bool`.

- [ ] **Step 1: Stub and see the tests fail**

Write `hops.rs` from the listing in Step 2 as a stub; add `mod hops;` to `main.rs`.
Run: `cd helper && cargo test -p tortuga-helper hops`
Expected: 4 tests FAIL.

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

/// One hop: its role, the relay's Ed25519 identity, and its country when known
/// (a Snowflake bridge never has one).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Hop {
    pub role: Role,
    pub id: String,
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
        Hop { role, id: id.into(), country: Some("DE".into()) }
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

- [ ] **Step 3: Run the tests**

Run: `cd helper && cargo test -p tortuga-helper hops`
Expected: `test result: ok. 4 passed`

- [ ] **Step 4: Commit**

```bash
git add helper/tortuga-helper/src
git commit -m "helper: hop roles and circuit change tracking"
```

---

### Task 3: Protocol messages

**Files:**
- Create: `helper/tortuga-helper/src/protocol.rs`
- Modify: `helper/tortuga-helper/src/main.rs` (add `mod protocol;`)

**Interfaces:**
- Consumes: `hops::Hop`, `hops::Role` (Task 2).
- Produces: `PROTOCOL_VERSION: u32 = 1`; `Request { id: u64, body: RequestBody }`; `RequestBody::{Hello { protocol }, TorStart { bridge: BridgeChoice }, TorStop, TorNewCircuit { site }}`; `BridgeChoice { kind: BridgeKind, lines: Vec<String> }`; `BridgeKind::{None, Snowflake, Obfs4, Webtunnel}`; `Phase::{Bridge, Directory, Ready}`; `Message { id: Option<u64>, body: Outgoing }` with `Message::reply(id, body)`, `Message::event(body)`, `Message::error(id, code, message)`; `Outgoing::{Hello { protocol, version }, Ok, TorStatus { phase, percent: u8, blocked: Option<String> }, TorReady { socks_port: u16 }, Circuit { site, bridge: Option<BridgeKind>, hops }, Error { code, message }}`; `ErrorCode::{BadRequest, HelloRequired, ProtocolMismatch, TorFailed, NotRunning}`.

- [ ] **Step 1: Write the tests first**

Create `protocol.rs` from the listing in Step 2 but leave out the `impl Message` block and keep only the types and the test module.
Run: `cd helper && cargo test -p tortuga-helper protocol`
Expected: compile error `no function or associated item named 'reply' found for struct 'Message'` — the tests name the constructors that don't exist yet.

- [ ] **Step 2: Implement**

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
            hops: vec![Hop { role: Role::Bridge, id: "abc".into(), country: None }],
        }))
        .unwrap();
        assert_eq!(
            circuit,
            json!({"type": "circuit", "payload": {"site": "github.com", "bridge": "snowflake",
                   "hops": [{"role": "bridge", "id": "abc", "country": null}]}})
        );

        let err = serde_json::to_value(Message::error(Some(5), ErrorCode::ProtocolMismatch, "want 1")).unwrap();
        assert_eq!(err, json!({"id": 5, "type": "error", "payload": {"code": "protocol_mismatch", "message": "want 1"}}));
    }
}
```

- [ ] **Step 3: Run the tests**

Run: `cd helper && cargo test -p tortuga-helper protocol`
Expected: `test result: ok. 3 passed`. These pin the wire format, e.g. `{"id":3,"type":"ok"}` and `{"id":2,"type":"tor.ready","payload":{"socksPort":9150}}`.

- [ ] **Step 4: Commit**

```bash
git add helper/tortuga-helper/src
git commit -m "helper: protocol messages"
```

---

### Task 4: Per-site isolation

**Files:**
- Create: `helper/tortuga-helper/src/isolation.rs`
- Modify: `helper/tortuga-helper/src/main.rs` (add `mod isolation;`)

**Interfaces:**
- Produces: `DEFAULT_SITE: &str = "default"`; `IsolationMap` (`Default`) with `fn token_for(&mut self, site: &str) -> IsolationToken` and `fn renew(&mut self, site: &str)`.

- [ ] **Step 1: Stub and see the tests fail**

Write `isolation.rs` from the listing in Step 2 as a stub; add `mod isolation;`.
Run: `cd helper && cargo test -p tortuga-helper isolation`
Expected: 3 tests FAIL.

- [ ] **Step 2: Implement**

`helper/tortuga-helper/src/isolation.rs`:

```rust
//! One Arti isolation token per site, so each site gets its own circuits.

use std::collections::HashMap;

use arti_client::IsolationToken;

/// The site used when the browser sends no SOCKS username (Chrome).
pub const DEFAULT_SITE: &str = "default";

#[derive(Default)]
pub struct IsolationMap {
    tokens: HashMap<String, IsolationToken>,
}

impl IsolationMap {
    /// The token for `site`, created on first use.
    pub fn token_for(&mut self, site: &str) -> IsolationToken {
        *self.tokens.entry(site.to_owned()).or_insert_with(IsolationToken::new)
    }

    /// Give `site` a fresh token: its next streams use new circuits.
    pub fn renew(&mut self, site: &str) {
        self.tokens.insert(site.to_owned(), IsolationToken::new());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_site_same_token() {
        let mut m = IsolationMap::default();
        assert_eq!(m.token_for("github.com"), m.token_for("github.com"));
    }

    #[test]
    fn different_sites_different_tokens() {
        let mut m = IsolationMap::default();
        assert_ne!(m.token_for("github.com"), m.token_for("wikipedia.org"));
    }

    #[test]
    fn renew_changes_only_that_site() {
        let mut m = IsolationMap::default();
        let github = m.token_for("github.com");
        let wiki = m.token_for("wikipedia.org");
        m.renew("github.com");
        assert_ne!(m.token_for("github.com"), github);
        assert_eq!(m.token_for("wikipedia.org"), wiki);
    }
}
```

- [ ] **Step 3: Run the tests**

Run: `cd helper && cargo test -p tortuga-helper isolation`
Expected: `test result: ok. 3 passed`

- [ ] **Step 4: Commit**

```bash
git add helper/tortuga-helper/src
git commit -m "helper: one isolation token per site"
```

---

### Task 5: SOCKS5 server

**Files:**
- Create: `helper/tortuga-helper/src/socks.rs`
- Modify: `helper/tortuga-helper/src/main.rs` (add `mod socks;`)

**Interfaces:**
- Consumes: `isolation::DEFAULT_SITE` (Task 4).
- Produces: `SocksRequest { site, host, port }`; `trait Connector: Send + Sync + 'static { type Stream: AsyncRead + AsyncWrite + Unpin + Send + 'static; fn connect(&self, req: SocksRequest) -> impl Future<Output = io::Result<Self::Stream>> + Send; }`; `async fn handshake(&mut S) -> io::Result<SocksRequest>`; `async fn reply(&mut S, code: u8)`; `async fn handle(client: S, connector: &C) -> io::Result<()>`; reply codes `SUCCEEDED`, `HOST_UNREACHABLE`, `COMMAND_NOT_SUPPORTED`, `ADDRESS_NOT_SUPPORTED`.

- [ ] **Step 1: Stub and see the tests fail**

Write `socks.rs` from the listing in Step 2 as a stub; add `mod socks;`.
Run: `cd helper && cargo test -p tortuga-helper socks`
Expected: 5 tests FAIL.

- [ ] **Step 2: Implement**

`helper/tortuga-helper/src/socks.rs`:

```rust
//! A minimal SOCKS5 server (RFC 1928, CONNECT only) with username/password
//! auth (RFC 1929). The username names the site whose circuits a connection
//! uses; the password is ignored. No auth means the default site (Chrome).

use std::future::Future;
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr};

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::isolation::DEFAULT_SITE;

pub const SUCCEEDED: u8 = 0x00;
pub const HOST_UNREACHABLE: u8 = 0x04;
pub const COMMAND_NOT_SUPPORTED: u8 = 0x07;
pub const ADDRESS_NOT_SUPPORTED: u8 = 0x08;

const NO_AUTH: u8 = 0x00;
const USER_PASS: u8 = 0x02;
const NO_ACCEPTABLE: u8 = 0xFF;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SocksRequest {
    pub site: String,
    pub host: String,
    pub port: u16,
}

/// Opens the outgoing side of a SOCKS connection.
pub trait Connector: Send + Sync + 'static {
    type Stream: AsyncRead + AsyncWrite + Unpin + Send + 'static;
    fn connect(&self, req: SocksRequest) -> impl Future<Output = io::Result<Self::Stream>> + Send;
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_owned())
}

/// Run the SOCKS5 greeting, auth and request; return what was asked for.
/// On a request this server can't serve, the error reply is already sent.
pub async fn handshake<S: AsyncRead + AsyncWrite + Unpin>(s: &mut S) -> io::Result<SocksRequest> {
    let [ver, n] = [s.read_u8().await?, s.read_u8().await?];
    if ver != 5 {
        return Err(bad("not SOCKS5"));
    }
    let mut methods = vec![0u8; n as usize];
    s.read_exact(&mut methods).await?;

    let site = if methods.contains(&USER_PASS) {
        s.write_all(&[5, USER_PASS]).await?;
        if s.read_u8().await? != 1 {
            return Err(bad("bad auth version"));
        }
        let mut user = vec![0u8; s.read_u8().await? as usize];
        s.read_exact(&mut user).await?;
        let mut pass = vec![0u8; s.read_u8().await? as usize];
        s.read_exact(&mut pass).await?;
        s.write_all(&[1, 0]).await?;
        let user = String::from_utf8(user).map_err(|_| bad("username is not UTF-8"))?;
        if user.is_empty() { DEFAULT_SITE.to_owned() } else { user }
    } else if methods.contains(&NO_AUTH) {
        s.write_all(&[5, NO_AUTH]).await?;
        DEFAULT_SITE.to_owned()
    } else {
        s.write_all(&[5, NO_ACCEPTABLE]).await?;
        return Err(bad("no acceptable auth method"));
    };

    let mut head = [0u8; 4];
    s.read_exact(&mut head).await?;
    let [ver, cmd, _rsv, atyp] = head;
    if ver != 5 {
        return Err(bad("not SOCKS5"));
    }
    if cmd != 1 {
        reply(s, COMMAND_NOT_SUPPORTED).await?;
        return Err(bad("only CONNECT is supported"));
    }
    let host = match atyp {
        1 => {
            let mut a = [0u8; 4];
            s.read_exact(&mut a).await?;
            Ipv4Addr::from(a).to_string()
        }
        3 => {
            let mut name = vec![0u8; s.read_u8().await? as usize];
            s.read_exact(&mut name).await?;
            String::from_utf8(name).map_err(|_| bad("host name is not UTF-8"))?
        }
        4 => {
            let mut a = [0u8; 16];
            s.read_exact(&mut a).await?;
            Ipv6Addr::from(a).to_string()
        }
        _ => {
            reply(s, ADDRESS_NOT_SUPPORTED).await?;
            return Err(bad("unknown address type"));
        }
    };
    let port = s.read_u16().await?;
    Ok(SocksRequest { site, host, port })
}

/// Send a reply with `code` and an all-zero bound address.
pub async fn reply<S: AsyncWrite + Unpin>(s: &mut S, code: u8) -> io::Result<()> {
    s.write_all(&[5, code, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
    s.flush().await
}

/// Serve one client: handshake, connect through `connector`, then relay bytes
/// both ways until either side closes.
pub async fn handle<S, C>(mut client: S, connector: &C) -> io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
    C: Connector,
{
    let req = handshake(&mut client).await?;
    match connector.connect(req).await {
        Ok(mut upstream) => {
            reply(&mut client, SUCCEEDED).await?;
            match tokio::io::copy_bidirectional(&mut client, &mut upstream).await {
                // Arti reports a stream the far end already closed as "not
                // connected" when we shut it down: that's a normal end.
                Err(e) if e.kind() != io::ErrorKind::NotConnected => Err(e),
                _ => Ok(()),
            }
        }
        Err(e) => {
            reply(&mut client, HOST_UNREACHABLE).await?;
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use tokio::io::{DuplexStream, duplex};

    /// Records requests; answers with one end of a pipe whose other end echoes.
    #[derive(Default)]
    struct EchoConnector {
        seen: Arc<Mutex<Vec<SocksRequest>>>,
        fail: bool,
    }

    impl Connector for EchoConnector {
        type Stream = DuplexStream;
        fn connect(&self, req: SocksRequest) -> impl Future<Output = io::Result<DuplexStream>> + Send {
            self.seen.lock().unwrap().push(req);
            let fail = self.fail;
            async move {
                if fail {
                    return Err(io::Error::other("unreachable"));
                }
                let (ours, mut theirs) = duplex(1024);
                tokio::spawn(async move {
                    let mut buf = [0u8; 64];
                    while let Ok(n) = theirs.read(&mut buf).await {
                        if n == 0 || theirs.write_all(&buf[..n]).await.is_err() {
                            break;
                        }
                    }
                });
                Ok(ours)
            }
        }
    }

    fn user_pass_hello(user: &str) -> Vec<u8> {
        let mut v = vec![5, 1, USER_PASS, 1, user.len() as u8];
        v.extend_from_slice(user.as_bytes());
        v.extend_from_slice(&[1, b'x']);
        v
    }

    fn connect_domain(host: &str, port: u16) -> Vec<u8> {
        let mut v = vec![5, 1, 0, 3, host.len() as u8];
        v.extend_from_slice(host.as_bytes());
        v.extend_from_slice(&port.to_be_bytes());
        v
    }

    #[tokio::test]
    async fn username_names_the_site() {
        let (mut client, mut server) = duplex(1024);
        let mut bytes = user_pass_hello("github.com");
        bytes.extend(connect_domain("api.github.com", 443));
        client.write_all(&bytes).await.unwrap();
        let req = handshake(&mut server).await.unwrap();
        assert_eq!(req, SocksRequest { site: "github.com".into(), host: "api.github.com".into(), port: 443 });
        let mut answer = [0u8; 4];
        client.read_exact(&mut answer).await.unwrap();
        assert_eq!(answer, [5, USER_PASS, 1, 0]);
    }

    #[tokio::test]
    async fn no_auth_uses_default_site() {
        let (mut client, mut server) = duplex(1024);
        let mut bytes = vec![5, 1, NO_AUTH];
        bytes.extend([5, 1, 0, 1, 93, 184, 216, 34, 0, 80]);
        client.write_all(&bytes).await.unwrap();
        let req = handshake(&mut server).await.unwrap();
        assert_eq!(req, SocksRequest { site: DEFAULT_SITE.into(), host: "93.184.216.34".into(), port: 80 });
    }

    #[tokio::test]
    async fn bind_is_refused() {
        let (mut client, mut server) = duplex(1024);
        client.write_all(&[5, 1, NO_AUTH, 5, 2, 0, 1, 0, 0, 0, 0, 0, 80]).await.unwrap();
        assert!(handshake(&mut server).await.is_err());
        let mut answer = [0u8; 12];
        client.read_exact(&mut answer).await.unwrap();
        assert_eq!(&answer[2..4], &[5, COMMAND_NOT_SUPPORTED]);
    }

    #[tokio::test]
    async fn relays_bytes_after_connect() {
        let connector = EchoConnector::default();
        let seen = connector.seen.clone();
        let (mut client, server) = duplex(1024);
        let task = tokio::spawn(async move { handle(server, &connector).await });
        let mut bytes = user_pass_hello("example.com");
        bytes.extend(connect_domain("example.com", 80));
        client.write_all(&bytes).await.unwrap();
        let mut answer = [0u8; 4 + 10];
        client.read_exact(&mut answer).await.unwrap();
        assert_eq!(answer[5], SUCCEEDED);
        client.write_all(b"ping").await.unwrap();
        let mut echo = [0u8; 4];
        client.read_exact(&mut echo).await.unwrap();
        assert_eq!(&echo, b"ping");
        drop(client);
        let _ = task.await;
        assert_eq!(seen.lock().unwrap()[0].site, "example.com");
    }

    #[tokio::test]
    async fn failed_connect_replies_host_unreachable() {
        let connector = EchoConnector { fail: true, ..Default::default() };
        let (mut client, server) = duplex(1024);
        let task = tokio::spawn(async move { handle(server, &connector).await });
        let mut bytes = vec![5, 1, NO_AUTH];
        bytes.extend(connect_domain("example.com", 80));
        client.write_all(&bytes).await.unwrap();
        let mut answer = [0u8; 2 + 10];
        client.read_exact(&mut answer).await.unwrap();
        assert_eq!(answer[3], HOST_UNREACHABLE);
        assert!(task.await.unwrap().is_err());
    }
}
```

- [ ] **Step 3: Run the tests**

Run: `cd helper && cargo test -p tortuga-helper socks`
Expected: `test result: ok. 5 passed`

- [ ] **Step 4: Commit**

```bash
git add helper/tortuga-helper/src
git commit -m "helper: SOCKS5 server with site usernames"
```

---

### Task 6: Paths and Arti config

**Files:**
- Create: `helper/tortuga-helper/src/config.rs`
- Modify: `helper/tortuga-helper/src/main.rs` (add `mod config;`)

**Interfaces:**
- Consumes: `protocol::{BridgeChoice, BridgeKind}` (Task 3).
- Produces: `Paths { state_dir, cache_dir, lyrebird, pt_config: PathBuf }` with `Paths::discover() -> anyhow::Result<Paths>`; `fn default_snowflake_lines(pt_config_json: &str) -> anyhow::Result<Vec<String>>`; `fn tor_config(choice: &BridgeChoice, paths: &Paths, default_snowflake: &[String]) -> anyhow::Result<TorClientConfig>`.

- [ ] **Step 1: Stub and see the tests fail**

Write `config.rs` from the listing in Step 2 as a stub; add `mod config;`.
Run: `cd helper && cargo test -p tortuga-helper config`
Expected: 5 tests FAIL.

- [ ] **Step 2: Implement**

`helper/tortuga-helper/src/config.rs`:

```rust
//! Where the helper keeps its files, and the Arti config for a bridge choice.

use std::path::PathBuf;

use arti_client::config::pt::TransportConfigBuilder;
use arti_client::config::{BridgeConfigBuilder, CfgPath, TorClientConfig, TorClientConfigBuilder};

use crate::protocol::{BridgeChoice, BridgeKind};

/// The helper's own directories and the bundled transport.
#[derive(Debug, Clone)]
pub struct Paths {
    pub state_dir: PathBuf,
    pub cache_dir: PathBuf,
    /// `lyrebird`, serving obfs4, WebTunnel, meek and Snowflake.
    pub lyrebird: PathBuf,
    /// The Expert Bundle's `pt_config.json`, for the default Snowflake bridges.
    pub pt_config: PathBuf,
}

impl Paths {
    /// Data under `TORTUGA_DATA_DIR` if set (tests, cold-start runs), else the
    /// platform's data and cache dirs. Transports under `TORTUGA_PT_DIR` if
    /// set, else `pt/` next to the executable.
    pub fn discover() -> anyhow::Result<Self> {
        let (state_dir, cache_dir) = match std::env::var_os("TORTUGA_DATA_DIR") {
            Some(d) => {
                let d = PathBuf::from(d);
                (d.join("state"), d.join("cache"))
            }
            None => {
                let dirs = directories::ProjectDirs::from("org", "Tortuga", "tortuga-helper")
                    .ok_or_else(|| anyhow::anyhow!("no home directory"))?;
                (dirs.data_dir().join("arti-state"), dirs.cache_dir().join("arti-cache"))
            }
        };
        let pt_dir = match std::env::var_os("TORTUGA_PT_DIR") {
            Some(d) => PathBuf::from(d),
            None => std::env::current_exe()?
                .parent()
                .ok_or_else(|| anyhow::anyhow!("executable has no directory"))?
                .join("pt"),
        };
        let exe = if cfg!(windows) { "lyrebird.exe" } else { "lyrebird" };
        Ok(Self { state_dir, cache_dir, lyrebird: pt_dir.join(exe), pt_config: pt_dir.join("pt_config.json") })
    }
}

/// The default Snowflake bridge lines from the Expert Bundle's `pt_config.json`.
pub fn default_snowflake_lines(pt_config_json: &str) -> anyhow::Result<Vec<String>> {
    let v: serde_json::Value = serde_json::from_str(pt_config_json)?;
    let lines = v["bridges"]["snowflake"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("pt_config.json has no snowflake bridges"))?
        .iter()
        .filter_map(|l| l.as_str())
        .map(|l| format!("Bridge {l}"))
        .collect::<Vec<_>>();
    anyhow::ensure!(!lines.is_empty(), "pt_config.json has no snowflake bridges");
    Ok(lines)
}

/// The Arti config for `choice`: own directories, and for bridge kinds only
/// those bridges, through `lyrebird`.
pub fn tor_config(choice: &BridgeChoice, paths: &Paths, default_snowflake: &[String]) -> anyhow::Result<TorClientConfig> {
    let mut builder = TorClientConfigBuilder::from_directories(&paths.state_dir, &paths.cache_dir);
    let (protocol, lines): (&str, Vec<String>) = match choice.kind {
        BridgeKind::None => return Ok(builder.build()?),
        BridgeKind::Snowflake if choice.lines.is_empty() => ("snowflake", default_snowflake.to_vec()),
        BridgeKind::Snowflake => ("snowflake", choice.lines.clone()),
        BridgeKind::Obfs4 => ("obfs4", choice.lines.clone()),
        BridgeKind::Webtunnel => ("webtunnel", choice.lines.clone()),
    };
    anyhow::ensure!(!lines.is_empty(), "{protocol} needs at least one bridge line");
    for line in &lines {
        let bridge: BridgeConfigBuilder = line.parse()?;
        builder.bridges().bridges().push(bridge);
    }
    let mut transport = TransportConfigBuilder::default();
    transport
        .protocols(vec![protocol.parse()?])
        .path(CfgPath::new_literal(&paths.lyrebird))
        .run_on_startup(true);
    builder.bridges().transports().push(transport);
    Ok(builder.build()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Made-up obfs4 line from arti-client's own documentation.
    const FAKE_OBFS4: &str = "Bridge obfs4 192.0.2.55:38114 316E643333645F6D79216558614D3931657A5F5F cert=YXJlIGZyZXF1ZW50bHkgZnVsbCBvZiBsaXR0bGUgbWVzc2FnZXMgeW91IGNhbiBmaW5kLg iat-mode=0";
    const FAKE_SNOWFLAKE: &str = "Bridge snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72";

    fn paths() -> Paths {
        Paths {
            state_dir: "/tmp/tortuga-test/state".into(),
            cache_dir: "/tmp/tortuga-test/cache".into(),
            lyrebird: "/tmp/tortuga-test/pt/lyrebird".into(),
            pt_config: "/tmp/tortuga-test/pt/pt_config.json".into(),
        }
    }

    fn choice(kind: BridgeKind, lines: &[&str]) -> BridgeChoice {
        BridgeChoice { kind, lines: lines.iter().map(|s| s.to_string()).collect() }
    }

    #[test]
    fn no_bridge_builds() {
        assert!(tor_config(&choice(BridgeKind::None, &[]), &paths(), &[]).is_ok());
    }

    #[test]
    fn snowflake_falls_back_to_defaults() {
        let defaults = vec![FAKE_SNOWFLAKE.to_string()];
        assert!(tor_config(&choice(BridgeKind::Snowflake, &[]), &paths(), &defaults).is_ok());
        assert!(tor_config(&choice(BridgeKind::Snowflake, &[]), &paths(), &[]).is_err());
    }

    #[test]
    fn obfs4_needs_lines() {
        assert!(tor_config(&choice(BridgeKind::Obfs4, &[FAKE_OBFS4]), &paths(), &[]).is_ok());
        assert!(tor_config(&choice(BridgeKind::Obfs4, &[]), &paths(), &[]).is_err());
    }

    #[test]
    fn bad_line_is_an_error() {
        assert!(tor_config(&choice(BridgeKind::Obfs4, &["Bridge nonsense"]), &paths(), &[]).is_err());
    }

    #[test]
    fn reads_default_snowflake_lines() {
        let json = r#"{"bridges": {"snowflake": ["snowflake 192.0.2.3:80 AAAA", "snowflake 192.0.2.4:80 BBBB"]}}"#;
        assert_eq!(
            default_snowflake_lines(json).unwrap(),
            vec!["Bridge snowflake 192.0.2.3:80 AAAA", "Bridge snowflake 192.0.2.4:80 BBBB"]
        );
        assert!(default_snowflake_lines(r#"{"bridges": {}}"#).is_err());
    }
}
```

- [ ] **Step 3: Run the tests**

Run: `cd helper && cargo test -p tortuga-helper config`
Expected: `test result: ok. 5 passed`

- [ ] **Step 4: Commit**

```bash
git add helper/tortuga-helper/src
git commit -m "helper: own data dirs and Arti config per bridge choice"
```

---

### Task 7: Tor, request handling and the main loop

**Files:**
- Create: `helper/tortuga-helper/src/tor.rs`, `helper/tortuga-helper/src/app.rs`
- Modify: `helper/tortuga-helper/src/main.rs` (final version)

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: `tor::phase_for(frac: f32, ready: bool) -> Phase`; `tor::Events = UnboundedSender<Message>`; `Tor::start(config, bridge, events) -> anyhow::Result<Arc<Tor>>`, `Tor::restart(&self, &config, bridge)`, `Tor::sleep(&self)`, `Tor::new_circuit(&self, site)`; `impl Connector for Arc<Tor>`; `App::new(paths, events)`, `App::handle(&self, req)`. The binary `tortuga-helper`.

Behaviour to keep (spec *Helper → Lifetime*, findings):
- One Arti client per process. A second `tor.start` reconfigures it (`Reconfigure::AllOrNothing`) and wakes it; `tor.stop` closes the SOCKS port and makes it dormant (`DormantMode::Soft`).
- `tor.start` answers with `tor.ready { socksPort }` (same `id`) or `error { tor_failed }`; `tor.status` events go out meanwhile, ending with `ready` / 100.
- A `circuit` event goes out when a site's path differs from the last one sent.
- Requests before `hello` get `error { hello_required }`; a wrong protocol gets `error { protocol_mismatch }`.
- stdin closing ends the process.

- [ ] **Step 1: Write `tor.rs` with its test**

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
                    let country = target
                        .addrs()
                        .next()
                        .and_then(|a| self.geoip.lookup_country_code(a.ip()))
                        .map(|c| c.get().to_string());
                    let id = target.ed_identity().map(|e| e.to_string()).unwrap_or_default();
                    Some(Hop { role, id, country })
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

- [ ] **Step 2: Write `app.rs`**

`helper/tortuga-helper/src/app.rs`:

```rust
//! Handles requests from the extension: hello, then starting, stopping and
//! renewing Tor. Long work runs in tasks so a `tor.stop` can cancel a start.

use std::sync::Arc;

use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

use crate::config::{Paths, default_snowflake_lines, tor_config};
use crate::protocol::{BridgeChoice, ErrorCode, Message, Outgoing, PROTOCOL_VERSION, Request, RequestBody};
use crate::tor::{Events, Tor};

#[derive(Default)]
struct State {
    hello: bool,
    tor: Option<Arc<Tor>>,
    /// The bootstrap in progress, if any.
    starting: Option<JoinHandle<()>>,
    /// The SOCKS listener while Tor is on.
    socks: Option<JoinHandle<()>>,
}

#[derive(Clone)]
pub struct App {
    state: Arc<Mutex<State>>,
    paths: Paths,
    events: Events,
}

impl App {
    pub fn new(paths: Paths, events: Events) -> Self {
        Self { state: Arc::default(), paths, events }
    }

    fn send(&self, m: Message) {
        let _ = self.events.send(m);
    }

    pub async fn handle(&self, req: Request) {
        let mut state = self.state.lock().await;
        if !state.hello && !matches!(req.body, RequestBody::Hello { .. }) {
            return self.send(Message::error(Some(req.id), ErrorCode::HelloRequired, "send hello first"));
        }
        match req.body {
            RequestBody::Hello { protocol } if protocol == PROTOCOL_VERSION => {
                state.hello = true;
                let version = env!("CARGO_PKG_VERSION").to_owned();
                self.send(Message::reply(req.id, Outgoing::Hello { protocol: PROTOCOL_VERSION, version }));
            }
            RequestBody::Hello { protocol } => self.send(Message::error(
                Some(req.id),
                ErrorCode::ProtocolMismatch,
                format!("helper speaks protocol {PROTOCOL_VERSION}, extension {protocol}"),
            )),
            RequestBody::TorStart { bridge } => {
                stop(&mut state);
                let app = self.clone();
                state.starting = Some(tokio::spawn(async move { app.start(req.id, bridge).await }));
            }
            RequestBody::TorStop => {
                stop(&mut state);
                self.send(Message::reply(req.id, Outgoing::Ok));
            }
            RequestBody::TorNewCircuit { site } => match &state.tor {
                Some(tor) if state.socks.is_some() => {
                    tor.new_circuit(&site);
                    self.send(Message::reply(req.id, Outgoing::Ok));
                }
                _ => self.send(Message::error(Some(req.id), ErrorCode::NotRunning, "Tor is off")),
            },
        }
    }

    async fn start(&self, id: u64, bridge: BridgeChoice) {
        match self.try_start(&bridge).await {
            Ok(socks_port) => self.send(Message::reply(id, Outgoing::TorReady { socks_port })),
            Err(e) => self.send(Message::error(Some(id), ErrorCode::TorFailed, format!("{e:#}"))),
        }
    }

    async fn try_start(&self, bridge: &BridgeChoice) -> anyhow::Result<u16> {
        let defaults = match std::fs::read_to_string(&self.paths.pt_config) {
            Ok(json) => default_snowflake_lines(&json)?,
            Err(_) => Vec::new(),
        };
        let config = tor_config(bridge, &self.paths, &defaults)?;
        let existing = self.state.lock().await.tor.clone();
        let tor = match existing {
            Some(tor) => {
                tor.restart(&config, bridge.kind).await?;
                tor
            }
            None => Tor::start(config, bridge.kind, self.events.clone()).await?,
        };
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let port = listener.local_addr()?.port();
        let socks = tokio::spawn(serve(listener, tor.clone()));
        let mut state = self.state.lock().await;
        state.tor = Some(tor);
        state.socks = Some(socks);
        state.starting = None;
        Ok(port)
    }
}

/// Cancel a start in progress, close the SOCKS port and let Tor sleep.
fn stop(state: &mut State) {
    if let Some(t) = state.starting.take() {
        t.abort();
    }
    if let Some(s) = state.socks.take() {
        s.abort();
    }
    if let Some(tor) = &state.tor {
        tor.sleep();
    }
}

async fn serve(listener: TcpListener, tor: Arc<Tor>) {
    while let Ok((client, _)) = listener.accept().await {
        let tor = tor.clone();
        tokio::spawn(async move {
            if let Err(e) = crate::socks::handle(client, &tor).await {
                eprintln!("socks: {e}");
            }
        });
    }
}
```

- [ ] **Step 3: Write the final `main.rs`**

`helper/tortuga-helper/src/main.rs`:

```rust
//! tortuga-helper: the native messaging host the Tortuga extension starts.
//! stdin/stdout carry framed JSON messages; logs go to stderr only.

mod app;
mod config;
mod framing;
mod hops;
mod isolation;
mod protocol;
mod socks;
mod tor;

use protocol::{ErrorCode, Message, Request};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let (events, mut outbox) = tokio::sync::mpsc::unbounded_channel::<Message>();

    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(m) = outbox.recv().await {
            let bytes = serde_json::to_vec(&m)?;
            framing::write_message(&mut stdout, &bytes).await?;
        }
        anyhow::Ok(())
    });

    let app = app::App::new(config::Paths::discover()?, events.clone());
    let mut stdin = tokio::io::stdin();
    // The browser closes stdin when the extension disconnects: then we exit,
    // taking Tor with us.
    while let Some(bytes) = framing::read_message(&mut stdin).await? {
        match serde_json::from_slice::<Request>(&bytes) {
            Ok(req) => app.handle(req).await,
            Err(e) => {
                let _ = events.send(Message::error(None, ErrorCode::BadRequest, e));
            }
        }
    }
    drop(app);
    drop(events);
    let _ = tokio::time::timeout(std::time::Duration::from_secs(1), writer).await;
    Ok(())
}
```

- [ ] **Step 4: Build and run all tests**

Run: `cd helper && cargo build --release -p tortuga-helper 2>&1 | grep -E "^(warning|error)"; cargo test -p tortuga-helper`
Expected: no warnings or errors printed by the first command; `test result: ok. 25 passed`.

- [ ] **Step 5: Commit**

```bash
git add helper/tortuga-helper/src
git commit -m "helper: Tor lifecycle, request handling and main loop"
```

---

### Task 8: Transports and the end-to-end check

**Files:**
- Create: `helper/scripts/fetch-pt.sh`, `helper/scripts/nm_client.py`

**Interfaces:**
- Consumes: the `tortuga-helper` binary (Task 7).
- Produces: `helper/resources/pt/{lyrebird,pt_config.json}` (ignored by git); the e2e command used before every helper release.

- [ ] **Step 1: Write the fetch script**

`helper/scripts/fetch-pt.sh` (then `chmod +x helper/scripts/fetch-pt.sh`):

```bash
#!/usr/bin/env bash
# Put lyrebird and pt_config.json from the official Tor Expert Bundle into
# helper/resources/pt/, after checking the bundle's SHA-256.
# Usage: helper/scripts/fetch-pt.sh [TOR_BROWSER_VERSION]   (default: 16.0)
set -euo pipefail
V="${1:-16.0}"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) P=macos-aarch64 ;;
  Darwin-x86_64) P=macos-x86_64 ;;
  Linux-x86_64) P=linux-x86_64 ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
F="tor-expert-bundle-$P-$V.tar.gz"
HELPER="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HELPER/resources/pt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sSf -o "$TMP/$F" "https://dist.torproject.org/torbrowser/$V/$F"
curl -sSf -o "$TMP/sums.txt" "https://dist.torproject.org/torbrowser/$V/sha256sums-signed-build.txt"
(cd "$TMP" && grep " $F\$" sums.txt | shasum -a 256 -c -)
tar -xzf "$TMP/$F" -C "$TMP"
mkdir -p "$OUT"
cp "$TMP/tor/pluggable_transports/lyrebird" "$TMP/tor/pluggable_transports/pt_config.json" "$OUT/"
if [ "$(uname -s)" = Darwin ]; then xattr -d com.apple.quarantine "$OUT/lyrebird" 2>/dev/null || true; fi
echo "lyrebird and pt_config.json are in $OUT"
```

- [ ] **Step 2: Fetch the transports**

Run: `helper/scripts/fetch-pt.sh`
Expected: `tor-expert-bundle-macos-aarch64-16.0.tar.gz: OK`, then `lyrebird and pt_config.json are in …/helper/resources/pt`.

- [ ] **Step 3: Write the end-to-end client**

`helper/scripts/nm_client.py`:

```python
#!/usr/bin/env python3
"""End-to-end check of tortuga-helper, acting as the browser.

Usage: nm_client.py HELPER_BINARY KIND [KIND...]   (KIND: none | snowflake)

Starts the helper, says hello, starts Tor, fetches check.torproject.org through
the SOCKS port as two sites, renews one site's circuit, and stops Tor. Prints
every message with the seconds since start. Exits non-zero on any failure.
"""
import json, queue, struct, subprocess, sys, threading, time

T0 = time.monotonic()

def log(*a):
    print(f"[{time.monotonic() - T0:6.1f}s]", *a, flush=True)

def send(p, msg):
    b = json.dumps(msg).encode()
    p.stdin.write(struct.pack("=I", len(b)) + b)
    p.stdin.flush()

def reader(p, q):
    while True:
        h = p.stdout.read(4)
        if len(h) < 4:
            q.put(None)
            return
        q.put(json.loads(p.stdout.read(struct.unpack("=I", h)[0])))

def wait_for(q, pred, timeout, seen):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            m = q.get(timeout=max(0.1, end - time.monotonic()))
        except queue.Empty:
            break
        if m is None:
            sys.exit("helper exited")
        log(json.dumps(m))
        seen.append(m)
        if pred(m):
            return m
    sys.exit("timed out")

def fetch(port, site):
    out = subprocess.run(
        ["curl", "-s", "--max-time", "60", "-x", f"socks5h://{site}:x@127.0.0.1:{port}",
         "https://check.torproject.org/api/ip"],
        capture_output=True, text=True)
    log(f"curl as {site}:", out.stdout.strip() or out.stderr.strip())
    if '"IsTor":true' not in out.stdout:
        sys.exit(f"{site}: not through Tor")

def main():
    helper, kinds = sys.argv[1], sys.argv[2:]
    p = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    q, seen = queue.Queue(), []
    threading.Thread(target=reader, args=(p, q), daemon=True).start()

    send(p, {"id": 1, "type": "hello", "payload": {"protocol": 1}})
    wait_for(q, lambda m: m.get("id") == 1 and m["type"] == "hello", 10, seen)

    # Each kind runs in the same helper process: the second start reconfigures
    # the client that the first one created.
    for n, kind in enumerate(kinds):
        base = 10 * (n + 1)
        log(f"--- bridge: {kind}")
        send(p, {"id": base, "type": "tor.start", "payload": {"bridge": {"kind": kind}}})
        ready = wait_for(q, lambda m: m.get("id") == base and m["type"] in ("tor.ready", "error"), 300, seen)
        if ready["type"] == "error":
            sys.exit("tor.start failed")
        port = ready["payload"]["socksPort"]
        log(f"Tor ready on port {port}")

        for site in ("site-a.test", "site-b.test"):
            fetch(port, site)
        time.sleep(1)
        circuits = {}
        while not q.empty():
            m = q.get()
            log(json.dumps(m))
            if m and m["type"] == "circuit":
                circuits[m["payload"]["site"]] = m["payload"]
        if set(circuits) != {"site-a.test", "site-b.test"}:
            sys.exit(f"expected circuit events for both sites, got {sorted(circuits)}")
        if circuits["site-a.test"]["hops"] == circuits["site-b.test"]["hops"]:
            sys.exit("both sites share a circuit")
        want_bridge = None if kind == "none" else kind
        if any(c["bridge"] != want_bridge for c in circuits.values()):
            sys.exit(f"circuits do not go through bridge {want_bridge}")

        send(p, {"id": base + 1, "type": "tor.newCircuit", "payload": {"site": "site-a.test"}})
        wait_for(q, lambda m: m.get("id") == base + 1, 10, seen)
        fetch(port, "site-a.test")
        renewed = wait_for(q, lambda m: m["type"] == "circuit" and m["payload"]["site"] == "site-a.test", 30, seen)
        if renewed["payload"]["hops"] == circuits["site-a.test"]["hops"]:
            sys.exit("new circuit has the same path")

        send(p, {"id": base + 2, "type": "tor.stop"})
        wait_for(q, lambda m: m.get("id") == base + 2 and m["type"] == "ok", 10, seen)
    p.stdin.close()
    p.wait(timeout=10)
    log("PASS")

main()
```

- [ ] **Step 4: Run it from a cold start: Snowflake, then no bridge, in one process**

Run:

```bash
cd helper && rm -rf /tmp/tortuga-e2e && \
TORTUGA_DATA_DIR=/tmp/tortuga-e2e TORTUGA_PT_DIR="$(pwd)/resources/pt" \
perl -e 'alarm 600; exec @ARGV' python3 -I scripts/nm_client.py target/release/tortuga-helper snowflake none \
| grep -v '"tor.status"'
```

Expected (times and ids differ): a `hello` reply; `--- bridge: snowflake`; `tor.ready` with a port within about 30 s on a cold start (measured 22 s while planning); `"IsTor":true` for `site-a.test` and `site-b.test` with different IPs; two `circuit` events with `"bridge": "snowflake"` and a first hop of role `bridge`; an `ok` for `tor.newCircuit` and a new `site-a.test` circuit; `--- bridge: none` with `"bridge": null` circuits whose first hop is `guard`; finally `PASS`. No `socks:` lines on stderr.
Write down the cold-start time to `tor.ready`: it goes into the spec in Task 9.

- [ ] **Step 5: Commit**

```bash
git add helper/scripts
git commit -m "helper: transport fetch script and end-to-end check"
```

---

### Task 9: Bring the spec in line

**Files:**
- Modify: `docs/superpowers/specs/2026-11-05-tortuga-design.md`

- [ ] **Step 1: Apply what this plan settled**

Make exactly these edits:
1. In the helper→extension table, change the `tor.status` payload to `{ phase: 'bridge' \| 'directory' \| 'ready', percent, blocked }` and add below the table: "Arti reports one bootstrap fraction (15 % first hop, 85 % directory); the phases follow that split. There is no separate circuit phase."
2. In *Popup (two tabs)*, change the connecting line to light up "station by station from `tor.status` phases (first hop, directory, ready)".
3. In *Errors*, replace "**Tor not ready after 30 s:**" with "**No bootstrap progress for 30 s:**" and add: "A cold start through Snowflake took <time from Task 8 Step 4> s, so a fixed 30 s limit would fire on healthy starts."
4. In the extension→helper table, add under it: "Replies: `tor.start` → `tor.ready { socksPort }`; `tor.stop` and `tor.newCircuit` → `ok`; any failure → `error { code, message }` with the request's `id`. Codes: `bad_request`, `hello_required`, `protocol_mismatch`, `tor_failed`, `not_running`."

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-11-05-tortuga-design.md
git commit -m "docs: spec follows the helper core"
```

---

## Next plans

1. **Extension Tor mode** — `extension/` from Nomada's layout and tokens; `connectNative` + `hello`; Firefox `proxy.onRequest` with site usernames (`tldts`), `resistFingerprinting`, WebRTC off; Chrome incognito scope; fail-closed red state; popup Route tab (metro diagram from `circuit` events, connecting animation from `tor.status`, bridge picker, New circuit); settings page. Dev setup registers the native host manifest pointing at `helper/target/release/tortuga-helper`.
2. **Moat bridges** — `bridges.fetch` over meek through `lyrebird`, and the **Get a bridge** button.
3. **Torrents** — `librqbit`, `torrent.*` messages, persistence, Downloads tab, link capture, context menu, confirm window.
4. **Installers and release.**
