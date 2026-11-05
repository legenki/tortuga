# Moat Bridges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Get obfs4 lines" / "Get WebTunnel lines" on the settings page ask the Tor Project's Moat service (bridges.torproject.org) for bridge lines, fill and save them — directly, or through Tor when the site is blocked and Tor already runs on Snowflake.

**Architecture:** The helper gets `moat.rs` (two Moat endpoints over `reqwest`, optionally through its own SOCKS port) and a `bridges.fetch { kind }` request answered with `bridges.lines`. The extension sends it through the Tor helper while Tor is on (so it can fall back to Tor), otherwise through the downloads helper (direct only). Domain fronting (meek) is not used: its front parameters change and can't be verified here; Snowflake needs no lines, so it is the way in when Moat is blocked.

**Tech Stack:** Rust (`reqwest` =0.13.5 with `json`, `socks` — already in the tree through librqbit), TypeScript, Python 3 e2e, headless Firefox over BiDi.

Spec: `docs/superpowers/specs/2026-11-05-tortuga-design.md` (*Helper → Tor*, *Settings page*).

## Global Constraints

- Moat base `https://bridges.torproject.org/moat/circumvention`; `TORTUGA_MOAT_URL` overrides it (tests); `TORTUGA_MOAT_NO_DIRECT` skips the direct try (to exercise the way through Tor).
- Requests: `POST settings { transports: [kind] }` (Moat finds the country from the address), then if it has no lines of that kind `POST builtin { transports: [kind] }`; header `Content-Type: application/vnd.api+json`; 30 s timeout.
- Through Tor: `socks5h://127.0.0.1:<the helper's SOCKS port>`, so the name is resolved by Tor.
- "Moat answered but has no lines" (`NoLines`) is returned as is, without retrying through Tor; only failed requests fall back.
- Lines come back raw (`obfs4 …`); the settings page runs them through `parseLines` and stores them as `Bridge …`.
- Facts found while planning (2026-11-05, from an Italian address): `settings` answers `{"settings":[],"country":"it"}`; `builtin` has 7 obfs4 lines (3 unique), 2 Snowflake, 1 meek and **no WebTunnel**; for `country: "ru"` `settings` hands out BridgeDB lines for snowflake, webtunnel and obfs4. Of the 3 built-in obfs4 bridges only `212.83.43.95:443` answered from this network; Arti tried the others first and took about 5 minutes to bootstrap.

## File Structure

| File | Change |
|---|---|
| `helper/tortuga-helper/Cargo.toml` | `reqwest` |
| `helper/tortuga-helper/src/moat.rs` (new) | Moat requests, answer parsing, `NoLines` |
| `helper/tortuga-helper/src/protocol.rs`, `app.rs`, `main.rs` | `bridges.fetch` → `bridges.lines`, `bridges_failed`, fallback through Tor |
| `helper/scripts/moat_check.py` (new) | End-to-end check, ending with Tor on the fetched lines |
| `extension/src/lib/protocol.ts`, `messages.ts`, `bridges.ts` | `FetchedLines`, `BridgesMessage`, `fetchedText` |
| `extension/src/background/controller.ts`, `downloads.ts`, `index.ts` | `fetchBridges`, `FETCH_BRIDGES` |
| `extension/src/options/index.html`, `index.ts`, `style.css` | Get … lines buttons |
| `extension/src/popup/index.ts` | "get lines in Settings" |
| `extension/tests/{controller,downloads,bridges}.test.ts` | New cases |
| `extension/scripts/live-check/{run.sh,bridges.mjs}` | `run.sh bridges` |

Listings are final content: write each file as shown (for changed files, replace the whole file).

---

### Task 1: Moat client in the helper

**Files:**
- Modify: `helper/tortuga-helper/Cargo.toml`, `helper/tortuga-helper/src/main.rs` (add `mod moat;`)
- Create: `helper/tortuga-helper/src/moat.rs`

**Interfaces:**
- Produces: `MOAT`; `enum LineKind { Obfs4, Webtunnel }` (lowercase serde); `enum Route { Direct, Tor { socks_port } }`; `struct Fetched { lines, source, country: Option<String>, via_tor }` (camelCase); `struct NoLines(String)` (an `Error`); `lines_from_settings(answer, kind)`, `lines_from_builtin(answer, kind)`, `fetch(kind, route, base) -> anyhow::Result<Fetched>`.

- [ ] **Step 1: Dependency and the tests first**

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
librqbit = "=9.1.0"
librqbit-core = "=9.1.0"
base64 = "0.22"
reqwest = { version = "=0.13.5", features = ["json", "socks"] }
anyhow = "1"
```

Create `moat.rs` with only its `#[cfg(test)] mod tests` from the listing in Step 2; add `mod moat;` to `main.rs`.
Run: `cd helper && cargo test -p tortuga-helper moat`
Expected: compile errors — `cannot find function lines_from_settings`, `lines_from_builtin`, `fetch`, type `LineKind`, `NoLines`.

- [ ] **Step 2: Implement**

`helper/tortuga-helper/src/moat.rs`:

