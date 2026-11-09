# Tortuga for macOS: real Tor for the whole Mac — design

Status: approved for planning. This is parts 2 and 3 of
`2026-11-09-macos-app-design.md`, done as one step. Torrents in the app
(part 4) are not in it.

## Goal

When the app is switched to Tor, every app on the Mac reaches the network
through Tor, each app on its own circuit, apart from the excepted ones. The
Route screen shows the real relays. Nothing goes out directly while Tor
isn't ready. DNS doesn't leak to the local network.

## Decisions

| Question | Decision |
|---|---|
| Order | One step: engine and system extension together, starting with a one-day spike on the user's Mac |
| Tor engine | The existing `tortuga-helper` binary, run by the system extension, spoken to with its JSON protocol |
| Per-app circuits | The SOCKS username is the app's signing identifier (today it's the site) |
| Capturing TCP | `NETransparentProxyProvider` |
| Capturing DNS | `NEDNSProxyProvider` in the same system extension |
| Other UDP (QUIC, calls) | Closed, so apps fall back to TCP |
| Where settings live | In the extension, which runs without the app |
| Torrents | Not in this step (the extension runs as root; downloads must belong to the user) |

### Why the helper as a process

- **Reuse.** The helper already runs Arti with bridges and Moat. Its SOCKS
  server isolates streams by username and reports each key's hops in
  `circuit` events. It is covered by 61 tests and is shipped today.
- **Failure isolation.** A crash in Arti or `lyrebird` takes down the helper,
  not the extension. The extension keeps traffic held back and restarts it.
- **Rejected: a Rust library in the extension (UniFFI).** That means new
  bindings and moving Arti into the extension's process, where a crash takes
  the extension with it.
- **Rejected: Tor in the app.** Quitting the app from the menu bar would block
  the whole Mac.

## Processes

```
Tortuga.app  (UI, menu bar; ProxyEngine implements TortugaEngine)
   │  XPC (Mach service of the extension): state stream + commands
   ▼
TortugaProxy.systemextension  (root, runs whether or not the app does)
   ├─ TransparentProxy (NETransparentProxyProvider)  TCP flows
   ├─ DNSProxy (NEDNSProxyProvider)                 DNS queries
   ├─ Supervisor: runs Contents/Helpers/tortuga-helper (+ pt/lyrebird), restarts it
   └─ Store: mode, bridge, bridge lines, exceptions (a plist in the extension's container)
```

**The extension.**
- **Activation:** it lives in the app bundle. When Tor is first switched on,
  the app activates it with `OSSystemExtensionRequest`. The user allows it
  once in System Settings.
- **Mode:** *Tor* enables both provider configurations
  (`NETransparentProxyManager`, `NEDNSProxyManager`). *Direct* disables them,
  so traffic goes out directly and the helper is stopped.
- **Quitting the app** changes nothing: Tor and the blocking keep working.

**The helper.** It is the same binary and the same protocol as the `.pkg`
installs. It gains two things:
- **`tor.resolve {name}`:** resolves a name through Tor (Arti's `resolve`,
  answered at the exit). The reply is
  `resolved {addresses: [String]}`, or `error` with `tor_failed`.
- **`apps` feature:** listed in `hello.features` and understood by the
  helper. It adds nothing to the wire: a SOCKS username is already an
  isolation key, and `circuit` events already name the key in `site`. The
  feature only says this helper answers `tor.resolve`.

