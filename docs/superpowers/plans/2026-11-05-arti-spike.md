# Arti Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that embedded Arti gives Tortuga what the spec needs — per-site isolated circuits, each stream's hop list, relay countries, and bootstrap through a Snowflake bridge — before anything else is built.

**Architecture:** A throwaway Rust binary `arti-probe` in `helper/spike/`. It bootstraps `arti-client`, opens streams with separate `IsolationToken`s, reads each stream's tunnel path through `ClientStreamCtrl`, and prints hop roles, countries and relay ids. Two small pure modules (`hops.rs`, `config.rs`) are unit-tested and will be reused by the real helper. The result is a findings document that decides go / no-go for Rust + Arti.

**Tech Stack:** Rust (edition 2024, rustc 1.99), `arti-client` 0.48.0, `tor-proto` 0.48.0 (`stream-ctrl`), `tor-linkspec`, `tor-geoip`, `tokio`, `anyhow`. Snowflake via the Tor Expert Bundle's pluggable transports.

Spec: `docs/superpowers/specs/2026-11-05-tortuga-design.md` (section *Testing → First implementation step — spike*).

## Global Constraints

- All `arti-client` / `tor-*` crates pinned with `=0.48.0` — the circuit-path API is experimental.
- Spike code lives only in `helper/spike/`; it is not the helper and ships nowhere.
- No local DNS: every connection goes through `TorClient::connect_with_prefs` with a host name.
- If Arti cannot give per-stream paths, stop after Task 4 and revisit the helper choice (spec: "stop and revisit the helper choice before building anything else").

## File Structure

| File | Responsibility |
|---|---|
| `helper/spike/Cargo.toml` | Crate with pinned Arti dependencies |
| `helper/spike/src/hops.rs` | `Role` and `roles_for()` — which hop is bridge / guard / middle / exit |
| `helper/spike/src/config.rs` | `BridgeSetup` and `tor_config()` — default or bridges-only `TorClientConfig` |
| `helper/spike/src/main.rs` | CLI: bootstrap, isolated streams, print paths |
| `helper/spike/bridges/.gitignore` | Keeps downloaded bridge lines and binaries out of git |
| `docs/spike-findings.md` | Observed results and the go / no-go decision |

---

### Task 1: Crate and hop roles

**Files:**
- Create: `helper/spike/Cargo.toml`
- Create: `helper/spike/src/hops.rs`
- Create: `helper/spike/src/main.rs` (temporary stub)

**Interfaces:**
- Produces: `pub enum Role { Guard, Bridge, Middle, Exit }` (`Debug, Clone, Copy, PartialEq, Eq`) and `pub fn roles_for(n_hops: usize, via_bridge: bool) -> Vec<Role>`.

- [ ] **Step 1: Create the crate manifest**

`helper/spike/Cargo.toml`:

```toml
[package]
name = "arti-probe"
version = "0.1.0"
edition = "2024"
publish = false

[dependencies]
arti-client = { version = "=0.48.0", features = ["full", "experimental-api", "geoip"] }
tor-proto = { version = "=0.48.0", features = ["stream-ctrl"] }
tor-linkspec = "=0.48.0"
tor-geoip = "=0.48.0"
tokio = { version = "1", features = ["full"] }
anyhow = "1"
```

- [ ] **Step 2: Write the failing tests**

`helper/spike/src/hops.rs`:

```rust
/// What a hop does in a circuit, as the popup's metro diagram names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Guard,
    Bridge,
    Middle,
    Exit,
}

/// Roles of a circuit's hops in order. The first hop is the bridge when
/// bridges are in use, the guard otherwise; the last is the exit.
pub fn roles_for(_n_hops: usize, _via_bridge: bool) -> Vec<Role> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
```

`helper/spike/src/main.rs` (stub until Task 3):

```rust
mod hops;

fn main() {}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd helper/spike && cargo test hops`
Expected: 3 tests FAIL (`left: []`). The first build downloads and compiles Arti — several minutes.

- [ ] **Step 4: Implement `roles_for`**

Replace the body in `helper/spike/src/hops.rs`:

```rust
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
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd helper/spike && cargo test hops`
Expected: `test result: ok. 3 passed`

- [ ] **Step 6: Commit**

```bash
git add helper/spike/Cargo.toml helper/spike/Cargo.lock helper/spike/src
git commit -m "spike: arti-probe crate with hop roles"
```

---

