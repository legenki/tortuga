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

## macOS system extension (2026-11-10)

macOS 27.0.1, Xcode 27.2, Apple Development signing (team Y6A9LRQDH7),
app in /Applications. Spike code: `macos/TortugaProxy/Spike*.swift`, driven
from the debug Spike window. Four runs.

**Q1. Does it activate and do both proxies start?** Yes.
`systemextensionsctl list` shows `org.tortuga.app.proxy … [activated enabled]`;
the log shows `transparent proxy started, settings error: nil` and
`DNS proxy started`. It took three fixes to get there, all needed for the
real extension:
- the extension's Info.plist needs `CFBundlePackageType = SYSX`, or sysextd
  says it "does not appear to belong to any extension categories";
- `NEMachServiceName` must start with an app group the extension has
  (`com.apple.security.application-groups: $(TeamIdentifierPrefix)org.tortuga.app`),
  or the network-extension category rejects it ("invalid NEMachServiceName");
- with Apple Development signing the entitlement values are
  `app-proxy-provider` and `dns-proxy`, not the `-systemextension` ones
  (those are for Developer ID); xcodebuild needs
  `-allowProvisioningUpdates -allowProvisioningDeviceRegistration` the first time.

A new build replaces the extension without asking again, as long as
`CFBundleVersion` goes up; the proxy session stops on replacement and must
be started again.

**Q2. Do flows carry the app's signing ID?** Yes, for TCP and UDP flows and
for DNS queries: `app=com.apple.Safari`, `app=com.apple.curl`,
`app=org.mozilla.firefox`, `app=com.apple.apsd`, `app=com.anthropic.claude-code`…
Command-line tools signed ad hoc show their cdhash-style ID
(`app=limactl-5555…`).

**Q3. Is `host=` filled for TCP?** For apps that connect by name, yes:
Safari (6/6 flows), curl (`host=example.com`), Claude Code. Firefox resolves
names itself and often connects by IP (`host=-`, `endpoint=31.13.86.36:443`),
so the IP → name cache from the DNS proxy is needed. UDP flows (QUIC) carry
the host too (`flow udp app=org.mozilla.firefox host=github.com`).

**Q4. What reaches the DNS proxy?** Every DNS query, attributed to the asking
app: `com.apple.mDNSResponder`, Safari, Firefox, apsd, limactl, Claude. A
direct query (`dig` to 8.8.8.8) went to the DNS proxy too, not to the
transparent proxy.

**Q5. Can the extension run the helper and lyrebird?**
- From its installed copy (`/Library/SystemExtensions/<uuid>/…`): **no**.
  sysextd strips the execute bit from everything but the main executable
  (`-rw-r--r-- tortuga-helper`).
- From a copy it writes into its container and `chmod 755`: **no**; the
  sandbox won't run files the extension wrote ("doesn't exist").
- From the app's copy in `/Applications/Tortuga.app/Contents/Library/SystemExtensions/…`:
  **yes**. `lyrebird -version` exits 0, and the helper answers
  `{"type":"hello",…,"features":["torrent-via-tor","torrent-open","apps"]}`.

  This only worked after the helper was built with liblzma in statically:
  the build had linked Homebrew's `/opt/homebrew/opt/xz/lib/liblzma.5.dylib`,
  which the sandbox can't see. The 0.2.0 release has the same problem (fixed
  in `fix/static-liblzma`).

**Q6. Does the network keep working with the spike on?** Only with the
transparent proxy alone. A DNS proxy whose `handleNewFlow` returns `false`
drops every query (curl and dig fail, the whole Mac loses DNS); the
transparent proxy returning `false` lets flows go out as usual (curl 200,
dig answers).

### What plan 2 must do differently from the spec

- Run the helper and lyrebird from the app bundle in /Applications, passing
  `TORTUGA_PT_DIR` there; the extension finds the app by its known path (or
  the app tells it in the provider configuration). If the app is moved or
  deleted, Tor can't start: say so in the status.
- The DNS proxy must answer every query itself (through Tor, or SERVFAIL);
  it can never pass one on by returning `false`.
- Use the development entitlement values in development and the
  `-systemextension` ones for Developer ID builds (two entitlements files, or
  a build setting).
- Keep the three Info.plist/entitlement fixes above.