```rust
//! Bridge lines from the Tor Project's Moat service (bridges.torproject.org),
//! as Tor Browser's Connection Assist gets them:
//! - `circumvention/settings` answers for the caller's country (it finds it
//!   from the address): bridges from BridgeDB where Tor is blocked, an empty
//!   list where it isn't;
//! - `circumvention/builtin` lists the public built-in bridges (obfs4 and
//!   Snowflake, no WebTunnel).
//! Requests go directly, or through Tor's own SOCKS port when the direct way
//! is blocked and Tor already runs (e.g. on Snowflake).

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::json;

pub const MOAT: &str = "https://bridges.torproject.org/moat/circumvention";
const TIMEOUT: Duration = Duration::from_secs(30);

/// The transports Moat can give lines for and the extension stores.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LineKind {
    Obfs4,
    Webtunnel,
}

impl LineKind {
    fn name(self) -> &'static str {
        match self {
            LineKind::Obfs4 => "obfs4",
            LineKind::Webtunnel => "webtunnel",
        }
    }
}

/// How the request leaves: directly, or through Tor's SOCKS port.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    Direct,
    Tor { socks_port: u16 },
}

/// Lines for one transport, and where they came from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Fetched {
    pub lines: Vec<String>,
    /// "bridgedb" (handed out for this network) or "builtin" (public defaults).
    pub source: String,
    /// The country Moat saw, when it said.
    pub country: Option<String>,
    /// Whether the answer came through Tor.
    pub via_tor: bool,
}

#[derive(Debug, Deserialize)]
struct SettingsAnswer {
    #[serde(default)]
    settings: Option<Vec<Setting>>,
    country: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Setting {
    bridges: SettingBridges,
}

#[derive(Debug, Deserialize)]
struct SettingBridges {
    #[serde(rename = "type")]
    kind: String,
    source: Option<String>,
    #[serde(default)]
    bridge_strings: Option<Vec<String>>,
}

/// Lines of `kind` in a `settings` answer, with their source; None when there are none.
pub fn lines_from_settings(answer: &str, kind: LineKind) -> anyhow::Result<(Option<(Vec<String>, String)>, Option<String>)> {
    let a: SettingsAnswer = serde_json::from_str(answer)?;
    let found = a.settings.unwrap_or_default().into_iter().find_map(|s| {
        let lines = s.bridges.bridge_strings.unwrap_or_default();
        (s.bridges.kind == kind.name() && !lines.is_empty()).then(|| (dedup(lines), s.bridges.source.unwrap_or_else(|| "bridgedb".into())))
    });
    Ok((found, a.country))
}

/// Lines of `kind` in a `builtin` answer (a map from transport to lines), without repeats.
pub fn lines_from_builtin(answer: &str, kind: LineKind) -> anyhow::Result<Vec<String>> {
    let mut map: std::collections::HashMap<String, Vec<String>> = serde_json::from_str(answer)?;
    Ok(dedup(map.remove(kind.name()).unwrap_or_default()))
}

/// Moat answered, but has no lines of this kind for this network. Asking
/// again another way won't help, unlike a failed request.
#[derive(Debug)]
pub struct NoLines(pub String);

impl std::fmt::Display for NoLines {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for NoLines {}

fn dedup(lines: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    lines.into_iter().filter(|l| seen.insert(l.clone())).collect()
}

fn client(route: Route) -> anyhow::Result<reqwest::Client> {
    let mut b = reqwest::Client::builder().timeout(TIMEOUT);
    if let Route::Tor { socks_port } = route {
        // socks5h: the name is resolved by Tor, not locally.
        b = b.proxy(reqwest::Proxy::all(format!("socks5h://127.0.0.1:{socks_port}"))?);
    }
    Ok(b.build()?)
}

async fn post(client: &reqwest::Client, base: &str, path: &str, body: serde_json::Value) -> anyhow::Result<String> {
    let res = client
        .post(format!("{base}/{path}"))
        .header("Content-Type", "application/vnd.api+json")
        .body(body.to_string())
        .send()
        .await?
        .error_for_status()?;
    Ok(res.text().await?)
}

/// Lines for `kind`: what Moat hands out for this network, else the built-in ones.
pub async fn fetch(kind: LineKind, route: Route, base: &str) -> anyhow::Result<Fetched> {
    let client = client(route)?;
    let via_tor = matches!(route, Route::Tor { .. });
    let settings = post(&client, base, "settings", json!({ "transports": [kind.name()] })).await?;
    let (found, country) = lines_from_settings(&settings, kind)?;
    if let Some((lines, source)) = found {
        return Ok(Fetched { lines, source, country, via_tor });
    }
    let builtin = post(&client, base, "builtin", json!({ "transports": [kind.name()] })).await?;
    let lines = lines_from_builtin(&builtin, kind)?;
    if lines.is_empty() {
        return Err(NoLines(format!(
            "bridges.torproject.org has no {} bridges for this network{} — it says none are needed here. Paste lines from bridges.torproject.org instead.",
            kind.name(),
            country.as_deref().map(|c| format!(" ({c})")).unwrap_or_default()
        ))
        .into());
    }
    Ok(Fetched { lines, source: "builtin".into(), country, via_tor })
}

#[cfg(test)]
mod tests {
    use super::*;

    const RU: &str = r#"{"settings":[
        {"bridges":{"type":"snowflake","source":"bridgedb","bridge_strings":["snowflake 192.0.2.3:80 AAAA"]}},
        {"bridges":{"type":"obfs4","source":"bridgedb","bridge_strings":["obfs4 192.0.2.1:443 BBBB cert=x iat-mode=0","obfs4 192.0.2.1:443 BBBB cert=x iat-mode=0"]}}
    ],"country":"ru"}"#;

    #[test]
    fn settings_for_a_blocked_country() {
        let (found, country) = lines_from_settings(RU, LineKind::Obfs4).unwrap();
        assert_eq!(found, Some((vec!["obfs4 192.0.2.1:443 BBBB cert=x iat-mode=0".to_string()], "bridgedb".to_string())));
        assert_eq!(country.as_deref(), Some("ru"));
        assert_eq!(lines_from_settings(RU, LineKind::Webtunnel).unwrap().0, None);
    }

    #[test]
    fn settings_where_nothing_is_needed() {
        let (found, country) = lines_from_settings(r#"{"settings":[],"country":"it"}"#, LineKind::Obfs4).unwrap();
        assert_eq!(found, None);
        assert_eq!(country.as_deref(), Some("it"));
        assert_eq!(lines_from_settings(r#"{"settings":null}"#, LineKind::Obfs4).unwrap(), (None, None));
    }

    #[test]
    fn builtin_without_repeats() {
        let answer = r#"{"obfs4":["obfs4 a","obfs4 b","obfs4 a"],"snowflake":["snowflake c"]}"#;
        assert_eq!(lines_from_builtin(answer, LineKind::Obfs4).unwrap(), vec!["obfs4 a", "obfs4 b"]);
        assert!(lines_from_builtin(answer, LineKind::Webtunnel).unwrap().is_empty());
    }

    #[test]
    fn bad_answers_are_errors() {
        assert!(lines_from_settings("<html>", LineKind::Obfs4).is_err());
        assert!(lines_from_builtin("[]", LineKind::Obfs4).is_err());
    }

    #[tokio::test]
    async fn unreachable_service_is_an_error_but_not_no_lines() {
        // Port 1 on localhost: refused at once, no network involved.
        let e = fetch(LineKind::Obfs4, Route::Direct, "http://127.0.0.1:1/moat").await.unwrap_err();
        assert!(e.downcast_ref::<NoLines>().is_none());
    }
}
```

Run: `cd helper && cargo test -p tortuga-helper moat`
Expected: `5 passed` (the unreachable-service test uses `127.0.0.1:1`; no network).

- [ ] **Step 3: Commit**

```bash
git add helper/Cargo.lock helper/tortuga-helper
git commit -m "helper: Moat client for bridge lines"
```

---

### Task 2: bridges.fetch and the end-to-end check

**Files:**
- Modify: `helper/tortuga-helper/src/protocol.rs`, `helper/tortuga-helper/src/app.rs`, `helper/tortuga-helper/src/main.rs`
- Create: `helper/scripts/moat_check.py`

**Interfaces:**
- Request `bridges.fetch { kind: "obfs4" | "webtunnel" }` → reply `bridges.lines { lines, source, country, viaTor }` or `error { code: "bridges_failed", message }`.

- [ ] **Step 1: Protocol test first**

Add the test `bridge_requests_and_answers` from the listing in Step 2 to `protocol.rs`.
Run: `cd helper && cargo test -p tortuga-helper protocol`
Expected: compile error — no variant `BridgesFetch`.

- [ ] **Step 2: Implement**

`helper/tortuga-helper/src/protocol.rs`:

```rust
//! Messages between the extension and the helper (spec: "Protocol").
//! Every message is `{ id?, type, payload? }`; replies carry the request's id.

use serde::{Deserialize, Serialize};

use crate::hops::Hop;
use crate::moat::{Fetched, LineKind};
use crate::torrents::{Progress, Source, TorrentInfo};

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
    #[serde(rename = "torrent.inspect")]
    TorrentInspect { source: SourceMsg },
    #[serde(rename = "torrent.add")]
    TorrentAdd { source: SourceMsg },
    #[serde(rename = "torrent.pause")]
    TorrentPause { id: String },
    #[serde(rename = "torrent.resume")]
    TorrentResume { id: String },
    #[serde(rename = "torrent.remove", rename_all = "camelCase")]
    TorrentRemove { id: String, delete_files: bool },
    #[serde(rename = "bridges.fetch")]
    BridgesFetch { kind: LineKind },
}

/// A torrent as the extension names it: `{ url }` (magnet or http(s) link to a
/// `.torrent`) or `{ torrentFile }` (the file, base64).
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(untagged, rename_all = "camelCase")]
pub enum SourceMsg {
    Url { url: String },
    #[serde(rename_all = "camelCase")]
    File { torrent_file: String },
}

impl SourceMsg {
    pub fn decode(&self) -> anyhow::Result<Source> {
        use base64::Engine as _;
        match self {
            SourceMsg::Url { url } if url.starts_with("magnet:") || url.starts_with("http://") || url.starts_with("https://") => {
                Ok(Source::Url(url.clone()))
            }
            SourceMsg::Url { url } => anyhow::bail!("not a magnet or http(s) link: {url}"),
            SourceMsg::File { torrent_file } => Ok(Source::File(base64::engine::general_purpose::STANDARD.decode(torrent_file)?)),
        }
    }
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
    #[serde(rename = "torrent.info")]
    TorrentInfo(TorrentInfo),
    #[serde(rename = "torrent.progress")]
    TorrentProgress { torrents: Vec<Progress> },
    #[serde(rename = "bridges.lines")]
    BridgesLines(Fetched),
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
    TorrentFailed,
    BridgesFailed,
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
    fn parses_torrent_requests() {
        assert_eq!(
            parse(json!({"id": 5, "type": "torrent.inspect", "payload": {"source": {"url": "magnet:?xt=urn:btih:abc"}}})),
            Request { id: 5, body: RequestBody::TorrentInspect { source: SourceMsg::Url { url: "magnet:?xt=urn:btih:abc".into() } } }
        );
        assert_eq!(
            parse(json!({"id": 6, "type": "torrent.add", "payload": {"source": {"torrentFile": "ZDQ6aW5mb2Vl"}}})),
            Request { id: 6, body: RequestBody::TorrentAdd { source: SourceMsg::File { torrent_file: "ZDQ6aW5mb2Vl".into() } } }
        );
        assert_eq!(
            parse(json!({"id": 7, "type": "torrent.remove", "payload": {"id": "ab", "deleteFiles": true}})),
            Request { id: 7, body: RequestBody::TorrentRemove { id: "ab".into(), delete_files: true } }
        );
    }

    #[test]
    fn decodes_sources() {
        assert_eq!(SourceMsg::Url { url: "magnet:?xt=urn:btih:abc".into() }.decode().unwrap(), Source::Url("magnet:?xt=urn:btih:abc".into()));
        assert_eq!(SourceMsg::File { torrent_file: "ZDQ6aW5mb2Vl".into() }.decode().unwrap(), Source::File(b"d4:infoee".to_vec()));
        assert!(SourceMsg::Url { url: "javascript:alert(1)".into() }.decode().is_err());
        assert!(SourceMsg::File { torrent_file: "%%%".into() }.decode().is_err());
    }

    #[test]
    fn serializes_torrent_messages() {
        let info = TorrentInfo { id: "ab".into(), name: "Sintel".into(), size: 10, files: 2, folder: "/d".into() };
        assert_eq!(
            serde_json::to_value(Message::reply(5, Outgoing::TorrentInfo(info))).unwrap(),
            json!({"id": 5, "type": "torrent.info", "payload": {"id": "ab", "name": "Sintel", "size": 10, "files": 2, "folder": "/d"}})
        );
        let row = Progress { id: "ab".into(), name: "Sintel".into(), done: 5, size: 10, down_rate: 1, up_rate: 0, state: crate::torrents::TorrentState::Downloading, error: None };
        assert_eq!(
            serde_json::to_value(Message::event(Outgoing::TorrentProgress { torrents: vec![row] })).unwrap(),
            json!({"type": "torrent.progress", "payload": {"torrents": [{"id": "ab", "name": "Sintel", "done": 5, "size": 10, "downRate": 1, "upRate": 0, "state": "downloading", "error": null}]}})
        );
    }

    #[test]
    fn bridge_requests_and_answers() {
        assert_eq!(
            parse(json!({"id": 8, "type": "bridges.fetch", "payload": {"kind": "webtunnel"}})),
            Request { id: 8, body: RequestBody::BridgesFetch { kind: LineKind::Webtunnel } }
        );
        assert!(serde_json::from_value::<Request>(json!({"id": 8, "type": "bridges.fetch", "payload": {"kind": "snowflake"}})).is_err());
        let fetched = Fetched { lines: vec!["obfs4 a".into()], source: "builtin".into(), country: Some("it".into()), via_tor: false };
        assert_eq!(
            serde_json::to_value(Message::reply(8, Outgoing::BridgesLines(fetched))).unwrap(),
            json!({"id": 8, "type": "bridges.lines", "payload": {"lines": ["obfs4 a"], "source": "builtin", "country": "it", "viaTor": false}})
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

`helper/tortuga-helper/src/app.rs`:

```rust
//! Handles requests from the extension: hello, then Tor (start, stop, new
//! circuit) and torrents. Long work runs in tasks, so a `tor.stop` can cancel
//! a start and a slow magnet lookup doesn't hold up other requests.
//!
//! The extension uses one helper process for Tor and another for torrents
//! (two native ports), so each part is opened only when first asked for.

use std::sync::Arc;
use std::time::Duration;

use tokio::net::TcpListener;
use tokio::sync::{Mutex, OnceCell};
use tokio::task::JoinHandle;

use crate::config::{Paths, default_snowflake_lines, tor_config};
use crate::moat::{self, LineKind, Route};
use crate::protocol::{BridgeChoice, ErrorCode, Message, Outgoing, PROTOCOL_VERSION, Request, RequestBody, SourceMsg};
use crate::tor::{Events, Tor};
use crate::torrents::Torrents;

/// How often the Downloads tab gets fresh numbers.
const PROGRESS_EVERY: Duration = Duration::from_secs(1);

/// A torrent request, run in its own task.
enum TorrentJob {
    Inspect(SourceMsg),
    Add(SourceMsg),
    Pause(String),
    Resume(String),
    Remove(String, bool),
}

#[derive(Default)]
struct State {
    hello: bool,
    tor: Option<Arc<Tor>>,
    /// The bootstrap in progress, if any.
    starting: Option<JoinHandle<()>>,
    /// The SOCKS listener while Tor is on, and its port.
    socks: Option<JoinHandle<()>>,
    socks_port: Option<u16>,
}

#[derive(Clone)]
pub struct App {
    state: Arc<Mutex<State>>,
    paths: Paths,
    events: Events,
    torrents: Arc<OnceCell<Arc<Torrents>>>,
}

impl App {
    pub fn new(paths: Paths, events: Events) -> Self {
        Self { state: Arc::default(), paths, events, torrents: Arc::default() }
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
            RequestBody::TorrentInspect { source } => self.torrent(req.id, TorrentJob::Inspect(source)),
            RequestBody::TorrentAdd { source } => self.torrent(req.id, TorrentJob::Add(source)),
            RequestBody::TorrentPause { id } => self.torrent(req.id, TorrentJob::Pause(id)),
            RequestBody::TorrentResume { id } => self.torrent(req.id, TorrentJob::Resume(id)),
            RequestBody::TorrentRemove { id, delete_files } => self.torrent(req.id, TorrentJob::Remove(id, delete_files)),
            RequestBody::BridgesFetch { kind } => {
                let app = self.clone();
                let socks_port = state.socks_port;
                tokio::spawn(async move {
                    let reply = match app.fetch_bridges(kind, socks_port).await {
                        Ok(fetched) => Message::reply(req.id, Outgoing::BridgesLines(fetched)),
                        Err(e) => Message::error(Some(req.id), ErrorCode::BridgesFailed, format!("{e:#}")),
                    };
                    app.send(reply);
                });
            }
        }
    }

    /// Ask Moat directly; if that fails and Tor is on, ask again through Tor.
    /// `TORTUGA_MOAT_URL` replaces the service (tests); `TORTUGA_MOAT_NO_DIRECT`
    /// skips the direct try, to exercise the way through Tor.
    async fn fetch_bridges(&self, kind: LineKind, socks_port: Option<u16>) -> anyhow::Result<moat::Fetched> {
        let base = std::env::var("TORTUGA_MOAT_URL").unwrap_or_else(|_| moat::MOAT.to_owned());
        let direct = if std::env::var_os("TORTUGA_MOAT_NO_DIRECT").is_some() {
            Err(anyhow::anyhow!("direct requests switched off"))
        } else {
            moat::fetch(kind, Route::Direct, &base).await
        };
        match (direct, socks_port) {
            (Ok(fetched), _) => Ok(fetched),
            // Moat answered: it has nothing for this network, and Tor won't change that.
            (Err(e), _) if e.downcast_ref::<moat::NoLines>().is_some() => Err(e),
            (Err(e), Some(port)) => moat::fetch(kind, Route::Tor { socks_port: port }, &base)
                .await
                .map_err(|via_tor| anyhow::anyhow!("bridges.torproject.org: {e:#}; through Tor: {via_tor:#}")),
            (Err(e), None) => Err(anyhow::anyhow!(
                "Can't reach bridges.torproject.org ({e:#}). Turn Tor on with Snowflake, then try again: the request will go through Tor."
            )),
        }
    }

    fn torrent(&self, id: u64, job: TorrentJob) {
        let app = self.clone();
        tokio::spawn(async move {
            let reply = match app.run_torrent(job).await {
                Ok(body) => Message::reply(id, body),
                Err(e) => Message::error(Some(id), ErrorCode::TorrentFailed, format!("{e:#}")),
            };
            app.send(reply);
        });
    }

    async fn run_torrent(&self, job: TorrentJob) -> anyhow::Result<Outgoing> {
        let torrents = self.open_torrents().await?;
        Ok(match job {
            TorrentJob::Inspect(source) => Outgoing::TorrentInfo(torrents.inspect(&source.decode()?).await?),
            TorrentJob::Add(source) => Outgoing::TorrentInfo(torrents.add(&source.decode()?).await?),
            TorrentJob::Pause(id) => torrents.pause(&id).await.map(|_| Outgoing::Ok)?,
            TorrentJob::Resume(id) => torrents.resume(&id).await.map(|_| Outgoing::Ok)?,
            TorrentJob::Remove(id, delete_files) => torrents.remove(&id, delete_files).await.map(|_| Outgoing::Ok)?,
        })
    }

    /// The torrent session, opened (and its saved downloads resumed) on first use.
    async fn open_torrents(&self) -> anyhow::Result<Arc<Torrents>> {
        let torrents = self
            .torrents
            .get_or_try_init(|| async {
                let t = Arc::new(Torrents::open(self.paths.downloads.clone(), self.paths.torrent_state.clone()).await?);
                tokio::spawn(report_progress(t.clone(), self.events.clone()));
                anyhow::Ok(t)
            })
            .await?;
        Ok(torrents.clone())
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
        state.socks_port = Some(port);
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
    state.socks_port = None;
    if let Some(tor) = &state.tor {
        tor.sleep();
    }
}