### Task 2: Tor config with optional bridges

**Files:**
- Create: `helper/spike/src/config.rs`
- Modify: `helper/spike/src/main.rs` (add `mod config;`)

**Interfaces:**
- Produces: `pub struct BridgeSetup { pub lines: Vec<String>, pub pt_binary: String, pub protocols: Vec<String> }` and `pub fn tor_config(bridges: Option<&BridgeSetup>) -> anyhow::Result<arti_client::TorClientConfig>`.

- [ ] **Step 1: Write the failing tests with a stub**

`helper/spike/src/config.rs`:

```rust
use arti_client::config::pt::TransportConfigBuilder;
use arti_client::config::{BridgeConfigBuilder, CfgPath, TorClientConfig};

/// Bridges for the spike: bridge lines, plus the transport binary and the
/// protocols it serves (e.g. `["snowflake"]`).
pub struct BridgeSetup {
    pub lines: Vec<String>,
    pub pt_binary: String,
    pub protocols: Vec<String>,
}

/// Default config, or one that bootstraps only through the given bridges.
pub fn tor_config(_bridges: Option<&BridgeSetup>) -> anyhow::Result<TorClientConfig> {
    anyhow::bail!("not implemented")
}

#[cfg(test)]
mod tests {
    use super::*;

    // Made-up obfs4 line from arti-client's own documentation.
    const FAKE_OBFS4: &str = "Bridge obfs4 192.0.2.55:38114 316E643333645F6D79216558614D3931657A5F5F cert=YXJlIGZyZXF1ZW50bHkgZnVsbCBvZiBsaXR0bGUgbWVzc2FnZXMgeW91IGNhbiBmaW5kLg iat-mode=0";

    #[test]
    fn default_config_builds() {
        assert!(tor_config(None).is_ok());
    }

    #[test]
    fn bridge_config_builds() {
        let setup = BridgeSetup {
            lines: vec![FAKE_OBFS4.into()],
            pt_binary: "/usr/local/bin/lyrebird".into(),
            protocols: vec!["obfs4".into()],
        };
        assert!(tor_config(Some(&setup)).is_ok());
    }

    #[test]
    fn bad_bridge_line_is_an_error() {
        let setup = BridgeSetup {
            lines: vec!["Bridge not-a-bridge".into()],
            pt_binary: "/usr/local/bin/lyrebird".into(),
            protocols: vec!["obfs4".into()],
        };
        assert!(tor_config(Some(&setup)).is_err());
    }
}
```

In `helper/spike/src/main.rs` add `mod config;` above `mod hops;`.

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd helper/spike && cargo test config`
Expected: `default_config_builds` and `bridge_config_builds` FAIL; `bad_bridge_line_is_an_error` passes.

- [ ] **Step 3: Implement `tor_config`**

Replace the stub in `helper/spike/src/config.rs`:

```rust
pub fn tor_config(bridges: Option<&BridgeSetup>) -> anyhow::Result<TorClientConfig> {
    let mut builder = TorClientConfig::builder();
    if let Some(b) = bridges {
        for line in &b.lines {
            let bridge: BridgeConfigBuilder = line.parse()?;
            builder.bridges().bridges().push(bridge);
        }
        let mut transport = TransportConfigBuilder::default();
        let protocols = b.protocols.iter().map(|p| p.parse()).collect::<Result<Vec<_>, _>>()?;
        transport.protocols(protocols).path(CfgPath::new(b.pt_binary.clone())).run_on_startup(true);
        builder.bridges().transports().push(transport);
    }
    Ok(builder.build()?)
}
```

- [ ] **Step 4: Run all tests**

Run: `cd helper/spike && cargo test`
Expected: `test result: ok. 6 passed`

- [ ] **Step 5: Commit**

```bash
git add helper/spike/src
git commit -m "spike: Tor config with optional bridges"
```

---

### Task 3: Probe — isolated streams and their paths

**Files:**
- Modify: `helper/spike/src/main.rs` (replace the stub)

**Interfaces:**
- Consumes: `roles_for` (Task 1), `BridgeSetup`, `tor_config` (Task 2).
- Produces: the `arti-probe` binary. Usage: `arti-probe` (direct) or `arti-probe BRIDGE_LINES_FILE PT_BINARY PROTOCOL`.

- [ ] **Step 1: Write the probe**

`helper/spike/src/main.rs`:

```rust
mod config;
mod hops;