**Never sent through Tor:**
- the helper and `lyrebird` themselves (otherwise it's Tor over Tor);
- loopback, link-local and private networks (printers, AirDrop, the router);
- excepted apps.

## Traffic

### TCP (`NEAppProxyTCPFlow`)

For each new flow, `FlowRouter.decide(flow, state)`, a pure function, picks
one of three:

1. **`.direct`**: return `false` from `handleNewFlow`, and macOS sends the
   flow itself. This is for the helper, `lyrebird`, excepted apps, and local
   and private destinations.
2. **`.refuse`**: Tor isn't ready (connecting, blocked, failed). Close the
   flow with an error; the app sees a failed connection.
3. **`.tor(host, port, isolation)`**: open the flow, then connect with
   `NWConnection` to the helper's SOCKS port on 127.0.0.1. Send the SOCKS5
   username/password handshake (username = app signing identifier, password
   `x`), then CONNECT and relay bytes both ways until either side closes.
   The host is chosen in this order:
   - `flow.remoteHostname`, when the app connected by name (most do: Safari,
     URLSession, Network.framework);
   - the name from `NameCache` (IP → name, filled by DNS answers);
   - the IP itself.

   Connecting by name lets the exit resolve it, so no lookup goes anywhere
   else.

### DNS (`NEDNSProxyProvider`)

macOS resolves names in `mDNSResponder`. The DNS proxy sees every query
the system makes and handles each as follows:

- **A and AAAA:** resolved with `tor.resolve`. The answer is built as a normal
  DNS response with a 60 s TTL, and each address → name pair goes into
  `NameCache` (shared with the TCP side, which is in the same process).
- **Every other type** (MX, TXT, SRV, HTTPS…) gets an empty NOERROR answer.
  It can't go through Tor, and it isn't sent anywhere else.
- **While Tor isn't ready:** SERVFAIL.
- **Queries from excepted apps** are answered through Tor too, because the
  DNS proxy can't always tell who asked. Resolving through Tor doesn't stop
  an excepted app from then connecting directly.

`DNSMessage` parses queries and builds answers. It handles one question per
message and name compression on reading. It never compresses when writing.

### Other UDP

Any UDP flow the transparent proxy sees that isn't DNS is closed: QUIC and
HTTP/3, calls, games. Browsers and most apps fall back to TCP. The
Exceptions screen says calls need their app excepted.

### Routes in the UI

- **Relays:** the helper's `circuit {site: <app ID>, bridge, hops}` events are
  turned into `AppRoute.middle` and `.exit`, and into `Trunk` (bridge, guard).
- **Activity:** `connections` (open flows) and `lastActive` are counted by
  the extension.
- **New circuit:** sends `tor.newCircuit {site: <app ID>}`; with no app, it
  sends one per app.

## App and extension

**XPC.** The extension's Info.plist sets `NEMachServiceName`
(`$(TeamIdentifierPrefix)org.tortuga.app.proxy`). The app connects with
`NSXPCConnection(machServiceName:)`. The interface is two calls carrying
`Codable` JSON:

- `subscribe(reply)`: the current `EngineState`, then every change, pushed
  through the exported object of the app's side.
- `perform(command) → result`: one per `TortugaEngine` command.

`ProxyEngine` (in a new `TortugaProxyKit` package shared by the app and the
extension) implements `TortugaEngine` over this connection. The UI keeps
working unchanged. `DemoEngine` stays for previews, UI tests and the Demo
tab.

**Engine choice in the app.**
- **Real engine:** `ProxyEngine` is used when the app runs from
  `/Applications` with the extension available.
- **Demo engine:** `DemoEngine` is used when a `-scenario` launch argument is
  given (UI tests) or when the Demo tab picks a scenario (debug builds).

**Downloads with the real engine.** The Downloads screen says "Downloads come
in a later version". Its commands throw that message.

## Signing and activation

- **Team ID:** goes in `macos/Local.xcconfig`. The user signs in to their
  developer account in Xcode (Settings → Accounts) once. Automatic signing
  then creates the certificates and the App IDs `org.tortuga.app` and
  `org.tortuga.app.proxy`.
- **Capabilities:**
  - the app: System Extension;
  - the extension: Network Extensions (`app-proxy-provider-systemextension`,
    `dns-proxy-systemextension`).
- **Dev builds:** macOS activates system extensions only for an app in
  `/Applications`. `macos/scripts/install-dev.sh` builds, copies to
  `/Applications/Tortuga.app` and opens it.
- **First Tor on:** macOS asks the user to allow the extension (System
  Settings → General → Login Items & Extensions → Network Extensions).
  Until they do, the status is
  `.failed("Allow Tortuga's network extension in System Settings")`, with a
  button that opens that pane.

## Errors

| What happens | Status | Next step |
|---|---|---|
| Extension not allowed yet | `.failed("Allow Tortuga's network extension in System Settings")` | button opens the pane |
| Helper won't start or dies | `.blocked("Tor stopped")`; flows refused, DNS SERVFAIL | Restart (the supervisor also retries 3 times, 2 s apart) |
| Bridge can't connect | `.failed(<the helper's tor.status message>)` | Bridges… |
| Extension unreachable from the app | `.failed("Tortuga's network extension isn't running")` | Restart re-activates it |

The extension logs to the unified log under subsystem `org.tortuga.app`.
Connection contents and host names are never logged; app IDs and counts may
be.

## Tests

- **Rust:** `tor.resolve` parsing and reply; `apps` in `hello.features`.
- **Swift, in `TortugaProxyKit` (`swift test`, no network):**
  - `FlowRouter` decisions: excepted, helper, local, private and link-local
    addresses, Tor not ready, by name vs by IP vs from `NameCache`;
  - `DNSMessage` parsing (with compression) and building, against bytes
    captured from `dig`;
  - `NameCache` eviction and TTL;
  - `HelperClient`: framing, hello, request/reply matching, events, against a
    fake process;
  - SOCKS5 client handshake bytes;
  - the `circuit` → `AppRoute`/`Trunk` mapping.
- **Live check** (`macos/scripts/live-check.sh`, run by hand with Tor on):
  - `curl -s https://check.torproject.org/api/ip` shows `"IsTor":true`;
  - two apps' exits differ (`curl` and a second tool with a different
    signing ID);
  - `dig example.com` answers. Meanwhile `tcpdump -i en0 port 53` sees no
    packets;
  - an excepted app gets the real IP;
  - after `kill` of the helper, `curl` fails instead of going out directly,
    and Restart brings it back.
- **UI tests:** unchanged, on `DemoEngine`.

## Order of work

1. **Spike, first:** a minimal system extension that only logs flows (app
   ID, `remoteHostname`, protocol) and DNS queries. On the user's Mac, check
   that:
   - it activates;
   - app IDs and host names are there;
   - `mDNSResponder`'s queries reach the DNS proxy;
   - the extension can run the helper and `lyrebird`.

   Write the results into `docs/spike-findings.md`. If any of them fails,
   stop and decide together before going on.
2. Rust: `tor.resolve` and the `apps` feature.
3. `TortugaProxyKit`, pure logic first, tested as above.
4. The extension: providers, supervisor, store, XPC.
5. `ProxyEngine` in the app, engine choice, activation flow.
6. Live check.

## Not in this step

- Torrents in the app (part 4), and the helper for the browser extension
  inside the app bundle.
- Notarised release packaging.
- Any change to the browser extension.