/// Send the torrent list every second while there is something to show, and
/// once more when it becomes empty.
async fn report_progress(torrents: Arc<Torrents>, events: Events) {
    let mut last_empty = false;
    loop {
        let list = torrents.progress();
        let empty = list.is_empty();
        if !(empty && last_empty) && events.send(Message::event(Outgoing::TorrentProgress { torrents: list })).is_err() {
            return;
        }
        last_empty = empty;
        tokio::time::sleep(PROGRESS_EVERY).await;
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

`helper/tortuga-helper/src/main.rs`:

```rust
//! tortuga-helper: the native messaging host the Tortuga extension starts.
//! stdin/stdout carry framed JSON messages; logs go to stderr only.

mod app;
mod config;
mod framing;
mod hops;
mod isolation;
mod moat;
mod protocol;
mod socks;
mod tor;
mod torrents;

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

Run: `cd helper && cargo test -p tortuga-helper && cargo build --release -p tortuga-helper 2>&1 | grep -E "^(warning|error)"`
Expected: `test result: ok. 38 passed`; the build prints nothing.

- [ ] **Step 3: End-to-end script**

`helper/scripts/moat_check.py`:

```python
#!/usr/bin/env python3
"""End-to-end check of bridges.fetch, acting as the browser.

Usage: moat_check.py HELPER_BINARY

1. obfs4 lines straight from bridges.torproject.org;
2. WebTunnel: lines, or the "none for this network" error;
3. with the direct way switched off (TORTUGA_MOAT_NO_DIRECT): an error that
   points at Snowflake, then the same request through Tor on Snowflake;
4. Tor restarted on the fetched obfs4 lines, and a page fetched through it.
Set TORTUGA_PT_DIR and a throwaway TORTUGA_DATA_DIR. Exits non-zero on failure.
"""
import json, os, queue, struct, subprocess, sys, threading, time

T0 = time.monotonic()

def log(*a):
    print(f"[{time.monotonic() - T0:6.1f}s]", *a, flush=True)

class Helper:
    def __init__(self, binary, env):
        self.p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        self.q = queue.Queue()
        self.next = 1
        self.circuits = []
        threading.Thread(target=self.read, daemon=True).start()
        self.ask("hello", {"protocol": 1}, 10)

    def read(self):
        while True:
            h = self.p.stdout.read(4)
            if len(h) < 4:
                self.q.put(None)
                return
            m = json.loads(self.p.stdout.read(struct.unpack("=I", h)[0]))
            if m.get("type") == "circuit":
                self.circuits.append(m["payload"])
            elif "id" in m:
                self.q.put(m)

    def ask(self, type, payload, timeout):
        id = self.next
        self.next += 1
        msg = {"id": id, "type": type} | ({"payload": payload} if payload is not None else {})
        b = json.dumps(msg).encode()
        self.p.stdin.write(struct.pack("=I", len(b)) + b)
        self.p.stdin.flush()
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                m = self.q.get(timeout=max(0.1, end - time.monotonic()))
            except queue.Empty:
                break
            if m is None:
                sys.exit("helper exited")
            if m.get("id") == id:
                return m
        sys.exit(f"no answer to {type}")

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=10)

def curl(port):
    out = subprocess.run(["curl", "-s", "--max-time", "60", "-x", f"socks5h://check:x@127.0.0.1:{port}",
                          "https://check.torproject.org/api/ip"], capture_output=True, text=True)
    return out.stdout.strip()

def main():
    binary = sys.argv[1]
    env = dict(os.environ)

    h = Helper(binary, env)
    r = h.ask("bridges.fetch", {"kind": "obfs4"}, 60)
    log("1. obfs4 direct:", r["type"], json.dumps(r.get("payload"))[:200])
    if r["type"] != "bridges.lines" or not r["payload"]["lines"] or r["payload"]["viaTor"]:
        sys.exit("no obfs4 lines")
    obfs4 = r["payload"]["lines"]
    r = h.ask("bridges.fetch", {"kind": "webtunnel"}, 60)
    log("2. webtunnel:", r["type"], json.dumps(r.get("payload"))[:200])
    if r["type"] == "error" and not r["payload"]["message"].startswith("bridges.torproject.org has no webtunnel bridges"):
        sys.exit("unexpected webtunnel error")
    h.close()

    h = Helper(binary, env | {"TORTUGA_MOAT_NO_DIRECT": "1"})
    r = h.ask("bridges.fetch", {"kind": "obfs4"}, 30)
    log("3a. no direct, Tor off:", r["type"], r["payload"].get("message", "")[:160])
    if r["type"] != "error" or "Snowflake" not in r["payload"]["message"]:
        sys.exit("expected the Snowflake hint")
    r = h.ask("tor.start", {"bridge": {"kind": "snowflake"}}, 300)
    if r["type"] != "tor.ready":
        sys.exit(f"Snowflake didn't start: {r}")
    log("3b. Tor on Snowflake, port", r["payload"]["socksPort"])
    r = h.ask("bridges.fetch", {"kind": "obfs4"}, 120)
    log("3c. obfs4 through Tor:", r["type"], json.dumps(r.get("payload"))[:200])
    if r["type"] != "bridges.lines" or not r["payload"]["viaTor"]:
        sys.exit("no lines through Tor")

    h.close()

    # A fresh process and data dir: on a running client a bridge change reports
    # ready before the new bridges are proven (see the spec), and some built-in
    # bridges don't answer from every network, so give Arti time to try them.
    h = Helper(binary, env | {"TORTUGA_DATA_DIR": env["TORTUGA_DATA_DIR"] + "-obfs4"})
    r = h.ask("tor.start", {"bridge": {"kind": "obfs4", "lines": [f"Bridge {l}" for l in obfs4]}}, 300)
    if r["type"] != "tor.ready":
        sys.exit(f"obfs4 didn't start: {r}")
    port = r["payload"]["socksPort"]
    answer = curl(port) or curl(port)
    log("4. Tor on the fetched obfs4 lines, port", port, "->", answer)
    time.sleep(1)
    last = h.circuits[-1] if h.circuits else None
    log("   circuit:", json.dumps(last)[:220] if last else None)
    if not last or last["bridge"] != "obfs4" or last["hops"][0]["role"] != "bridge":
        sys.exit("not through an obfs4 bridge")
    h.close()
    log("PASS")

main()
```

- [ ] **Step 4: Run it**

```bash
cd helper && rm -rf target/moat-e2e target/moat-e2e-obfs4 && TORTUGA_PT_DIR="$(pwd)/resources/pt" TORTUGA_DATA_DIR="$(pwd)/target/moat-e2e" \
perl -e 'alarm 1200; exec @ARGV' python3 -I scripts/moat_check.py target/release/tortuga-helper
```

The data dir lives under `target/`: Arti refuses state under a group- or world-writable parent, and on this machine `$TMPDIR` is `rwxrwxrwx`, so `mktemp -d` dirs fail with `problem with filesystem permissions`.
Expected (planning run, from Italy): `1. obfs4 direct: bridges.lines` with the 3 built-in lines in about a second; `2. webtunnel: error … has no webtunnel bridges for this network (it) — it says none are needed here`; `3a. no direct, Tor off: error Can't reach bridges.torproject.org (direct requests switched off). Turn Tor on with Snowflake, then try again…`; `3b` Tor on Snowflake (about 1–2 min cold); `3c. obfs4 through Tor: bridges.lines … "viaTor": true`; `4.` Tor in a fresh process on the fetched obfs4 lines → `{"IsTor":true,…}` and a circuit with `"bridge": "obfs4"` whose first hop is role `bridge`; `PASS`. Step 4 can take several minutes when some built-in bridges don't answer from the network. From a censored network step 1 gets BridgeDB lines (`"source": "bridgedb"`) and step 2 gets WebTunnel lines.

- [ ] **Step 5: Commit**

```bash
git add helper/tortuga-helper/src helper/scripts/moat_check.py
git commit -m "helper: bridges.fetch, falling back to Tor; end-to-end check"
```

---

### Task 3: Bridge lines in the extension's background

**Files:**
- Modify: `extension/src/lib/protocol.ts`, `extension/src/lib/messages.ts`, `extension/src/lib/bridges.ts`, `extension/src/background/controller.ts`, `extension/src/background/downloads.ts`
- Test: `extension/tests/controller.test.ts`, `extension/tests/downloads.test.ts`, `extension/tests/bridges.test.ts`

**Interfaces:**
- Produces: `FetchedLines { lines, source, country, viaTor }`; `ErrorCode` adds `bridges_failed`; `BridgesMessage = { type: 'FETCH_BRIDGES'; kind }`, `BridgesResult`; `linesOf(m)`; `Controller.fetchBridges(kind): Promise<FetchedLines> | null` (null while Tor is off); `Downloads.fetchBridges(kind)`; `fetchedText(kind, fetched)`.

- [ ] **Step 1: Tests first**

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

  it('asks for bridge lines only while Tor is on', async () => {
    const { c, ports } = setup();
    expect(c.fetchBridges('obfs4')).toBeNull();
    await c.turnOn('snowflake');
    await boot(ports[0]);
    const fetching = c.fetchBridges('obfs4')!;
    await flush();
    expect(ports[0].sent.at(-1)).toMatchObject({ type: 'bridges.fetch', payload: { kind: 'obfs4' } });
    ports[0].emit({ id: ports[0].idOf('bridges.fetch'), type: 'bridges.lines', payload: { lines: ['obfs4 a'], source: 'builtin', country: 'it', viaTor: false } });
    await expect(fetching).resolves.toMatchObject({ lines: ['obfs4 a'] });
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

`extension/tests/downloads.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { Downloads, type DlDeps } from '../src/background/downloads';
import { HELPER_MISSING } from '../src/background/controller';
import { HelperClient } from '../src/background/helper';
import type { DownloadsState } from '../src/lib/messages';
import type { TorrentInfo, TorrentRow } from '../src/lib/protocol';
import { FakePort, flush } from './fake-port';

const INFO: TorrentInfo = { id: '7acf', name: 'debian.iso', size: 792723456, files: 1, folder: '/Users/me/Downloads/Tortuga' };
const ROW: TorrentRow = { id: '7acf', name: 'debian.iso', done: 1, size: 792723456, downRate: 5, upRate: 0, state: 'downloading', error: null };
const MAGNET = { url: 'magnet:?xt=urn:btih:7acf' };

function setup(lastError?: string) {
  const ports: FakePort[] = [];
  const states: DownloadsState[] = [];
  const saved: boolean[] = [];
  const deps: DlDeps = {
    connect: (onEvent, onGone) => {
      const port = new FakePort();
      ports.push(port);
      return new HelperClient(port, onEvent, onGone, () => lastError);
    },
    broadcast: s => void states.push(s),
    saveActive: async a => void saved.push(a),
  };
  return { d: new Downloads(deps), ports, states, saved };
}

/** Answer the hello on the newest port. */
async function hello(ports: FakePort[]) {
  await flush();
  const port = ports.at(-1)!;
  port.emit({ id: port.idOf('hello'), type: 'hello', payload: { protocol: 1, version: '0.1.0' } });
  await flush();
  return port;
}

describe('Downloads', () => {
  it('connects on first use, says hello, then inspects', async () => {
    const { d, ports } = setup();
    const inspecting = d.inspect(MAGNET);
    const port = await hello(ports);
    expect(port.sent[1]).toMatchObject({ type: 'torrent.inspect', payload: { source: MAGNET } });
    port.emit({ id: port.idOf('torrent.inspect'), type: 'torrent.info', payload: INFO });
    await expect(inspecting).resolves.toEqual(INFO);
    expect(d.current.folder).toBe(INFO.folder);
  });

  it('uses one port for every request', async () => {
    const { d, ports } = setup();
    const first = d.inspect(MAGNET);
    const port = await hello(ports);
    port.emit({ id: port.idOf('torrent.inspect'), type: 'torrent.info', payload: INFO });
    await first;
    const pausing = d.pause('7acf');
    await flush();
    port.emit({ id: port.idOf('torrent.pause'), type: 'ok' });
    await pausing;
    expect(ports).toHaveLength(1);
  });

  it('remembers that there are downloads, and forgets when the list empties', async () => {
    const { d, ports, saved, states } = setup();
    const adding = d.add(MAGNET);
    const port = await hello(ports);
    port.emit({ id: port.idOf('torrent.add'), type: 'torrent.info', payload: INFO });
    await adding;
    port.emit({ type: 'torrent.progress', payload: { torrents: [ROW] } });
    expect(states.at(-1)?.rows).toEqual([ROW]);
    port.emit({ type: 'torrent.progress', payload: { torrents: [] } });
    await flush();
    expect(saved).toEqual([true, false]);
  });

  it('passes the helper’s error on', async () => {
    const { d, ports } = setup();
    const adding = d.add({ url: 'magnet:?xt=urn:btih:bad' });
    const port = await hello(ports);
    port.emit({ id: port.idOf('torrent.add'), type: 'error', payload: { code: 'torrent_failed', message: 'no peers' } });
    await expect(adding).rejects.toThrow('no peers');
  });

  it('gets bridge lines over the same port', async () => {
    const { d, ports } = setup();
    const fetching = d.fetchBridges('webtunnel');
    const port = await hello(ports);
    expect(port.sent[1]).toMatchObject({ type: 'bridges.fetch', payload: { kind: 'webtunnel' } });
    port.emit({ id: port.idOf('bridges.fetch'), type: 'error', payload: { code: 'bridges_failed', message: 'none are needed here' } });
    await expect(fetching).rejects.toThrow('none are needed here');
  });

  it('reports a missing helper and reconnects on the next request', async () => {
    const { d, ports, states } = setup('Specified native messaging host not found.');
    const first = d.inspect(MAGNET);
    await flush();
    ports[0].die();
    await expect(first).rejects.toThrow();
    expect(states.at(-1)).toMatchObject({ helperMissing: true, error: HELPER_MISSING, rows: [] });
    void d.inspect(MAGNET).catch(() => undefined);
    await flush();
    expect(ports).toHaveLength(2);
  });
});
```

`extension/tests/bridges.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { bridgeReady, fetchedText, linesFor, parseLines } from '../src/lib/bridges';
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

describe('fetchedText', () => {
  it('says how many lines, which kind and how they came', () => {
    expect(fetchedText('obfs4', { lines: ['a', 'b', 'c'], source: 'builtin', country: 'it', viaTor: false }))
      .toBe('Got 3 obfs4 lines from bridges.torproject.org — built-in (IT).');
    expect(fetchedText('webtunnel', { lines: ['a'], source: 'bridgedb', country: 'ru', viaTor: true }))
      .toBe('Got 1 WebTunnel line from bridges.torproject.org — handed out for your network (RU), through Tor.');
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

Run: `cd extension && npx vitest run tests/controller.test.ts tests/downloads.test.ts tests/bridges.test.ts`
Expected: 3 FAIL — `c.fetchBridges is not a function`, `d.fetchBridges is not a function`, `fetchedText is not a function` (the export is missing).

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

export type ErrorCode = 'bad_request' | 'hello_required' | 'protocol_mismatch' | 'tor_failed' | 'not_running' | 'torrent_failed' | 'bridges_failed';

/** Bridge lines from bridges.torproject.org (Moat). */
export interface FetchedLines {
  lines: string[];
  /** "bridgedb": handed out for this network; "builtin": the public defaults. */
  source: string;
  country: string | null;
  viaTor: boolean;
}

/** A torrent to fetch: a magnet or http(s) link to a `.torrent`, or the file itself (base64). */
export type TorrentSource = { url: string } | { torrentFile: string };

/** What the confirm window shows before a download starts. */
export interface TorrentInfo {
  /** The info hash: the torrent's id across restarts. */
  id: string;
  name: string;
  size: number;
  files: number;
  /** Where the files go. */
  folder: string;
}

export type TorrentState = 'starting' | 'downloading' | 'seeding' | 'paused' | 'error';

/** One row of the Downloads tab. Rates are bytes per second. */
export interface TorrentRow {
  id: string;
  name: string;
  done: number;
  size: number;
  downRate: number;
  upRate: number;
  state: TorrentState;
  error: string | null;
}

/** Anything the helper sends: a reply (with id) or an event (without). */
export type HelperMessage =
  | { id?: number; type: 'hello'; payload: { protocol: number; version: string } }
  | { id?: number; type: 'ok' }
  | { id?: number; type: 'tor.status'; payload: { phase: Stage; percent: number; blocked: string | null } }
  | { id?: number; type: 'tor.ready'; payload: { socksPort: number } }
  | { id?: number; type: 'circuit'; payload: Circuit }
  | { id?: number; type: 'torrent.info'; payload: TorrentInfo }
  | { id?: number; type: 'torrent.progress'; payload: { torrents: TorrentRow[] } }
  | { id?: number; type: 'bridges.lines'; payload: FetchedLines }
  | { id?: number; type: 'error'; payload: { code: ErrorCode; message: string } };

/** What the extension asks the helper. */
export type HelperRequest =
  | { type: 'hello'; payload: { protocol: number } }
  | { type: 'tor.start'; payload: { bridge: { kind: BridgeKind; lines?: string[] } } }
  | { type: 'tor.stop' }
  | { type: 'tor.newCircuit'; payload: { site: string } }
  | { type: 'torrent.inspect'; payload: { source: TorrentSource } }
  | { type: 'torrent.add'; payload: { source: TorrentSource } }
  | { type: 'torrent.pause'; payload: { id: string } }
  | { type: 'torrent.resume'; payload: { id: string } }
  | { type: 'torrent.remove'; payload: { id: string; deleteFiles: boolean } }
  | { type: 'bridges.fetch'; payload: { kind: 'obfs4' | 'webtunnel' } };
```

`extension/src/lib/messages.ts`:

```ts
import type { BridgeKind, FetchedLines, TorrentInfo, TorrentRow, TorrentSource } from './protocol';
import type { TorState } from './state';

/** Popup → background. Each is answered with the current TorState. */
export type BgMessage =
  | { type: 'GET_STATE' }
  | { type: 'TOR_ON'; bridge: BridgeKind }
  | { type: 'TOR_OFF' }
  | { type: 'SET_BRIDGE'; bridge: BridgeKind }
  | { type: 'NEW_CIRCUIT'; site: string };

/** Background → popup, after every change. */
export type BgBroadcast = { type: 'STATE'; state: TorState } | { type: 'DOWNLOADS'; state: DownloadsState };

/** Everything the Downloads tab shows. */
export interface DownloadsState {
  rows: TorrentRow[];
  /** Where downloads are saved, once the helper has said. */
  folder: string | null;
  error: string | null;
  helperMissing: boolean;
}

/**
 * Messages about downloads, from the popup, the confirm window and the link
 * catcher in pages. OPEN puts a torrent up for confirmation and opens the
 * confirm window; the window then INSPECTs and CONFIRMs it by its token.
 */
export type DlMessage =
  | { type: 'GET_DOWNLOADS' }
  | { type: 'TORRENT_OPEN'; source: TorrentSource }
  | { type: 'TORRENT_INSPECT'; token: string }
  | { type: 'TORRENT_CONFIRM'; token: string }
  | { type: 'TORRENT_CANCEL'; token: string }
  | { type: 'TORRENT_PAUSE'; id: string }
  | { type: 'TORRENT_RESUME'; id: string }
  | { type: 'TORRENT_REMOVE'; id: string; deleteFiles: boolean };

/** The answer to INSPECT / CONFIRM. */
export type DlResult = { ok: true; info: TorrentInfo } | { ok: false; error: string };

/** Settings page → background: get bridge lines from bridges.torproject.org. */
export type BridgesMessage = { type: 'FETCH_BRIDGES'; kind: keyof BridgeLines };
export type BridgesResult = ({ ok: true } & FetchedLines) | { ok: false; error: string };

/** Set while there are downloads, so a restarted browser resumes them. */
export const DOWNLOADS_KEY = 'tortugaDownloads';

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

`extension/src/lib/bridges.ts`:

```ts
import type { BridgeLines } from './messages';
import type { BridgeKind, FetchedLines } from './protocol';

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

/** What the settings page says after getting lines from bridges.torproject.org. */
export function fetchedText(kind: LineKind, f: FetchedLines): string {
  const name = kind === 'obfs4' ? 'obfs4' : 'WebTunnel';
  const what = f.source === 'builtin' ? 'built-in' : 'handed out for your network';
  const where = f.country ? ` (${f.country.toUpperCase()})` : '';
  const via = f.viaTor ? ', through Tor' : '';
  return `Got ${f.lines.length} ${name} ${f.lines.length === 1 ? 'line' : 'lines'} from bridges.torproject.org — ${what}${where}${via}.`;
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

`extension/src/background/controller.ts`:

```ts
import type { BridgeKind, FetchedLines, HelperMessage } from '../lib/protocol';
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

/** The lines in a `bridges.lines` reply. */
export function linesOf(m: HelperMessage): FetchedLines {
  if (m.type !== 'bridges.lines') throw new Error(`unexpected reply ${m.type}`);
  return m.payload;
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

  /**
   * Bridge lines from Moat through the Tor helper, which can retry through Tor
   * when the direct way is blocked. Null when Tor is off (no helper to ask).
   */
  fetchBridges(kind: 'obfs4' | 'webtunnel'): Promise<FetchedLines> | null {
    if (this.state.phase !== 'on' || !this.helper) return null;
    return this.helper.request({ type: 'bridges.fetch', payload: { kind } }).then(linesOf);
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

`extension/src/background/downloads.ts`:

```ts
import type { DownloadsState } from '../lib/messages';
import { PROTOCOL_VERSION, type FetchedLines, type HelperMessage, type TorrentInfo, type TorrentSource } from '../lib/protocol';
import { HELPER_MISSING, linesOf } from './controller';
import { isMissingHost, type HelperClient } from './helper';

/** Everything the downloads controller does to the outside world (fakes in tests). */
export interface DlDeps {
  connect(onEvent: (m: HelperMessage) => void, onGone: (reason: string) => void): HelperClient;
  broadcast(state: DownloadsState): void;
  /** Remember whether there are downloads, so a restarted browser resumes them. */
  saveActive(active: boolean): Promise<void>;
}

export const NO_DOWNLOADS: DownloadsState = { rows: [], folder: null, error: null, helperMissing: false };

/**
 * Torrents run in their own helper process, on a native port of their own:
 * Tor can be on or off without touching downloads. The port is opened on the
 * first request and kept while the browser runs.
 */
export class Downloads {
  private state: DownloadsState = NO_DOWNLOADS;
  private ready: Promise<HelperClient> | null = null;
  private active = false;

  constructor(private readonly deps: DlDeps) {}

  get current(): DownloadsState {
    return this.state;
  }

  /** Connect now (on startup, when there were downloads to resume). */
  async resume(): Promise<void> {
    await this.client().catch(() => undefined);
  }

  async inspect(source: TorrentSource): Promise<TorrentInfo> {
    return this.info(await this.request({ type: 'torrent.inspect', payload: { source } }));
  }

  async add(source: TorrentSource): Promise<TorrentInfo> {
    const info = this.info(await this.request({ type: 'torrent.add', payload: { source } }));
    await this.setActive(true);
    return info;
  }

  async pause(id: string): Promise<void> {
    await this.request({ type: 'torrent.pause', payload: { id } });
  }

  async resumeOne(id: string): Promise<void> {
    await this.request({ type: 'torrent.resume', payload: { id } });
  }

  async remove(id: string, deleteFiles: boolean): Promise<void> {
    await this.request({ type: 'torrent.remove', payload: { id, deleteFiles } });
  }

  /** Bridge lines from Moat, directly (this helper never runs Tor). */
  async fetchBridges(kind: 'obfs4' | 'webtunnel'): Promise<FetchedLines> {
    return linesOf(await this.request({ type: 'bridges.fetch', payload: { kind } }));
  }

  private info(m: HelperMessage): TorrentInfo {
    if (m.type !== 'torrent.info') throw new Error(`unexpected reply ${m.type}`);
    this.update({ folder: m.payload.folder });
    return m.payload;
  }

  private async request(req: Parameters<HelperClient['request']>[0]): Promise<HelperMessage> {
    const helper = await this.client();
    return helper.request(req);
  }

  private client(): Promise<HelperClient> {
    if (!this.ready) {
      const ready = (async () => {
        const helper = this.deps.connect(m => this.onEvent(m), reason => this.onGone(reason));
        await helper.request({ type: 'hello', payload: { protocol: PROTOCOL_VERSION } });
        this.update({ error: null, helperMissing: false });
        return helper;
      })();
      this.ready = ready;
      ready.catch(() => {
        if (this.ready === ready) this.ready = null;
      });
    }
    return this.ready;
  }

  private onEvent(m: HelperMessage): void {
    if (m.type !== 'torrent.progress') return;
    this.update({ rows: m.payload.torrents });
    void this.setActive(m.payload.torrents.length > 0);
  }

  private onGone(reason: string): void {
    this.ready = null;
    const missing = isMissingHost(reason);
    // The rows are stale once the helper is gone; they come back when it does.
    this.update({ rows: [], error: missing ? HELPER_MISSING : reason, helperMissing: missing });
  }

  private async setActive(active: boolean): Promise<void> {
    if (active === this.active) return;
    this.active = active;
    await this.deps.saveActive(active);
  }

  private update(change: Partial<DownloadsState>): void {
    this.state = { ...this.state, ...change };
    this.deps.broadcast(this.state);
  }
}
```

Run: `cd extension && npm test`
Expected: `Tests  70 passed (70)`

- [ ] **Step 3: Commit**

```bash
git add extension/src extension/tests
git commit -m "extension: fetch bridge lines through either helper"
```

---

### Task 4: Get … lines on the settings page

**Files:**
- Modify: `extension/src/background/index.ts`, `extension/src/options/index.html`, `extension/src/options/index.ts`, `extension/src/options/style.css`, `extension/src/popup/index.ts`

- [ ] **Step 1: Background**

`extension/src/background/index.ts`:

```ts
import { linesFor } from '../lib/bridges';
import { isTorrentLink } from '../lib/downloads';
import {
  DOWNLOADS_KEY, LINES_KEY, NO_LINES, STORAGE_KEY,
  type BgBroadcast, type BgMessage, type BridgeLines, type BridgesMessage, type BridgesResult, type DlMessage, type DlResult, type Stored,
} from '../lib/messages';
import type { BridgeKind, TorrentInfo, TorrentSource } from '../lib/protocol';
import type { TorState } from '../lib/state';
import { Controller } from './controller';
import { Downloads } from './downloads';
import { connectHelper } from './helper';
import { applyPrivacy } from './privacy';
import { applyChromeRoute, firefoxAnswer } from './routing';

const controller = new Controller({
  connect: connectHelper,
  // Firefox asks proxy.onRequest about each request (below); Chrome has one setting.
  applyRoute: port => (__TARGET__ === 'firefox' ? Promise.resolve() : applyChromeRoute(port)),
  applyPrivacy,
  save: stored => chrome.storage.local.set({ [STORAGE_KEY]: stored }),
  broadcast: (state: TorState) => broadcast({ type: 'STATE', state }),
  incognitoAllowed: () => (__TARGET__ === 'firefox' ? Promise.resolve(true) : chrome.extension.isAllowedIncognitoAccess()),
});

function broadcast(msg: BgBroadcast): void {
  chrome.runtime.sendMessage(msg).catch(() => { /* no popup open */ });
}

const downloads = new Downloads({
  connect: connectHelper,
  broadcast: state => broadcast({ type: 'DOWNLOADS', state }),
  saveActive: active => chrome.storage.local.set({ [DOWNLOADS_KEY]: active }),
});

// Downloads stop with the browser; if there were some, pick them up again.
void chrome.storage.local.get(DOWNLOADS_KEY).then(r => {
  if (r[DOWNLOADS_KEY]) void downloads.resume();
});

/** Torrents waiting in a confirm window, by the window's token. */
const pending = new Map<string, TorrentSource>();

/** Put a torrent up for confirmation in a small window of its own. */
async function openConfirm(source: TorrentSource): Promise<void> {
  const token = crypto.randomUUID();
  pending.set(token, source);
  await chrome.windows.create({ url: chrome.runtime.getURL(`confirm.html?t=${token}`), type: 'popup', width: 440, height: 420 });
}

async function result(run: () => Promise<TorrentInfo>): Promise<DlResult> {
  try {
    return { ok: true, info: await run() };
  } catch (e) {
    return { ok: false, error: (e as Error).message };
  }
}

function sourceOf(token: string): TorrentSource {
  const source = pending.get(token);
  if (!source) throw new Error('This link has expired. Click it again.');
  return source;
}

const MENU_ID = 'tortuga-download';
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: MENU_ID, title: 'Download with Tortuga', contexts: ['link'] });
});
chrome.contextMenus.onClicked.addListener(info => {
  if (info.menuItemId === MENU_ID && info.linkUrl) void openConfirm({ url: info.linkUrl });
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

/** Bridge lines from Moat: through the Tor helper while Tor is on (it can retry through Tor), else directly. */
async function fetchBridges(kind: 'obfs4' | 'webtunnel'): Promise<BridgesResult> {
  try {
    const fetched = await (controller.fetchBridges(kind) ?? downloads.fetchBridges(kind));
    return { ok: true, ...fetched };
  } catch (e) {
    return { ok: false, error: (e as Error).message };
  }
}

chrome.runtime.onMessage.addListener((msg: BgMessage | DlMessage | BridgesMessage, _sender, sendResponse) => {
  const reply = (p: Promise<TorState>) => {
    p.then(sendResponse, () => sendResponse(controller.current));
    return true;
  };
  const answer = (p: Promise<unknown>) => {
    p.then(sendResponse, e => sendResponse({ ok: false, error: (e as Error).message }));
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
    case 'GET_DOWNLOADS':
      return answer(Promise.resolve(downloads.current));
    case 'TORRENT_OPEN':
      // Pages only ever ask for links that look like torrents; refuse anything else.
      if ('url' in msg.source && !isTorrentLink(msg.source.url)) return answer(Promise.resolve({ ok: false, error: 'Not a magnet or .torrent link' }));
      return answer(openConfirm(msg.source).then(() => ({ ok: true })));
    case 'TORRENT_INSPECT':
      return answer(result(() => downloads.inspect(sourceOf(msg.token))));
    case 'TORRENT_CONFIRM':
      return answer(result(async () => {
        const info = await downloads.add(sourceOf(msg.token));
        pending.delete(msg.token);
        return info;
      }));
    case 'TORRENT_CANCEL':
      pending.delete(msg.token);
      return answer(Promise.resolve({ ok: true }));
    case 'TORRENT_PAUSE':
      return answer(downloads.pause(msg.id).then(() => downloads.current));
    case 'TORRENT_RESUME':
      return answer(downloads.resumeOne(msg.id).then(() => downloads.current));
    case 'TORRENT_REMOVE':
      return answer(downloads.remove(msg.id, msg.deleteFiles).then(() => downloads.current));
    case 'FETCH_BRIDGES':
      return answer(fetchBridges(msg.kind));
  }
  return false;
});
```

- [ ] **Step 2: Settings page**

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
      <h2>Downloads</h2>
      <p id="downloads" class="muted">Torrents are saved in your Downloads folder, under Tortuga.</p>
      <p class="muted">They download from your own IP, not through Tor.</p>
    </section>

    <section class="card">
      <h2>Bridge lines</h2>
      <p class="muted">obfs4 and WebTunnel need bridge addresses. <b>Get … lines</b> asks bridges.torproject.org: for a network where Tor is blocked it hands out bridges, elsewhere the public built-in ones. If the site itself is blocked, turn Tor on with Snowflake first — the request then goes through Tor. You can also paste lines from bridges.torproject.org or the Tor Project’s Telegram bot, one per line. Snowflake needs none.</p>
      <div class="field-row"><label class="field" for="obfs4">obfs4</label><button class="btn btn-small" id="getObfs4" type="button" data-kind="obfs4">Get obfs4 lines</button></div>
      <textarea id="obfs4" rows="4" spellcheck="false" placeholder="obfs4 192.0.2.1:443 0123…ABCD cert=… iat-mode=0"></textarea>
      <ul class="errors" id="obfs4Errors" hidden></ul>
      <div class="field-row"><label class="field" for="webtunnel">WebTunnel</label><button class="btn btn-small" id="getWebtunnel" type="button" data-kind="webtunnel">Get WebTunnel lines</button></div>
      <textarea id="webtunnel" rows="4" spellcheck="false" placeholder="webtunnel [2001:db8::1]:443 0123…ABCD url=https://… ver=0.0.1"></textarea>
      <ul class="errors" id="webtunnelErrors" hidden></ul>
      <p class="muted" id="fetched" role="status" hidden></p>
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
import { fetchedText, parseLines, type LineKind } from '../lib/bridges';
import {
  LINES_KEY, NO_LINES,
  type BgMessage, type BridgeLines, type BridgesMessage, type BridgesResult, type DlMessage, type DownloadsState,
} from '../lib/messages';
import type { TorState } from '../lib/state';
import { chooseTheme, chosenTheme, clearTheme } from '../lib/theme';
import { helperText } from './helper-text';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const KINDS: LineKind[] = ['obfs4', 'webtunnel'];

async function showHelper(): Promise<void> {
  const s: TorState = await chrome.runtime.sendMessage({ type: 'GET_STATE' } satisfies BgMessage);
  $('helper').textContent = helperText(s);
}

async function showDownloads(): Promise<void> {
  const d: DownloadsState = await chrome.runtime.sendMessage({ type: 'GET_DOWNLOADS' } satisfies DlMessage);
  if (d.folder) $('downloads').textContent = `Torrents are saved in ${d.folder}.`;
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
      await saveLines();
      fetched.textContent = fetchedText(kind, r);
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

.field-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-top: 4px; }
.field-row .field { margin-top: 0; }
.btn-small { padding: 4px 10px; font-size: 12px; }
.btn:disabled { opacity: 0.6; cursor: progress; }
#fetched.bad { color: var(--warn); }
```

- [ ] **Step 3: Popup wording**

`extension/src/popup/index.ts`:

```ts
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
```

- [ ] **Step 4: Everything**

Run: `cd extension && npx tsc --noEmit && npm test && npm run build && npm run build:firefox && npm run lint:firefox`
Expected: no `tsc` output; `70 passed`; both builds; lint `errors 0, notices 0, warnings 0`.

- [ ] **Step 5: Commit**

```bash
git add extension/src
git commit -m "extension: Get obfs4 / WebTunnel lines on the settings page"
```

---

### Task 5: Live check and spec

**Files:**
- Modify: `extension/scripts/live-check/run.sh`
- Create: `extension/scripts/live-check/bridges.mjs`
- Modify: `docs/superpowers/specs/2026-11-05-tortuga-design.md`

- [ ] **Step 1: Scripts**

`extension/scripts/live-check/run.sh`:

```bash
#!/usr/bin/env bash
# Live checks in headless Firefox with the extension and the dev helper.
#   extension/scripts/live-check/run.sh            Tor mode (check.mjs)
#   extension/scripts/live-check/run.sh downloads  torrents (downloads.mjs)
#   extension/scripts/live-check/run.sh bridges    Get … lines on the settings page (bridges.mjs)
# Both need network access; the Tor check needs Tor to be reachable.
set -euo pipefail
WHAT="${1:-tor}"
HERE="$(cd "$(dirname "$0")" && pwd)"
EXT="$(cd "$HERE/../.." && pwd)"
"$EXT/scripts/register-dev-host.sh" >/dev/null
(cd "$EXT" && npm run build:firefox --silent >/dev/null)
TMP="$(mktemp -d)"
case "$(uname -s)" in
  Darwin) MANIFEST="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts/org.tortuga.helper.json"
          HELPER="$HOME/Library/Application Support/Tortuga/dev/tortuga-helper" ;;
  *)      MANIFEST="$HOME/.mozilla/native-messaging-hosts/org.tortuga.helper.json"
          HELPER="$HOME/.local/share/tortuga/dev/tortuga-helper" ;;
esac
SERVER=""
if [ "$WHAT" = downloads ] || [ "$WHAT" = bridges ]; then
  # Keep test downloads and helper data out of ~/Downloads and the real data
  # dir: point the host at a wrapper that sets them, and put it back on exit.
  mkdir -p "$TMP/downloads" "$TMP/data"
  cp "$MANIFEST" "$TMP/manifest.json"
  cat > "$TMP/host.sh" <<SH
#!/bin/sh
export TORTUGA_DOWNLOADS="$TMP/downloads"
export TORTUGA_DATA_DIR="$TMP/data"
exec "$HELPER" "\$@"
SH
  chmod +x "$TMP/host.sh"
  python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); m["path"]=sys.argv[2]; open(sys.argv[1],"w").write(json.dumps(m, indent=2))' "$MANIFEST" "$TMP/host.sh"
fi
if [ "$WHAT" = downloads ]; then
  (cd "$HERE/site" && exec python3 -I -m http.server 8765 --bind 127.0.0.1) >/dev/null 2>&1 &
  SERVER=$!
fi
(cd "$EXT" && MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1 npx --yes web-ext@10.8.0 run --source-dir dist-firefox \
  --no-input --no-reload --arg=--headless --arg=--remote-debugging-port=9222 --arg=--remote-allow-system-access) >"$TMP/web-ext.log" 2>&1 &
WEBEXT=$!
cleanup() {
  kill "$WEBEXT" 2>/dev/null || true
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || true
  pkill -f 'Firefox.app/Contents/MacOS/firefox.*headless|firefox.*--headless' 2>/dev/null || true
  pkill -f 'Tortuga/dev/tortuga-helper|tortuga/dev/tortuga-helper' 2>/dev/null || true
  [ -f "$TMP/manifest.json" ] && cp "$TMP/manifest.json" "$MANIFEST"
  rm -rf "$TMP"
}
trap cleanup EXIT
for _ in $(seq 1 60); do nc -z 127.0.0.1 9222 2>/dev/null && break; sleep 0.5; done
sleep 2
if [ "$WHAT" = downloads ]; then
  mkdir -p "$TMP/shots"
  node "$HERE/downloads.mjs" "$TMP/shots" "$TMP/downloads"
elif [ "$WHAT" = bridges ]; then
  node "$HERE/bridges.mjs" "${SHOTS:-}"
else
  node "$HERE/check.mjs"
fi
```

`extension/scripts/live-check/bridges.mjs`:

```js
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
```

- [ ] **Step 2: Run all three live checks**

Run: `(cd helper && cargo build --release -p tortuga-helper) && extension/scripts/live-check/run.sh bridges`
Expected: `ALL PASSED` — `Got 3 obfs4 lines from bridges.torproject.org — built-in (IT).` (or BridgeDB lines elsewhere), lines saved and passing the line check, WebTunnel lines or Moat's "none are needed here", the popup's obfs4 card enabled with "3 saved". `SHOTS=<dir>` before the command also saves screenshots.

Run: `extension/scripts/live-check/run.sh downloads` and `extension/scripts/live-check/run.sh`
Expected: `ALL PASSED` for both (nothing they cover changed).

- [ ] **Step 3: Spec**

In `docs/superpowers/specs/2026-11-05-tortuga-design.md`:
1. *Helper → Tor*: replace "fetched with **Get a bridge**: the helper asks the Tor Project's Moat service over the meek transport, as Tor Browser's Connection Assist does" with: "fetched with **Get … lines** on the settings page: the helper asks Moat (`circumvention/settings`, then `circumvention/builtin`) directly, or through Tor's own SOCKS port when that fails and Tor already runs — Snowflake needs no lines, so it is the way in where bridges.torproject.org is blocked. No domain fronting."
2. *Protocol*: add `bridges.fetch { kind: 'obfs4' | 'webtunnel' }` → `bridges.lines { lines, source: 'bridgedb' | 'builtin', country, viaTor }`; error code `bridges_failed`.
3. *Errors → known limitations*: "Changing bridges on a running client reports ready at once (the directory is cached) before the new bridges are proven; traffic still can't leak, but the popup can say *on* while circuits fail. Fix: probe a circuit after a bridge change." and "Built-in obfs4 bridges don't all answer from every network (1 of 3 here); Arti tries them in turn, so a first start on them can take minutes."

- [ ] **Step 4: Commit**

```bash
git add extension/scripts/live-check docs/superpowers/specs/2026-11-05-tortuga-design.md
git commit -m "dev: bridges live check; spec follows Moat"
```

---

## Next plans

Installers and release. Follow-up found here: prove new bridges with a circuit after a bridge change before reporting ready.