use arti_client::{IsolationToken, StreamPrefs, TorClient};
use tor_geoip::GeoipDb;
use tor_linkspec::{HasAddrs, HasRelayIds};
use tor_proto::client::stream::ClientStreamCtrl;

use config::{BridgeSetup, tor_config};
use hops::roles_for;

/// Usage: arti-probe [BRIDGE_LINES_FILE PT_BINARY PROTOCOL]
fn bridge_setup_from_args() -> anyhow::Result<Option<BridgeSetup>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [] => Ok(None),
        [file, pt, protocol] => {
            let lines = std::fs::read_to_string(file)?
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty() && !l.starts_with('#'))
                .map(String::from)
                .collect();
            Ok(Some(BridgeSetup { lines, pt_binary: pt.clone(), protocols: vec![protocol.clone()] }))
        }
        _ => anyhow::bail!("usage: arti-probe [BRIDGE_LINES_FILE PT_BINARY PROTOCOL]"),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let bridges = bridge_setup_from_args()?;
    let via_bridge = bridges.is_some();
    let started = std::time::Instant::now();
    let tor = TorClient::create_bootstrapped(tor_config(bridges.as_ref())?).await?;
    println!("bootstrapped in {:.1?}", started.elapsed());
    let geoip = GeoipDb::new_embedded();

    // Two sites with their own tokens, then the first site again with its token:
    // expect two different tunnels, and the third equal to the first.
    let token_a = IsolationToken::new();
    let token_b = IsolationToken::new();
    for (site, token) in [("example.com", token_a), ("example.org", token_b), ("example.com", token_a)] {
        let mut prefs = StreamPrefs::new();
        prefs.set_isolation(token);
        let stream = tor.connect_with_prefs((site, 80), &prefs).await?;
        let ctrl = stream.client_stream_ctrl().ok_or_else(|| anyhow::anyhow!("not a client stream"))?;
        let tunnel = ctrl.tunnel().ok_or_else(|| anyhow::anyhow!("tunnel already closed"))?;
        println!("{site} via tunnel {}", tunnel.unique_id());
        for path in tunnel.all_paths() {
            let roles = roles_for(path.n_hops(), via_bridge);
            for (hop, role) in path.iter().zip(roles) {
                let Some(target) = hop.as_chan_target() else {
                    println!("  {role:?}: virtual hop");
                    continue;
                };
                let addr = target.addrs().next();
                let country = addr
                    .and_then(|a| geoip.lookup_country_code(a.ip()))
                    .map(|c| c.get().to_string())
                    .unwrap_or_else(|| "??".into());
                let id = target.ed_identity().map(|e| e.to_string()).unwrap_or_default();
                println!("  {role:?}: {country} {addr:?} {id}");
            }
        }
    }
    Ok(())
}
```

- [ ] **Step 2: Build**

Run: `cd helper/spike && cargo build && cargo test`
Expected: builds; `6 passed`. (Unused-code warnings are fine.)

- [ ] **Step 3: Run directly against the Tor network**

Run: `cd helper/spike && timeout 180 cargo run --release`
Expected, if Tor is reachable from this network (ids, countries and timings will differ):

```
bootstrapped in 12.3s
example.com via tunnel Circ 4.1
  Guard: DE Some(…:443) …
  Middle: FR Some(…) …
  Exit: NL Some(…) …
example.org via tunnel Circ 5.1
  …
example.com via tunnel Circ 4.1
  …
