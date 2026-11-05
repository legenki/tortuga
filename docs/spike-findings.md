# Arti spike findings

Date: 2026-11-05
Arti: arti-client 0.48.0 · Tor Expert Bundle 16.0 (lyrebird for Snowflake) · macOS arm64

| Question | Result |
|---|---|
| Direct bootstrap works, time | Yes, 5.4 s (fresh state) |
| Snowflake bootstrap works, time | Yes. Bootstrap took 0.27 s because the directory was cached by the direct run; every circuit's first hop was the Snowflake bridge `192.0.2.3:80` |
| Each stream exposes its tunnel path (`ClientStreamCtrl::tunnel`) | Yes |
| Hops have addresses and a GeoIP country | Yes for relays (US, MD, DE, FR, NL). The Snowflake bridge shows `??`: its address is the placeholder `192.0.2.3`, the real peer is a volunteer's browser |
| Same IsolationToken → same tunnel | Yes (`example.com` twice → `Circ 1.0` both times) |
| Different tokens → different tunnels | Yes (`example.org` → `Circ 2.0`, different middle and exit) |
| First hop is the bridge when bridges are on | Yes |
| Relay nickname available from the path | No — `ChanTarget` carries Ed25519 / RSA ids and addresses only |

## Decision

**GO: build the helper on Arti.** Everything the metro diagram and per-site
isolation need is available from a stream, and Snowflake works through the
bundled `lyrebird`.

## Notes for the helper plan

- The `circuit` event carries `id` (Ed25519 identity, shortened in the UI), not `nickname`.
- A bridge hop's country is often unknown (Snowflake always). The UI shows the
  bridge's transport, never a country, for the bridge station.
- Arti's default state and cache live in `~/Library/Application Support/org.torproject.Arti`
  and `~/Library/Caches/org.torproject.Arti`, shared with any other Arti on the
  machine. The helper must set its own `storage.state_dir` and `storage.cache_dir`.
- Different isolated circuits used different guards (two US guards in the direct run).
- The Expert Bundle maps Snowflake to `lyrebird` (`pt_config.json`), so one
  bundled binary covers obfs4, WebTunnel, meek and Snowflake. Default Snowflake
  bridge lines come from the same file.
- Bootstrap through Snowflake from a cold state was not measured; the helper
  plan should measure it, because the connecting animation and the 30 s
  "try another bridge" timeout depend on it.
- macOS has no `timeout` command; the plan's run steps were adjusted to `perl -e 'alarm N; exec @ARGV'`.