```

Check: (a) each tunnel prints three hops with a country; (b) the two `example.com` lines show the same tunnel id; (c) `example.org` shows a different one. Save the full output to `helper/spike/bridges/direct.log` (git-ignored, Task 4) for the findings.
If bootstrap does not finish within 180 s (Tor blocked on this network), note it and go on to Task 4 — that is what Snowflake is for.

- [ ] **Step 4: Commit**

```bash
git add helper/spike/src/main.rs
git commit -m "spike: print isolated stream paths with countries"
```

---

### Task 4: Bootstrap through Snowflake

**Files:**
- Create: `helper/spike/bridges/.gitignore`
- Local only (ignored): `helper/spike/bridges/snowflake.txt`, the Tor Expert Bundle

- [ ] **Step 1: Ignore downloaded material**

`helper/spike/bridges/.gitignore`:

```
*
!.gitignore
```

- [ ] **Step 2: Get the pluggable transport binary**

Download the Tor Expert Bundle for macOS (aarch64) from https://www.torproject.org/download/tor/ into `helper/spike/bridges/` and unpack it there. Then:

Run: `ls helper/spike/bridges/tor/pluggable_transports/ && cat helper/spike/bridges/tor/pluggable_transports/pt_config.json`
Expected: a `lyrebird` binary (and any others listed), plus `pt_config.json` whose `pluggableTransports` entry for `snowflake` names the binary that serves it. Use that binary path as `PT_BINARY` below. On macOS, if the binary is quarantined: `xattr -d com.apple.quarantine <binary>`.

- [ ] **Step 3: Get Snowflake bridge lines**

From the same `pt_config.json`, copy every string in `bridges.snowflake` into `helper/spike/bridges/snowflake.txt`, one per line, each prefixed with `Bridge `, the form arti-client's own documentation parses.

Run: `wc -l helper/spike/bridges/snowflake.txt`
Expected: 2 or more lines, each starting `Bridge snowflake 192.0.2.`.

- [ ] **Step 4: Run through Snowflake**

Run: `cd helper/spike && timeout 300 cargo run --release -- bridges/snowflake.txt "$(pwd)/bridges/tor/pluggable_transports/lyrebird" snowflake`
(Replace the binary path if `pt_config.json` named a different one.)
Expected: `bootstrapped in …`, then the same three blocks as Task 3, with the first hop printed as `Bridge:`. Save the output to `helper/spike/bridges/snowflake.log`.

- [ ] **Step 5: Commit**

```bash
git add helper/spike/bridges/.gitignore
git commit -m "spike: keep downloaded bridges and transports out of git"
```

---

### Task 5: Findings and decision

**Files:**
- Create: `docs/spike-findings.md`

- [ ] **Step 1: Write the findings from the logs**

`docs/spike-findings.md`, filled with what Tasks 3–4 actually printed:

```markdown
# Arti spike findings

Date: <run date>
Arti: arti-client 0.48.0

| Question | Result |
|---|---|
| Direct bootstrap works, time | <yes/no, seconds> |
| Snowflake bootstrap works, time | <yes/no, seconds> |
| Each stream exposes its tunnel path (`ClientStreamCtrl::tunnel`) | <yes/no> |
| Hops have addresses and a GeoIP country | <yes/no, any "??"> |
| Same IsolationToken → same tunnel | <yes/no> |
| Different tokens → different tunnels | <yes/no> |
| First hop is the bridge when bridges are on | <yes/no> |
| Relay nickname available from the path | no — ChanTarget carries ids and addresses only; nicknames would need the netdir |

## Decision

<GO: build the helper on Arti / NO-GO: reason, and what to try instead>

## Notes for the helper plan

<anything surprising: warnings, slow steps, API shapes that differ from the spec>
```

The `<…>` markers are the slots for the observed values; every one must be replaced by a real result before committing.

- [ ] **Step 2: Update the spec if the spike contradicts it**

If nicknames are unavailable (expected), change the `circuit` event in `docs/superpowers/specs/2026-11-05-tortuga-design.md` from `nickname` to `id` (the relay's Ed25519 identity, shortened in the UI). Apply any other contradiction the findings list.

- [ ] **Step 3: Commit**

```bash
git add docs/spike-findings.md docs/superpowers/specs/2026-11-05-tortuga-design.md
git commit -m "docs: Arti spike findings and decision"
```

---

## Next plans (written after this spike, in order)

Each produces working, testable software on its own and is planned only once the previous one has landed, because it depends on what was learned:

1. **Helper core** — workspace `helper/`, native messaging framing, `hello` handshake, own SOCKS5 server with username → `IsolationToken`, `tor.start / tor.stop / tor.newCircuit`, `tor.status`, `circuit` events, bundled `lyrebird`, Moat bridge fetching.
2. **Extension Tor mode** — `extension/` scaffold from Nomada's layout and tokens, Firefox `proxy.onRequest` with site usernames (`tldts`), Chrome incognito scope, fail-closed states, popup Route tab with the metro diagram, bridge picker and connecting animation, settings page.
3. **Torrents** — `librqbit` in the helper, `torrent.*` messages, persistence, Downloads tab, link capture, context menu, confirm window.
4. **Installers and release** — macOS `.pkg` (signed, notarized), Windows `.msi`, Linux `.deb` / AppImage, native host registration for Chrome and Firefox, store listings with the "not Tor Browser" disclaimer.
