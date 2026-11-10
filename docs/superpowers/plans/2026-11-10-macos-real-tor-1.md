# Real Tor for the Mac, plan 1: spike, helper resolve, proxy logic

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove on the user's Mac that a transparent-proxy and DNS-proxy
system extension works as the spec needs it to. Teach the helper to
resolve names through Tor. Build and test every piece of the proxy's logic
that needs no system extension.

**Architecture:**
- **Spike:** a throwaway `TortugaProxy` system extension that only logs
  flows and DNS queries and runs the bundled helper once. A debug-only Spike
  window in the app activates and enables it.
- **Helper:** gains `tor.resolve` and the `apps` feature.
- **`TortugaProxyKit`:** a new Swift package holding the pure parts (flow
  decisions, local addresses, DNS messages, the IP → name cache, SOCKS5
  client bytes, the helper protocol and client, and circuit → route
  mapping), all tested without a network.

**Plan 2** (written after the spike, from its findings) covers:
- the real providers, the helper supervisor and the store;
- XPC and `ProxyEngine` in the app;
- the activation flow and the live check.

**Tech Stack:** Rust (arti-client 0.48, tokio), Swift 6 (tools 6.2,
swift-testing), NetworkExtension, SystemExtensions, XcodeGen 2.46.

**Spec:** `docs/superpowers/specs/2026-11-10-macos-real-tor-design.md`.

**Conventions:**
- **Directory:** run commands from the repository root unless a step says
  otherwise.
- **Commits:** each message ends with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Branch:** `feat/macos-real-tor`.

---

## File map

| File | Responsibility |
|---|---|
| `macos/Config/Base.xcconfig` | entitlements off by default, so unsigned builds and CI still run |
| `macos/Local.xcconfig.example` | team, signing, and the entitlements files to use |
| `macos/Tortuga/Tortuga.entitlements` | app: install system extensions, network extension types |
| `macos/TortugaProxy/TortugaProxy.entitlements` | extension: sandbox, network extension types |
| `macos/TortugaProxy/Helper.entitlements` | helper and lyrebird: sandbox + inherit |
| `macos/TortugaProxy/main.swift` | system extension entry point |
| `macos/TortugaProxy/SpikeTransparentProxy.swift` | spike: logs flows, passes them through |
| `macos/TortugaProxy/SpikeDNSProxy.swift` | spike: logs DNS flows |
| `macos/TortugaProxy/SpikeHelperCheck.swift` | spike: runs the bundled helper (hello) and lyrebird |
| `macos/scripts/embed-helper.sh` | build phase: build helper, fetch lyrebird, copy and sign them into the extension |
| `macos/scripts/install-dev.sh` | build, copy to /Applications, open |
| `macos/Tortuga/SpikeWindow.swift` | debug: activate the extension, enable/disable the proxies |
| `macos/project.yml` | the TortugaProxy target, embedding, entitlements settings |
| `docs/spike-findings.md` | spike results |
| `helper/tortuga-helper/src/{protocol,app,tor}.rs` | `tor.resolve`, `resolved`, the `apps` feature |
| `macos/Packages/TortugaProxyKit/…` | the proxy's pure logic and its tests |

---

### Task 1 (the user): sign in and set the team

Signing with the user's team can't be done for them. Ask the user to do
these steps, then go on.

- [ ] **Step 1:** In Xcode → Settings → Accounts, sign in with the Apple
  Developer account. Note the Team ID shown for the paid team, or find it
  on developer.apple.com → Membership.
- [ ] **Step 2:** Create `macos/Local.xcconfig` with:

```
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = <the Team ID>
TORTUGA_APP_ENTITLEMENTS = Tortuga/Tortuga.entitlements
TORTUGA_PROXY_ENTITLEMENTS = TortugaProxy/TortugaProxy.entitlements
```

- [ ] **Step 3:** Check that it's ignored by git.

Run: `git check-ignore macos/Local.xcconfig`
Expected: `macos/Local.xcconfig`

---

### Task 2: the spike extension and its build

**Files:**
- Modify: `macos/Config/Base.xcconfig`, `macos/Local.xcconfig.example`, `macos/project.yml`
- Create: `macos/Tortuga/Tortuga.entitlements`, `macos/TortugaProxy/TortugaProxy.entitlements`, `macos/TortugaProxy/Helper.entitlements`
- Create: `macos/TortugaProxy/main.swift`, `macos/TortugaProxy/SpikeTransparentProxy.swift`, `macos/TortugaProxy/SpikeDNSProxy.swift`, `macos/TortugaProxy/SpikeHelperCheck.swift`
- Create: `macos/scripts/embed-helper.sh`, `macos/scripts/install-dev.sh`

- [ ] **Step 1: Make entitlements opt-in in Base.xcconfig**

Network-extension entitlements need a provisioning profile. An ad-hoc signed
app that claims them is killed at launch, which would break CI and unsigned
UI tests. Append to `macos/Config/Base.xcconfig`, before the `#include?`
line:

```
// Entitlements need the team's provisioning profiles: Local.xcconfig turns
// them on. Without them the app runs, but can't install its extension.
TORTUGA_APP_ENTITLEMENTS =
TORTUGA_PROXY_ENTITLEMENTS =
```

Append to `macos/Local.xcconfig.example`:

```
TORTUGA_APP_ENTITLEMENTS = Tortuga/Tortuga.entitlements
TORTUGA_PROXY_ENTITLEMENTS = TortugaProxy/TortugaProxy.entitlements
```

- [ ] **Step 2: Write the entitlements files**

`macos/Tortuga/Tortuga.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.system-extension.install</key>
	<true/>
	<key>com.apple.developer.networking.networkextension</key>
	<array>
		<string>app-proxy-provider-systemextension</string>
		<string>dns-proxy-systemextension</string>
	</array>
</dict>
</plist>
```

`macos/TortugaProxy/TortugaProxy.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.developer.networking.networkextension</key>
	<array>
		<string>app-proxy-provider-systemextension</string>
		<string>dns-proxy-systemextension</string>
	</array>
</dict>
</plist>
```

`macos/TortugaProxy/Helper.entitlements` (for programs the sandboxed
extension starts; they take on its sandbox):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.inherit</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 3: Write the extension's entry point and spike providers**

`macos/TortugaProxy/main.swift`:

```swift
import Foundation
import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
```

`macos/TortugaProxy/SpikeTransparentProxy.swift`:

```swift
import Foundation
import Network
import NetworkExtension
import os

let spikeLog = Logger(subsystem: "org.tortuga.app", category: "spike")

/// Spike only: logs every flow it's offered and passes it through. Host names
/// are logged publicly here and nowhere else; the real provider never logs them.
final class SpikeTransparentProxy: NETransparentProxyProvider {
    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil, localPrefix: 0, protocol: .TCP, direction: .outbound),
            NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil, localPrefix: 0, protocol: .UDP, direction: .outbound),
        ]
        setTunnelNetworkSettings(settings) { error in
            spikeLog.notice("spike: transparent proxy started, settings error: \(String(describing: error), privacy: .public)")
            SpikeHelperCheck.run()
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        spikeLog.notice("spike: transparent proxy stopped (\(reason.rawValue))")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let app = flow.metaData.sourceAppSigningIdentifier
        let host = flow.remoteHostname ?? "-"
        let kind = flow is NEAppProxyTCPFlow ? "tcp" : "udp"
        var endpoint = "-"
        if let tcp = flow as? NEAppProxyTCPFlow { endpoint = "\(tcp.remoteFlowEndpoint)" }
        spikeLog.notice("spike: flow \(kind, privacy: .public) app=\(app, privacy: .public) host=\(host, privacy: .public) endpoint=\(endpoint, privacy: .public)")
        return false
    }
}
```

`macos/TortugaProxy/SpikeDNSProxy.swift`:

```swift
import Foundation
import NetworkExtension

/// Spike only: logs who sends DNS and lets it through (returns false).
final class SpikeDNSProxy: NEDNSProxyProvider {
    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        spikeLog.notice("spike: DNS proxy started")
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        spikeLog.notice("spike: DNS proxy stopped (\(reason.rawValue))")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let kind = flow is NEAppProxyTCPFlow ? "tcp" : "udp"
        spikeLog.notice("spike: dns \(kind, privacy: .public) app=\(flow.metaData.sourceAppSigningIdentifier, privacy: .public)")
        return false
    }
}
```

`macos/TortugaProxy/SpikeHelperCheck.swift`:

```swift
import Foundation

/// Spike only: can the sandboxed extension run the bundled helper and
/// lyrebird? Sends hello to the helper and logs the reply; runs lyrebird
/// with -version and logs its exit status.
enum SpikeHelperCheck {
    static func run() {
        DispatchQueue.global().async {
            helper()
            lyrebird()
        }
    }

    private static func helper() {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "tortuga-helper") else {
            spikeLog.error("spike: no tortuga-helper in the bundle")
            return
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = url
        process.standardInput = input
        process.standardOutput = output
        process.environment = ["TORTUGA_DATA_DIR": NSTemporaryDirectory() + "tortuga-spike"]
        do {
            try process.run()
        } catch {
            spikeLog.error("spike: helper didn't start: \(error.localizedDescription, privacy: .public)")
            return
        }
        let hello = Data(#"{"id":1,"type":"hello","payload":{"protocol":1}}"#.utf8)
        var length = UInt32(hello.count).littleEndian
        input.fileHandleForWriting.write(Data(bytes: &length, count: 4) + hello)
        let head = output.fileHandleForReading.readData(ofLength: 4)
        guard head.count == 4 else {
            spikeLog.error("spike: helper closed without answering")
            return
        }
        let size = head.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        let body = output.fileHandleForReading.readData(ofLength: size)
        spikeLog.notice("spike: helper said \(String(decoding: body, as: UTF8.self), privacy: .public)")
        process.terminate()
    }

    private static func lyrebird() {
        guard let macOS = Bundle.main.executableURL?.deletingLastPathComponent() else { return }
        let process = Process()
        process.executableURL = macOS.appending(path: "pt/lyrebird")
        process.arguments = ["-version"]
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            spikeLog.notice("spike: lyrebird -version exited \(process.terminationStatus)")
        } catch {
            spikeLog.error("spike: lyrebird didn't start: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 4: Write the build-phase and install scripts**

`macos/scripts/embed-helper.sh`:

```sh
#!/bin/sh
# Xcode build phase of TortugaProxy: put tortuga-helper and pt/{lyrebird,
# pt_config.json} into the extension's Contents/MacOS and sign them so they
# may run inside its sandbox. Set TORTUGA_SKIP_HELPER=1 to skip (CI's app job).
set -eu
[ "${TORTUGA_SKIP_HELPER:-}" = 1 ] && exit 0
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
HELPER="$SRCROOT/../helper"
(cd "$HELPER" && cargo build --release -p tortuga-helper)
PT="$HELPER/target/pt-macos"
[ -x "$PT/lyrebird" ] || "$HELPER/scripts/fetch-pt.sh" 16.0 "" "$PT"
DEST="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
mkdir -p "$DEST/pt"
cp "$HELPER/target/release/tortuga-helper" "$DEST/tortuga-helper"
cp "$PT/lyrebird" "$PT/pt_config.json" "$DEST/pt/"
SIGN="${EXPANDED_CODE_SIGN_IDENTITY:--}"
for bin in "$DEST/tortuga-helper" "$DEST/pt/lyrebird"; do
  codesign --force --options runtime --sign "$SIGN" --entitlements "$SRCROOT/TortugaProxy/Helper.entitlements" "$bin"
done
```

`macos/scripts/install-dev.sh`:

```sh
#!/bin/sh
# Build Tortuga, put it in /Applications (macOS activates system extensions
# only from there) and open it. Arguments go to the app, e.g. -spike YES.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Tortuga.xcodeproj -scheme Tortuga -configuration Debug -derivedDataPath build build | tail -1
pkill -x Tortuga 2>/dev/null || true
rm -rf /Applications/Tortuga.app
cp -R build/Build/Products/Debug/Tortuga.app /Applications/
open /Applications/Tortuga.app --args "$@"
```

Run: `chmod +x macos/scripts/embed-helper.sh macos/scripts/install-dev.sh`

- [ ] **Step 5: Add the target to project.yml**

In `macos/project.yml`:

1. Under `Tortuga:` → `dependencies:`, add the extension:

```yaml
      - target: TortugaProxy
```

2. Under `Tortuga:` → `settings: base:`, add:

```yaml
        CODE_SIGN_ENTITLEMENTS: $(TORTUGA_APP_ENTITLEMENTS)
```

3. Add this target after `Tortuga:` (before `TortugaAppUITests:`):

```yaml
  TortugaProxy:
    type: system-extension
    platform: macOS
    sources: [TortugaProxy]
    dependencies:
      - package: TortugaKit
    info:
      path: TortugaProxy/Info.plist
      properties:
        CFBundleDisplayName: Tortuga Proxy
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        NSSystemExtensionUsageDescription: Sends this Mac's traffic through Tor.
        NetworkExtension:
          NEMachServiceName: $(DEVELOPMENT_TEAM).org.tortuga.app.proxy
          NEProviderClasses:
            com.apple.networkextension.app-proxy: $(PRODUCT_MODULE_NAME).SpikeTransparentProxy
            com.apple.networkextension.dns-proxy: $(PRODUCT_MODULE_NAME).SpikeDNSProxy
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.tortuga.app.proxy
        PRODUCT_NAME: org.tortuga.app.proxy
        PRODUCT_MODULE_NAME: TortugaProxy
        ENABLE_HARDENED_RUNTIME: YES
        SWIFT_VERSION: "6.0"
        CODE_SIGN_ENTITLEMENTS: $(TORTUGA_PROXY_ENTITLEMENTS)
    postBuildScripts:
      - name: Embed tortuga-helper and lyrebird
        script: '"$SRCROOT/scripts/embed-helper.sh"'
        basedOnDependencyAnalysis: false
```

4. Add `macos/TortugaProxy/Info.plist` to `.gitignore` next to
   `macos/Tortuga/Info.plist`, because it is generated.

- [ ] **Step 6: Build and check the bundle**

Run:

```bash
cd macos && xcodegen generate && xcodebuild -project Tortuga.xcodeproj -scheme Tortuga -configuration Debug -derivedDataPath build build | tail -1 && ls build/Build/Products/Debug/Tortuga.app/Contents/Library/SystemExtensions/org.tortuga.app.proxy.systemextension/Contents/MacOS build/Build/Products/Debug/Tortuga.app/Contents/Library/SystemExtensions/org.tortuga.app.proxy.systemextension/Contents/MacOS/pt
```

Expected: `** BUILD SUCCEEDED **`, then `org.tortuga.app.proxy`, `pt` and
`tortuga-helper`, then `lyrebird` and `pt_config.json`.

If the extension isn't under `Contents/Library/SystemExtensions`, XcodeGen
didn't embed it. Add `embed: true` and
`copy: {destination: plugins, subpath: ../Library/SystemExtensions}` to
the `- target: TortugaProxy` dependency and build again.

- [ ] **Step 7: Check that the unsigned path still works**

Run: `cd macos && mv Local.xcconfig Local.xcconfig.off && TORTUGA_SKIP_HELPER=1 xcodebuild test -project Tortuga.xcodeproj -scheme Tortuga -destination 'platform=macOS' -derivedDataPath build-unsigned | grep -E "TEST (SUCCEEDED|FAILED)"; mv Local.xcconfig.off Local.xcconfig`
Expected: `** TEST SUCCEEDED **`. Without a team, the app still builds and
its UI tests run.

- [ ] **Step 8: Commit**

```bash
git add .gitignore macos/Config macos/Local.xcconfig.example macos/project.yml macos/Tortuga/Tortuga.entitlements macos/TortugaProxy macos/scripts
git commit -m "feat(macos): spike system extension that logs flows and runs the helper" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: the Spike window in the app

**Files:**
- Create: `macos/Tortuga/SpikeWindow.swift`
- Modify: `macos/Tortuga/TortugaApp.swift`

- [ ] **Step 1: Write the Spike window**

`macos/Tortuga/SpikeWindow.swift`:

```swift
#if DEBUG
import NetworkExtension
import SwiftUI
import SystemExtensions

/// Debug only, for the spike: activate the system extension and switch its
/// two proxies on and off, showing what macOS answers.
struct SpikeWindow: View {
    @State private var lines: [String] = []
    @State private var activator: SpikeActivator?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Activate extension") {
                    let activator = SpikeActivator { line in Task { @MainActor in lines.append(line) } }
                    self.activator = activator
                    activator.activate()
                }
                Button("Enable proxies") { Task { await set(true) } }
                Button("Disable proxies") { Task { await set(false) } }
            }
            .buttonStyle(.glass)
            ScrollView {
                Text(lines.joined(separator: "\n")).font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 560, height: 360)
    }

    private func set(_ on: Bool) async {
        do {
            try await SpikeProxies.set(on)
            lines.append("proxies \(on ? "enabled" : "disabled")")
        } catch {
            lines.append("proxies: \(error.localizedDescription)")
        }
    }
}

final class SpikeActivator: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    private let report: @Sendable (String) -> Void

    init(report: @escaping @Sendable (String) -> Void) { self.report = report }

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: "org.tortuga.app.proxy", queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        report("activation requested")
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        report("replacing \(existing.bundleShortVersion) with \(ext.bundleShortVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        report("needs approval: System Settings → General → Login Items & Extensions")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        report("activated (result \(result.rawValue))")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        report("activation failed: \(error.localizedDescription)")
    }
}

@MainActor
enum SpikeProxies {
    static func set(_ on: Bool) async throws {
        let manager = try await NETransparentProxyManager.loadAllFromPreferences().first ?? NETransparentProxyManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "org.tortuga.app.proxy"
        proto.serverAddress = "Tortuga"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Tortuga"
        manager.isEnabled = on
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        if on { try manager.connection.startVPNTunnel() } else { manager.connection.stopVPNTunnel() }

        let dns = NEDNSProxyManager.shared()
        try await dns.loadFromPreferences()
        let dnsProto = NEDNSProxyProviderProtocol()
        dnsProto.providerBundleIdentifier = "org.tortuga.app.proxy"
        dnsProto.serverAddress = "Tortuga"
        dns.providerProtocol = dnsProto
        dns.localizedDescription = "Tortuga DNS"
        dns.isEnabled = on
        try await dns.saveToPreferences()
    }
}
#endif
```

- [ ] **Step 2: Add the window to the app**

In `macos/Tortuga/TortugaApp.swift`, after the `Settings { … }` scene inside
`body`, add:

```swift
        #if DEBUG
        Window("Spike", id: "spike") {
            SpikeWindow()
        }
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: "spike") ? .presented : .suppressed)
        #endif
```

- [ ] **Step 3: Build**

Run: `cd macos && xcodegen generate && xcodebuild -project Tortuga.xcodeproj -scheme Tortuga -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`. Deprecation warnings about
`NENetworkRule(remoteNetwork:…)` are acceptable in spike code.

- [ ] **Step 4: Commit**

```bash
git add macos/Tortuga
git commit -m "feat(macos): debug Spike window to activate and enable the extension" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4 (with the user): run the spike and write the findings

macOS shows approval dialogs and settings panes only the user can click.
Run the commands yourself and ask the user for each click.

- [ ] **Step 1: Install and open**

Run: `macos/scripts/install-dev.sh -spike YES -didShowWelcome YES`
Expected: the Spike window opens.

- [ ] **Step 2: Activate.** Ask the user to click *Activate extension*,
  then allow it in System Settings → General → Login Items & Extensions →
  Network Extensions. The window should then show `activated`.
- [ ] **Step 3: Watch the log** in the background:

Run (background): `log stream --style compact --predicate 'subsystem == "org.tortuga.app"' > /tmp/tortuga-spike.log`

- [ ] **Step 4: Enable.** Ask the user to click *Enable proxies* and to
  accept the "add VPN configuration" prompt if one appears.
- [ ] **Step 5: Make traffic:**

Run:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://example.com
dig +short example.com
open -a Safari https://www.torproject.org
```

Then wait ten seconds.

- [ ] **Step 6: Read the results**

Run: `grep spike: /tmp/tortuga-spike.log | sort | uniq -c | sort -rn | head -40`

Answer each question from the log:
- **Q1.** Did the extension activate and both proxies start?
  (`transparent proxy started`, `DNS proxy started`)
- **Q2.** Do TCP flows carry the app's signing ID? (`app=com.apple.curl`
  or similar, `app=com.apple.Safari`)
- **Q3.** Is `host=` filled for Safari and curl, which connect by name?
- **Q4.** Does the DNS proxy see the system's queries
  (`dns … app=com.apple.mDNSResponder` or the app's own)? Does `dig`'s
  direct UDP query show up in the DNS proxy, or only in the transparent
  proxy as a `udp` flow?
- **Q5.** Did `helper said {"id":1,"type":"hello",…}` appear, and did
  `lyrebird -version exited 0`?
- **Q6.** With both proxies returning `false`, did DNS and web keep working?

- [ ] **Step 7: Disable.** Ask the user to click *Disable proxies*.
  Then stop the log stream.
- [ ] **Step 8: Write the findings**

Append to `docs/spike-findings.md` a section
`## macOS system extension (2026-11-10)` with:
- the answers to Q1–Q6, each with the log line that shows it;
- the macOS and Xcode versions (`sw_vers -productVersion`,
  `xcodebuild -version | head -1`);
- what plan 2 must do differently from the spec because of any answer.

If Q1, Q2, Q4 or Q5 is "no", stop here and bring the findings to the
user before going on.

- [ ] **Step 9: Commit**

```bash
git add docs/spike-findings.md
git commit -m "docs: spike findings for the macOS system extension" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: helper: `tor.resolve` and the `apps` feature

**Files:**
- Modify: `helper/tortuga-helper/src/protocol.rs`
- Modify: `helper/tortuga-helper/src/tor.rs`
- Modify: `helper/tortuga-helper/src/app.rs`

- [ ] **Step 1: Write the failing tests**

In `helper/tortuga-helper/src/protocol.rs`, inside `mod tests`, add:

```rust
    #[test]
    fn parses_resolve() {
        assert_eq!(
            parse(json!({"id": 7, "type": "tor.resolve", "payload": {"name": "example.com"}})),
            Request { id: 7, body: RequestBody::TorResolve { name: "example.com".into() } }
        );
    }

    #[test]
    fn writes_resolved() {
        let m = serde_json::to_value(Message::reply(7, Outgoing::Resolved { addresses: vec!["93.184.215.14".into()] })).unwrap();
        assert_eq!(m, json!({"id": 7, "type": "resolved", "payload": {"addresses": ["93.184.215.14"]}}));
    }

    #[test]
    fn says_it_serves_apps() {
        assert!(FEATURES.contains(&"apps"));
    }
```

In `helper/tortuga-helper/src/app.rs`, inside `mod tests`, add:

```rust
    #[tokio::test]
    async fn resolve_needs_tor() {
        let (app, mut rx, _dir) = app();
        app.handle(req(json!({"id": 1, "type": "hello", "payload": {"protocol": PROTOCOL_VERSION}}))).await;
        rx.recv().await.unwrap();
        app.handle(req(json!({"id": 2, "type": "tor.resolve", "payload": {"name": "example.com"}}))).await;
        let answer = json_of(rx.recv().await.unwrap());
        assert_eq!(answer["id"], 2);
        assert_eq!(answer["payload"]["code"], "not_running");
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd helper && cargo test -p tortuga-helper resolve 2>&1 | tail -5`
Expected: compile errors, `no variant named TorResolve`.

- [ ] **Step 3: Implement**

In `protocol.rs`:
- **`FEATURES`:** replace it with
  `pub const FEATURES: &[&str] = &["torrent-via-tor", "torrent-open", "apps"];`
- **Doc comment:** extend the one above `FEATURES` with the line
  `` /// `apps`: `tor.resolve`, for a client whose isolation keys are apps. ``
- **`RequestBody`:** add after `TorNewCircuit`:

```rust
    /// Resolve a name through Tor (answered at an exit).
    #[serde(rename = "tor.resolve")]
    TorResolve { name: String },
```

- **`Outgoing`:** add after `TorReady`:

```rust
    #[serde(rename = "resolved")]
    Resolved { addresses: Vec<String> },
```

In `tor.rs`, inside `impl Tor`, after `new_circuit`:

```rust
    /// Resolve `name` through Tor; the exit does the lookup.
    pub async fn resolve(&self, name: &str) -> anyhow::Result<Vec<std::net::IpAddr>> {
        Ok(self.client.resolve(name).await?)
    }
```

In `app.rs`, inside `handle`'s `match req.body`, after the
`RequestBody::TorNewCircuit` arm:

```rust
            RequestBody::TorResolve { name } => match &state.tor {
                Some(tor) if state.socks.is_some() => {
                    let tor = tor.clone();
                    let app = self.clone();
                    tokio::spawn(async move {
                        let reply = match tor.resolve(&name).await {
                            Ok(ips) => Message::reply(req.id, Outgoing::Resolved { addresses: ips.iter().map(|ip| ip.to_string()).collect() }),
                            Err(e) => Message::error(Some(req.id), ErrorCode::TorFailed, format!("{e:#}")),
                        };
                        app.send(reply);
                    });
                }
                _ => self.send(Message::error(Some(req.id), ErrorCode::NotRunning, "Tor is off")),
            },
```

In the existing test in `protocol.rs` that checks the hello payload
(`"features": ["torrent-via-tor", "torrent-open"]`), change the expected
array to `["torrent-via-tor", "torrent-open", "apps"]`.

- [ ] **Step 4: Run all helper tests and clippy**

Run: `cd helper && cargo test -p tortuga-helper 2>&1 | grep -E "test result|FAILED" && cargo clippy -p tortuga-helper --all-targets -- -D warnings 2>&1 | tail -2`
Expected: every `test result: ok` (65 tests), clippy clean.

- [ ] **Step 5: Commit**

```bash
git add helper/tortuga-helper/src
git commit -m "feat(helper): tor.resolve, and the apps feature for per-app isolation" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: TortugaProxyKit: local addresses and flow decisions

**Files:**
- Create: `macos/Packages/TortugaProxyKit/Package.swift`
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/LocalAddress.swift`
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/NameCache.swift`
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/FlowRouter.swift`
- Create: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/FlowRouterTests.swift`

- [ ] **Step 1: Write the manifest**

`macos/Packages/TortugaProxyKit/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TortugaProxyKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TortugaProxyKit", targets: ["TortugaProxyKit"])],
    dependencies: [.package(path: "../TortugaKit")],
    targets: [
        .target(name: "TortugaProxyKit", dependencies: ["TortugaKit"]),
        .testTarget(name: "TortugaProxyKitTests", dependencies: ["TortugaProxyKit", "TortugaKit"]),
    ]
)
```

- [ ] **Step 2: Write the failing tests**

`macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/FlowRouterTests.swift`:

```swift
import Foundation
import Testing
@testable import TortugaProxyKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test(arguments: ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.3.4",
                  "224.0.0.251", "255.255.255.255", "0.0.0.0", "::1", "fe80::1", "fd12::1", "ff02::fb", "::ffff:192.168.1.1"])
func localAddresses(_ ip: String) {
    #expect(LocalAddress.isLocal(ip))
}

@Test(arguments: ["8.8.8.8", "172.32.0.1", "93.184.215.14", "2001:4860:4860::8888", "::ffff:8.8.8.8", "not an ip", "example.com"])
func publicAddresses(_ ip: String) {
    #expect(!LocalAddress.isLocal(ip))
}

private func flow(app: String = "com.apple.Safari", host: String? = "example.com", ip: String = "93.184.215.14",
                  port: Int = 443, udp: Bool = false) -> FlowInfo {
    FlowInfo(app: app, remoteHost: host, remoteIP: ip, port: port, isUDP: udp)
}

private let ready = RouterState(torReady: true, exceptions: ["com.apple.mail"], own: ["org.tortuga.helper"])

@Test func byNameThroughTorIsolatedByApp() {
    #expect(FlowRouter.decide(flow(), ready, names: NameCache(), now: t0)
            == .tor(host: "example.com", port: 443, isolation: "com.apple.Safari"))
}

@Test func byIPUsesTheNameFromDNS() {
    let names = NameCache()
    names.record(ip: "93.184.215.14", name: "example.com", now: t0)
    #expect(FlowRouter.decide(flow(host: nil), ready, names: names, now: t0)
            == .tor(host: "example.com", port: 443, isolation: "com.apple.Safari"))
}

@Test func byIPWithoutANameKeepsTheIP() {
    #expect(FlowRouter.decide(flow(host: nil), ready, names: NameCache(), now: t0)
            == .tor(host: "93.184.215.14", port: 443, isolation: "com.apple.Safari"))
}

@Test func exceptedOwnAndLocalGoDirect() {
    #expect(FlowRouter.decide(flow(app: "com.apple.mail"), ready, names: NameCache(), now: t0) == .direct)
    #expect(FlowRouter.decide(flow(app: "org.tortuga.helper"), ready, names: NameCache(), now: t0) == .direct)
    #expect(FlowRouter.decide(flow(host: "printer.local", ip: "192.168.1.20"), ready, names: NameCache(), now: t0) == .direct)
}

@Test func nothingGoesOutWhileTorIsntReady() {
    let notReady = RouterState(torReady: false, exceptions: [], own: [])
    #expect(FlowRouter.decide(flow(), notReady, names: NameCache(), now: t0) == .refuse)
    #expect(FlowRouter.decide(flow(host: "router.lan", ip: "192.168.1.1"), notReady, names: NameCache(), now: t0) == .direct)
}

@Test func udpIsClosed() {
    #expect(FlowRouter.decide(flow(port: 443, udp: true), ready, names: NameCache(), now: t0) == .refuse)
}

@Test func namesExpireAndTheCacheStaysSmall() {
    let names = NameCache(capacity: 2)
    names.record(ip: "1.1.1.1", name: "a", ttl: 10, now: t0)
    #expect(names.name(for: "1.1.1.1", now: t0.addingTimeInterval(9)) == "a")
    #expect(names.name(for: "1.1.1.1", now: t0.addingTimeInterval(11)) == nil)
    names.record(ip: "2.2.2.2", name: "b", now: t0)
    names.record(ip: "3.3.3.3", name: "c", now: t0)
    names.record(ip: "4.4.4.4", name: "d", now: t0)
    #expect(names.count == 2)
    #expect(names.name(for: "4.4.4.4", now: t0) == "d")
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "error:" | head -3`
Expected: a build error (`target 'TortugaProxyKit' … is empty`, or
`cannot find 'LocalAddress'`).

- [ ] **Step 4: Implement**

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/LocalAddress.swift`:

```swift
import Network

/// Addresses that stay on this Mac or its network (loopback, private,
/// link-local, multicast): never sent through Tor.
public enum LocalAddress {
    public static func isLocal(_ ip: String) -> Bool {
        if let v4 = IPv4Address(ip) { return isLocal(v4: [UInt8](v4.rawValue)) }
        if let v6 = IPv6Address(ip) {
            let b = [UInt8](v6.rawValue)
            if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }      // ::1
            if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }                   // fe80::/10
            if (b[0] & 0xFE) == 0xFC { return true }                                   // fc00::/7
            if b[0] == 0xFF { return true }                                            // ff00::/8
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {   // ::ffff:a.b.c.d
                return isLocal(v4: Array(b[12..<16]))
            }
            return false
        }
        return false
    }

    private static func isLocal(v4 b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): true
        case (172, 16...31): true
        case (224...255, _): true   // multicast, reserved, broadcast
        default: false
        }
    }
}
```

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/NameCache.swift`:

```swift
import Foundation
import Synchronization

/// Names the DNS proxy answered, by address, so a flow that connects to an
/// address can still go through Tor by name. Shared by the DNS and TCP sides.
public final class NameCache: Sendable {
    /// How long a name is remembered: longer than the 60 s TTL we answer
    /// with, since apps connect a while after they look a name up.
    public static let defaultTTL: TimeInterval = 600

    private struct Entry { var name: String; var expires: Date; var order: UInt64 }
    private struct Store { var entries: [String: Entry] = [:]; var counter: UInt64 = 0 }

    private let capacity: Int
    private let store = Mutex(Store())

    public init(capacity: Int = 4096) {
        self.capacity = capacity
    }

    public func record(ip: String, name: String, ttl: TimeInterval = NameCache.defaultTTL, now: Date = .now) {
        store.withLock { s in
            s.counter += 1
            s.entries[ip] = Entry(name: name, expires: now.addingTimeInterval(ttl), order: s.counter)
            while s.entries.count > capacity, let oldest = s.entries.min(by: { $0.value.order < $1.value.order })?.key {
                s.entries[oldest] = nil
            }
        }
    }

    public func name(for ip: String, now: Date = .now) -> String? {
        store.withLock { s in
            guard let entry = s.entries[ip], entry.expires > now else { return nil }
            return entry.name
        }
    }

    public var count: Int { store.withLock { $0.entries.count } }
}
```

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/FlowRouter.swift`:

```swift
import Foundation

/// A flow as the transparent proxy sees it.
public struct FlowInfo: Sendable, Equatable {
    /// The app's code-signing identifier.
    public var app: String
    /// The name the app connected to, when it connected by name.
    public var remoteHost: String?
    public var remoteIP: String
    public var port: Int
    public var isUDP: Bool

    public init(app: String, remoteHost: String?, remoteIP: String, port: Int, isUDP: Bool) {
        self.app = app
        self.remoteHost = remoteHost
        self.remoteIP = remoteIP
        self.port = port
        self.isUDP = isUDP
    }
}

/// What the router needs to know besides the flow.
public struct RouterState: Sendable, Equatable {
    public var torReady: Bool
    /// Apps the user excepted.
    public var exceptions: Set<String>
    /// The helper and lyrebird: their traffic must never go through Tor.
    public var own: Set<String>

    public init(torReady: Bool, exceptions: Set<String>, own: Set<String>) {
        self.torReady = torReady
        self.exceptions = exceptions
        self.own = own
    }
}

public enum FlowDecision: Sendable, Equatable {
    /// Let macOS send it as usual.
    case direct
    /// Close it: Tor isn't ready, or it's UDP.
    case refuse
    /// Through the helper's SOCKS port, isolated by `isolation`.
    case tor(host: String, port: Int, isolation: String)
}

public enum FlowRouter {
    public static func decide(_ flow: FlowInfo, _ state: RouterState, names: NameCache, now: Date = .now) -> FlowDecision {
        if state.own.contains(flow.app) || state.exceptions.contains(flow.app) || LocalAddress.isLocal(flow.remoteIP) {
            return .direct
        }
        if flow.isUDP || !state.torReady { return .refuse }
        let byName = flow.remoteHost.flatMap { $0.isEmpty ? nil : $0 }
        let host = byName ?? names.name(for: flow.remoteIP, now: now) ?? flow.remoteIP
        return .tor(host: host, port: flow.port, isolation: flow.app)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "warning:|error:|Test run with"`
Expected: `Test run with 28 tests … passed` and no warnings. The
parameterised tests count each argument as a test.

- [ ] **Step 6: Commit**

```bash
git add macos/Packages/TortugaProxyKit
git commit -m "feat(macos): TortugaProxyKit with flow decisions, local addresses and the name cache" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: DNS messages

**Files:**
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/DNSMessage.swift`
- Create: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/DNSMessageTests.swift`

- [ ] **Step 1: Write the failing tests**

`macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/DNSMessageTests.swift`:

```swift
import Foundation
import Testing
@testable import TortugaProxyKit

/// A query for example.com, type `type`, id 0x1234, recursion desired, as dig sends it.
private func query(type: UInt16 = 1) -> Data {
    var b: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    b += [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0]
    b += [UInt8(type >> 8), UInt8(type & 0xFF), 0x00, 0x01]
    return Data(b)
}

@Test func parsesAQuery() throws {
    let q = try #require(DNSMessage.parseQuery(query()))
    #expect(q.id == 0x1234)
    #expect(q.question == DNSQuestion(name: "example.com", type: DNSType.a, klass: 1))
}

@Test func refusesGarbage() {
    #expect(DNSMessage.parseQuery(Data([0x12, 0x34])) == nil)
    var noQuestion = [UInt8](query())
    noQuestion[5] = 0
    #expect(DNSMessage.parseQuery(Data(noQuestion)) == nil)
}

@Test func readsCompressedNames() throws {
    // "com" at 0, then "example" + pointer to 0 at 5.
    let bytes: [UInt8] = [3] + Array("com".utf8) + [0] + [7] + Array("example".utf8) + [0xC0, 0x00]
    var offset = 5
    #expect(try DNSMessage.readName(bytes, at: &offset) == "example.com")
    #expect(offset == 15)
}

@Test func refusesPointerLoops() {
    let bytes: [UInt8] = [0xC0, 0x00]
    var offset = 0
    #expect(throws: DNSMessage.ParseError.self) { try DNSMessage.readName(bytes, at: &offset) }
}

@Test func answersWithTheAddressesOfTheAskedType() throws {
    let q = try #require(DNSMessage.parseQuery(query()))
    let answer = [UInt8](DNSMessage.answer(q, addresses: ["93.184.215.14", "2606:2800::1"], ttl: 60))
    #expect(Array(answer[0..<2]) == [0x12, 0x34])
    #expect(answer[2] & 0x80 == 0x80)                // a response
    #expect(answer[2] & 0x01 == 0x01)                // recursion desired, copied
    #expect(answer[3] & 0x80 == 0x80)                // recursion available
    #expect(answer[3] & 0x0F == 0)                   // NOERROR
    #expect(Array(answer[4..<12]) == [0, 1, 0, 1, 0, 0, 0, 0])  // 1 question, 1 answer (the A only)
    #expect(Array(answer.suffix(4)) == [93, 184, 215, 14])
    #expect(Array(answer.suffix(14).prefix(10)) == [0, 1, 0, 1, 0, 0, 0, 60, 0, 4])  // A, IN, TTL 60, 4 bytes
}

@Test func aaaaAnswersCarrySixteenBytes() throws {
    let q = try #require(DNSMessage.parseQuery(query(type: DNSType.aaaa)))
    let answer = [UInt8](DNSMessage.answer(q, addresses: ["93.184.215.14", "2606:2800::1"], ttl: 60))
    #expect(Array(answer[6..<8]) == [0, 1])
    #expect(Array(answer.suffix(16)) == [0x26, 0x06, 0x28, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
}

@Test func emptyAndFailureAnswers() throws {
    let q = try #require(DNSMessage.parseQuery(query(type: 16)))
    let empty = [UInt8](DNSMessage.empty(q))
    #expect(empty[3] & 0x0F == 0)
    #expect(Array(empty[6..<8]) == [0, 0])
    let failed = [UInt8](DNSMessage.serverFailure(q))
    #expect(failed[3] & 0x0F == 2)
    #expect(Array(failed[6..<8]) == [0, 0])
}

@Test func onlyAddressTypesGoThroughTor() {
    #expect(DNSType.resolvable(DNSType.a))
    #expect(DNSType.resolvable(DNSType.aaaa))
    #expect(!DNSType.resolvable(16))   // TXT
    #expect(!DNSType.resolvable(65))   // HTTPS
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'DNSMessage' in scope`.

- [ ] **Step 3: Implement**

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/DNSMessage.swift`:

```swift
import Foundation
import Network

public struct DNSQuestion: Sendable, Equatable {
    public var name: String
    public var type: UInt16
    public var klass: UInt16
}

public struct DNSQuery: Sendable, Equatable {
    public var id: UInt16
    public var flags: UInt16
    public var question: DNSQuestion
}

public enum DNSType {
    public static let a: UInt16 = 1
    public static let aaaa: UInt16 = 28

    /// Types Tor can answer (it resolves names to addresses, nothing else).
    public static func resolvable(_ type: UInt16) -> Bool { type == a || type == aaaa }
}

/// The DNS proxy's messages: read a query's first question, write answers.
/// Names are read with compression and written without it.
public enum DNSMessage {
    public enum ParseError: Error { case short, badLabel, loop }

    public static func parseQuery(_ data: Data) -> DNSQuery? {
        let b = [UInt8](data)
        guard b.count >= 12 else { return nil }
        let qdcount = Int(b[4]) << 8 | Int(b[5])
        guard qdcount >= 1 else { return nil }
        var offset = 12
        guard let name = try? readName(b, at: &offset), offset + 4 <= b.count else { return nil }
        let type = UInt16(b[offset]) << 8 | UInt16(b[offset + 1])
        let klass = UInt16(b[offset + 2]) << 8 | UInt16(b[offset + 3])
        return DNSQuery(id: UInt16(b[0]) << 8 | UInt16(b[1]),
                        flags: UInt16(b[2]) << 8 | UInt16(b[3]),
                        question: DNSQuestion(name: name, type: type, klass: klass))
    }

    /// The name at `offset`, following compression pointers; `offset` moves
    /// past the name as it is written at that place.
    static func readName(_ b: [UInt8], at offset: inout Int) throws -> String {
        var labels: [String] = []
        var at = offset
        var jumped = false
        var jumps = 0
        while true {
            guard at < b.count else { throw ParseError.short }
            let length = Int(b[at])
            if length & 0xC0 == 0xC0 {
                guard at + 1 < b.count else { throw ParseError.short }
                jumps += 1
                guard jumps <= 16 else { throw ParseError.loop }
                if !jumped { offset = at + 2 }
                jumped = true
                at = (length & 0x3F) << 8 | Int(b[at + 1])
                continue
            }
            guard length & 0xC0 == 0 else { throw ParseError.badLabel }
            if length == 0 {
                if !jumped { offset = at + 1 }
                return labels.joined(separator: ".")
            }
            guard at + 1 + length <= b.count else { throw ParseError.short }
            labels.append(String(decoding: b[(at + 1)...(at + length)], as: UTF8.self))
            at += 1 + length
        }
    }

    /// NOERROR with the addresses that match the question's type.
    public static func answer(_ q: DNSQuery, addresses: [String], ttl: UInt32 = 60) -> Data {
        let records: [[UInt8]] = addresses.compactMap { address in
            if q.question.type == DNSType.a, let v4 = IPv4Address(address) { return [UInt8](v4.rawValue) }
            if q.question.type == DNSType.aaaa, let v6 = IPv6Address(address), IPv4Address(address) == nil {
                return [UInt8](v6.rawValue)
            }
            return nil
        }
        var out = header(q, rcode: 0, answers: records.count) + question(q)
        for rdata in records {
            out += encodeName(q.question.name)
            out += be16(q.question.type) + be16(1) + be32(ttl) + be16(UInt16(rdata.count)) + rdata
        }
        return Data(out)
    }

    /// NOERROR, no answers: for types Tor can't resolve.
    public static func empty(_ q: DNSQuery) -> Data { Data(header(q, rcode: 0, answers: 0) + question(q)) }

    /// SERVFAIL: Tor isn't ready, or the lookup failed.
    public static func serverFailure(_ q: DNSQuery) -> Data { Data(header(q, rcode: 2, answers: 0) + question(q)) }

    private static func header(_ q: DNSQuery, rcode: UInt8, answers: Int) -> [UInt8] {
        let opcode = UInt8((q.flags >> 8) & 0x78)
        let recursionDesired = UInt8((q.flags >> 8) & 0x01)
        let flags1 = 0x80 | opcode | recursionDesired
        let flags2 = 0x80 | (rcode & 0x0F)
        return be16(q.id) + [flags1, flags2] + be16(1) + be16(UInt16(answers)) + be16(0) + be16(0)
    }

    private static func question(_ q: DNSQuery) -> [UInt8] {
        encodeName(q.question.name) + be16(q.question.type) + be16(q.question.klass)
    }

    private static func encodeName(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            out += [UInt8(bytes.count)] + bytes
        }
        return out + [0]
    }

    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}
```

Note on the AAAA filter: `IPv6Address("93.184.215.14")` returns nil, so the
`IPv4Address(address) == nil` check only guards against parsers that accept
IPv4 as IPv6. Keep it.

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "warning:|error:|recorded an issue|Test run with"`
Expected: every test passes, no warnings.

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaProxyKit
git commit -m "feat(macos): DNS messages for the DNS proxy" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: SOCKS5 client bytes

**Files:**
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/Socks5.swift`
- Create: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/Socks5Tests.swift`

- [ ] **Step 1: Write the failing tests**

`macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/Socks5Tests.swift`:

```swift
import Testing
@testable import TortugaProxyKit

@Test func greetingOffersUsernameAuthOnly() {
    #expect(Socks5.greeting == [0x05, 0x01, 0x02])
}

@Test func authCarriesTheAppAsUsername() {
    #expect(Socks5.auth(user: "com.apple.Safari", password: "x")
            == [0x01, 16] + Array("com.apple.Safari".utf8) + [1, UInt8(ascii: "x")])
}

@Test func connectByNameByIPv4AndByIPv6() {
    #expect(Socks5.connect(host: "example.com", port: 443)
            == [0x05, 0x01, 0x00, 0x03, 11] + Array("example.com".utf8) + [0x01, 0xBB])
    #expect(Socks5.connect(host: "93.184.215.14", port: 80) == [0x05, 0x01, 0x00, 0x01, 93, 184, 215, 14, 0x00, 0x50])
    #expect(Socks5.connect(host: "2606:2800::1", port: 443)
            == [0x05, 0x01, 0x00, 0x04, 0x26, 0x06, 0x28, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x01, 0xBB])
}

@Test func checksTheServersAnswers() throws {
    try Socks5.checkMethod([0x05, 0x02])
    #expect(throws: Socks5.ReplyError.noAcceptableMethod) { try Socks5.checkMethod([0x05, 0xFF]) }
    try Socks5.checkAuth([0x01, 0x00])
    #expect(throws: Socks5.ReplyError.authFailed) { try Socks5.checkAuth([0x01, 0x01]) }
}

@Test func connectReplyLengthByAddressType() throws {
    #expect(try Socks5.connectReplyLength([0x05, 0x00, 0x00, 0x01, 0]) == 10)
    #expect(try Socks5.connectReplyLength([0x05, 0x00, 0x00, 0x04, 0]) == 22)
    #expect(try Socks5.connectReplyLength([0x05, 0x00, 0x00, 0x03, 9]) == 16)
    #expect(throws: Socks5.ReplyError.refused(4)) { try Socks5.connectReplyLength([0x05, 0x04, 0x00, 0x01, 0]) }
    #expect(throws: Socks5.ReplyError.badVersion) { try Socks5.connectReplyLength([0x04, 0x00, 0x00, 0x01, 0]) }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'Socks5' in scope`.

- [ ] **Step 3: Implement**

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/Socks5.swift`:

```swift
import Network

/// The client side of SOCKS5 (RFC 1928) with username/password auth
/// (RFC 1929), as the helper's server speaks it: the username is the
/// isolation key (the app), CONNECT only.
public enum Socks5 {
    public enum ReplyError: Error, Equatable {
        case badVersion, noAcceptableMethod, authFailed
        /// The server's CONNECT reply code (4: host unreachable, 5: refused…).
        case refused(UInt8)
    }

    public static let greeting: [UInt8] = [0x05, 0x01, 0x02]

    public static func auth(user: String, password: String) -> [UInt8] {
        let u = Array(user.utf8.prefix(255))
        let p = Array(password.utf8.prefix(255))
        return [0x01, UInt8(u.count)] + u + [UInt8(p.count)] + p
    }

    public static func connect(host: String, port: Int) -> [UInt8] {
        let portBytes: [UInt8] = [UInt8((port >> 8) & 0xFF), UInt8(port & 0xFF)]
        if let v4 = IPv4Address(host) { return [0x05, 0x01, 0x00, 0x01] + [UInt8](v4.rawValue) + portBytes }
        if let v6 = IPv6Address(host) { return [0x05, 0x01, 0x00, 0x04] + [UInt8](v6.rawValue) + portBytes }
        let name = Array(host.utf8.prefix(255))
        return [0x05, 0x01, 0x00, 0x03, UInt8(name.count)] + name + portBytes
    }

    /// The server's answer to `greeting`: two bytes.
    public static func checkMethod(_ reply: [UInt8]) throws {
        guard reply.count == 2, reply[0] == 0x05 else { throw ReplyError.badVersion }
        guard reply[1] == 0x02 else { throw ReplyError.noAcceptableMethod }
    }

    /// The server's answer to `auth`: two bytes.
    public static func checkAuth(_ reply: [UInt8]) throws {
        guard reply.count == 2, reply[1] == 0x00 else { throw ReplyError.authFailed }
    }

    /// The whole CONNECT reply's length, from its first five bytes; throws
    /// if the server refused.
    public static func connectReplyLength(_ head: [UInt8]) throws -> Int {
        guard head.count >= 5, head[0] == 0x05 else { throw ReplyError.badVersion }
        guard head[1] == 0x00 else { throw ReplyError.refused(head[1]) }
        switch head[3] {
        case 0x01: return 10
        case 0x04: return 22
        case 0x03: return 7 + Int(head[4])
        default: throw ReplyError.badVersion
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "warning:|error:|recorded an issue|Test run with"`
Expected: every test passes, no warnings.

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaProxyKit
git commit -m "feat(macos): SOCKS5 client bytes for the helper's server" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: the helper protocol and client

**Files:**
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/HelperMessages.swift`
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/HelperClient.swift`
- Create: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/HelperClientTests.swift`

- [ ] **Step 1: Write the failing tests**

`macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/HelperClientTests.swift`:

```swift
import Foundation
import Testing
@testable import TortugaProxyKit

/// A helper played by the test: what the client writes, and what to answer.
final class FakeTransport: HelperTransport, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let feed: AsyncStream<Data>.Continuation
    private(set) var written: [Data] = []
    private let lock = NSLock()

    init() {
        (incoming, feed) = AsyncStream.makeStream(of: Data.self)
    }

    func write(_ data: Data) async throws {
        lock.withLock { written.append(data) }
    }

    /// Requests written so far, decoded.
    var requests: [[String: Any]] {
        lock.withLock {
            var reader = FrameReader()
            return written.flatMap { reader.push($0) }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    func send(_ json: String) { feed.yield(Framing.encode(Data(json.utf8))) }
    func close() { feed.finish() }
}

@Test func framesAreLengthPrefixedLittleEndian() {
    #expect([UInt8](Framing.encode(Data("{}".utf8))) == [2, 0, 0, 0, 0x7B, 0x7D])
}

@Test func theReaderCopesWithSplitAndJoinedFrames() {
    var reader = FrameReader()
    let two = Framing.encode(Data("{\"a\":1}".utf8)) + Framing.encode(Data("{}".utf8))
    #expect(reader.push(two.prefix(3)).isEmpty)
    #expect(reader.push(two.dropFirst(3)).map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{}"])
}

@Test func parsesTheHelpersMessages() throws {
    func parse(_ s: String) -> HelperMessage? { HelperMessage.parse(Data(s.utf8)) }
    #expect(parse(#"{"id":1,"type":"hello","payload":{"protocol":1,"version":"0.3.0","features":["apps"]}}"#)
            == HelperMessage(id: 1, event: .hello(version: "0.3.0", features: ["apps"])))
    #expect(parse(#"{"type":"tor.status","payload":{"phase":"directory","percent":40,"blocked":null}}"#)?.event
            == .torStatus(phase: "directory", percent: 40, blocked: nil))
    #expect(parse(#"{"id":2,"type":"tor.ready","payload":{"socksPort":49152}}"#)?.event == .torReady(socksPort: 49152))
    #expect(parse(#"{"type":"circuit","payload":{"site":"com.apple.Safari","bridge":"snowflake","hops":[{"role":"bridge","id":"abc","addr":null,"country":null},{"role":"middle","id":"def","addr":"1.2.3.4:9001","country":"DE"}]}}"#)?.event
            == .circuit(site: "com.apple.Safari", bridge: "snowflake", hops: [
                HelperHop(role: "bridge", id: "abc", addr: nil, country: nil),
                HelperHop(role: "middle", id: "def", addr: "1.2.3.4:9001", country: "DE"),
            ]))
    #expect(parse(#"{"id":3,"type":"resolved","payload":{"addresses":["1.2.3.4"]}}"#)?.event == .resolved(["1.2.3.4"]))
    #expect(parse(#"{"id":4,"type":"error","payload":{"code":"not_running","message":"Tor is off"}}"#)?.event
            == .error(code: "not_running", message: "Tor is off"))
    #expect(parse(#"{"id":5,"type":"bridges.lines","payload":{"lines":["Bridge obfs4 x"],"source":"builtin","country":null,"viaTor":false}}"#)?.event
            == .bridgeLines(["Bridge obfs4 x"]))
    #expect(parse(#"{"type":"something.new"}"#)?.event == .other("something.new"))
    #expect(parse("not json") == nil)
}

@Test func requestsAreWrittenWithIDs() async throws {
    let fake = FakeTransport()
    let client = HelperClient(transport: fake)
    async let answer = client.request(.resolve("example.com"))
    try await waitFor { fake.requests.count == 1 }
    let sent = fake.requests[0]
    #expect(sent["type"] as? String == "tor.resolve")
    #expect((sent["payload"] as? [String: Any])?["name"] as? String == "example.com")
    let id = try #require(sent["id"] as? Int)
    fake.send(#"{"id":\#(id),"type":"resolved","payload":{"addresses":["1.2.3.4"]}}"#)
    #expect(try await answer == .resolved(["1.2.3.4"]))
}

@Test func errorsBecomeThrows() async throws {
    let fake = FakeTransport()
    let client = HelperClient(transport: fake)
    async let answer = client.request(.newCircuit(site: "com.apple.Safari"))
    try await waitFor { fake.requests.count == 1 }
    let id = try #require(fake.requests[0]["id"] as? Int)
    fake.send(#"{"id":\#(id),"type":"error","payload":{"code":"not_running","message":"Tor is off"}}"#)
    await #expect(throws: HelperError.remote(code: "not_running", message: "Tor is off")) { try await answer }
}

@Test func eventsWithoutIDsGoToTheEventStream() async throws {
    let fake = FakeTransport()
    let client = HelperClient(transport: fake)
    var events = await client.events.makeAsyncIterator()
    fake.send(#"{"type":"tor.status","payload":{"phase":"ready","percent":100,"blocked":null}}"#)
    #expect(await events.next() == .torStatus(phase: "ready", percent: 100, blocked: nil))
}

@Test func aGoneHelperFailsWaitingRequests() async throws {
    let fake = FakeTransport()
    let client = HelperClient(transport: fake)
    async let answer = client.request(.stop)
    try await waitFor { fake.requests.count == 1 }
    fake.close()
    await #expect(throws: HelperError.gone) { try await answer }
}

@Test func requestBodies() throws {
    func json(_ r: HelperRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: r.encoded(id: 9)) as? [String: Any])
    }
    #expect(try json(.hello)["payload"] as? [String: Int] == ["protocol": 1])
    let start = try json(.start(bridge: "obfs4", lines: ["Bridge obfs4 x"]))
    #expect(start["type"] as? String == "tor.start")
    let bridge = try #require((start["payload"] as? [String: Any])?["bridge"] as? [String: Any])
    #expect(bridge["kind"] as? String == "obfs4")
    #expect(bridge["lines"] as? [String] == ["Bridge obfs4 x"])
    #expect(try json(.fetchBridges(kind: "webtunnel"))["type"] as? String == "bridges.fetch")
}

func waitFor(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out")
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find type 'HelperTransport' in scope`.

- [ ] **Step 3: Implement the messages**

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/HelperMessages.swift`:

```swift
import Foundation

/// Native-messaging framing, as the helper reads and writes it: a 4-byte
/// little-endian length, then that many bytes of JSON.
public enum Framing {
    public static func encode(_ json: Data) -> Data {
        var length = UInt32(json.count).littleEndian
        return Data(bytes: &length, count: 4) + json
    }
}

/// Splits a byte stream into frames, however the bytes arrive.
public struct FrameReader: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func push(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}

public enum HelperRequest: Sendable, Equatable {
    case hello
    /// `bridge`: "none", "snowflake", "obfs4" or "webtunnel".
    case start(bridge: String, lines: [String])
    case stop
    case newCircuit(site: String)
    case resolve(String)
    case fetchBridges(kind: String)

    func encoded(id: UInt64) -> Data {
        let (type, payload): (String, [String: Any]?) = switch self {
        case .hello: ("hello", ["protocol": 1])
        case .start(let bridge, let lines): ("tor.start", ["bridge": ["kind": bridge, "lines": lines]])
        case .stop: ("tor.stop", nil)
        case .newCircuit(let site): ("tor.newCircuit", ["site": site])
        case .resolve(let name): ("tor.resolve", ["name": name])
        case .fetchBridges(let kind): ("bridges.fetch", ["kind": kind])
        }
        var message: [String: Any] = ["id": id, "type": type]
        if let payload { message["payload"] = payload }
        return (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
    }
}

public struct HelperHop: Sendable, Equatable {
    public var role: String
    public var id: String
    public var addr: String?
    public var country: String?
}

public enum HelperEvent: Sendable, Equatable {
    case hello(version: String, features: [String])
    case ok
    case torStatus(phase: String, percent: Int, blocked: String?)
    case torReady(socksPort: Int)
    case circuit(site: String, bridge: String?, hops: [HelperHop])
    case resolved([String])
    case bridgeLines([String])
    case error(code: String, message: String)
    /// A message this client doesn't know (a newer helper's).
    case other(String)
}

public struct HelperMessage: Sendable, Equatable {
    public var id: UInt64?
    public var event: HelperEvent

    public static func parse(_ data: Data) -> HelperMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let p = object["payload"] as? [String: Any] ?? [:]
        let id = (object["id"] as? NSNumber)?.uint64Value
        let event: HelperEvent
        switch type {
        case "hello":
            event = .hello(version: p["version"] as? String ?? "", features: p["features"] as? [String] ?? [])
        case "ok":
            event = .ok
        case "tor.status":
            event = .torStatus(phase: p["phase"] as? String ?? "", percent: p["percent"] as? Int ?? 0, blocked: p["blocked"] as? String)
        case "tor.ready":
            event = .torReady(socksPort: p["socksPort"] as? Int ?? 0)
        case "circuit":
            let hops = (p["hops"] as? [[String: Any]] ?? []).map {
                HelperHop(role: $0["role"] as? String ?? "", id: $0["id"] as? String ?? "",
                          addr: $0["addr"] as? String, country: $0["country"] as? String)
            }
            event = .circuit(site: p["site"] as? String ?? "", bridge: p["bridge"] as? String, hops: hops)
        case "resolved":
            event = .resolved(p["addresses"] as? [String] ?? [])
        case "bridges.lines":
            event = .bridgeLines(p["lines"] as? [String] ?? [])
        case "error":
            event = .error(code: p["code"] as? String ?? "", message: p["message"] as? String ?? "")
        default:
            event = .other(type)
        }
        return HelperMessage(id: id, event: event)
    }
}
```

- [ ] **Step 4: Implement the client**

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/HelperClient.swift`:

```swift
import Foundation

/// How the client reaches the helper: a process's pipes in the extension,
/// a fake in tests.
public protocol HelperTransport: Sendable {
    func write(_ data: Data) async throws
    /// Bytes from the helper as they arrive; finishes when it exits.
    var incoming: AsyncStream<Data> { get }
}

public enum HelperError: Error, Equatable, LocalizedError {
    case remote(code: String, message: String)
    /// The helper exited (or its pipe closed) before answering.
    case gone

    public var errorDescription: String? {
        switch self {
        case .remote(_, let message): message
        case .gone: "Tor stopped"
        }
    }
}

/// Requests with replies matched by id; everything without an id is an event.
public actor HelperClient {
    public nonisolated let events: AsyncStream<HelperEvent>
    private let eventFeed: AsyncStream<HelperEvent>.Continuation
    private let transport: any HelperTransport
    private var nextID: UInt64 = 1
    private var waiting: [UInt64: AsyncThrowingStream<HelperEvent, Error>.Continuation] = [:]
    private var gone = false
    private var reader: Task<Void, Never>?

    public init(transport: any HelperTransport) {
        self.transport = transport
        (events, eventFeed) = AsyncStream.makeStream(of: HelperEvent.self)
        Task { await self.startReading() }
    }

    public func request(_ request: HelperRequest) async throws -> HelperEvent {
        guard !gone else { throw HelperError.gone }
        let id = nextID
        nextID += 1
        let (stream, reply) = AsyncThrowingStream<HelperEvent, Error>.makeStream()
        waiting[id] = reply
        try await transport.write(Framing.encode(request.encoded(id: id)))
        for try await event in stream {
            if case .error(let code, let message) = event { throw HelperError.remote(code: code, message: message) }
            return event
        }
        throw HelperError.gone
    }

    private func startReading() {
        guard reader == nil else { return }
        let incoming = transport.incoming
        reader = Task { [weak self] in
            var frames = FrameReader()
            for await chunk in incoming {
                for frame in frames.push(chunk) {
                    guard let message = HelperMessage.parse(frame) else { continue }
                    await self?.deliver(message)
                }
            }
            await self?.closed()
        }
    }

    private func deliver(_ message: HelperMessage) {
        if let id = message.id, let reply = waiting.removeValue(forKey: id) {
            reply.yield(message.event)
            reply.finish()
        } else {
            eventFeed.yield(message.event)
        }
    }

    private func closed() {
        gone = true
        for reply in waiting.values { reply.finish(throwing: HelperError.gone) }
        waiting.removeAll()
        eventFeed.finish()
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "warning:|error:|recorded an issue|Test run with"`
Expected: every test passes, no warnings.

- [ ] **Step 6: Commit**

```bash
git add macos/Packages/TortugaProxyKit
git commit -m "feat(macos): the helper's protocol and a client for it" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: the real helper speaks to the client

**Files:**
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProcessTransport.swift`
- Create: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/RealHelperTests.swift`

- [ ] **Step 1: Write the failing test**

`macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/RealHelperTests.swift`:

```swift
import Foundation
import Testing
@testable import TortugaProxyKit

/// The helper built by `cargo build --release` (Task 5), if it's there.
private let helper: URL? = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // Tests/…/file → package
        .appending(path: "../../../helper/target/release/tortuga-helper").standardizedFileURL
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}()

@Test(.enabled(if: helper != nil, "build the helper first: cd helper && cargo build --release"))
func theRealHelperSaysHelloWithApps() async throws {
    let data = FileManager.default.temporaryDirectory.appending(path: "tortuga-proxykit-\(UUID().uuidString)")
    let transport = try ProcessTransport(executable: helper!, environment: ["TORTUGA_DATA_DIR": data.path])
    let client = HelperClient(transport: transport)
    guard case .hello(_, let features) = try await client.request(.hello) else {
        Issue.record("no hello")
        return
    }
    #expect(features.contains("apps"))
    await #expect(throws: HelperError.remote(code: "not_running", message: "Tor is off")) {
        try await client.request(.resolve("example.com"))
    }
    transport.terminate()
}
```

- [ ] **Step 2: Build the helper and run the test to see it fail**

Run: `(cd helper && cargo build --release -p tortuga-helper) && swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'ProcessTransport' in scope`.

- [ ] **Step 3: Implement**

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProcessTransport.swift`:

```swift
import Foundation

/// The helper as a child process, spoken to over its stdin and stdout.
public final class ProcessTransport: HelperTransport, @unchecked Sendable {
    public let incoming: AsyncStream<Data>
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    public init(executable: URL, environment: [String: String] = [:]) throws {
        let (stream, feed) = AsyncStream.makeStream(of: Data.self)
        incoming = stream
        process.executableURL = executable
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                feed.finish()
            } else {
                feed.yield(data)
            }
        }
        process.terminationHandler = { _ in feed.finish() }
        try process.run()
    }

    public func write(_ data: Data) async throws {
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    public var isRunning: Bool { process.isRunning }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "warning:|error:|recorded an issue|skipped|Test run with"`
Expected: every test passes, including `theRealHelperSaysHelloWithApps`
(not skipped), with no warnings.

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaProxyKit
git commit -m "feat(macos): run the helper as a process and talk to it" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: from helper events to the UI's state

**Files:**
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/StateMapping.swift`
- Create: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/StateMappingTests.swift`

- [ ] **Step 1: Write the failing tests**

`macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/StateMappingTests.swift`:

```swift
import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func hop(_ role: String, _ id: String, _ addr: String?, _ country: String?) -> HelperHop {
    HelperHop(role: role, id: id, addr: addr, country: country)
}

@Test func aCircuitWithAGuardFillsTheTrunkAndTheApp() {
    var state = EngineState()
    StateMapping.apply(site: "com.apple.Safari", bridge: nil, hops: [
        hop("guard", "AAAAAAAAAAAA", "1.1.1.1:443", "DE"),
        hop("middle", "BBBBBBBBBBBB", "2.2.2.2:9001", "NL"),
        hop("exit", "CCCCCCCCCCCC", "[2001:db8::1]:443", "SE"),
    ], to: &state, now: t0)
    #expect(state.trunk == Trunk(bridge: nil, guardRelay: Relay(nickname: "AAAAAAAA", country: "DE", address: "1.1.1.1")))
    #expect(state.apps == [AppRoute(app: AppID("com.apple.Safari"),
                                    middle: Relay(nickname: "BBBBBBBB", country: "NL", address: "2.2.2.2"),
                                    exit: Relay(nickname: "CCCCCCCC", country: "SE", address: "2001:db8::1"),
                                    connections: 0, lastActive: t0)])
}

@Test func aBridgeHasNoSeparateGuard() {
    var state = EngineState()
    StateMapping.apply(site: "a", bridge: "snowflake", hops: [
        hop("bridge", "AAAAAAAA", nil, nil), hop("middle", "BBBBBBBB", "2.2.2.2:1", "NL"), hop("exit", "CCCCCCCC", "3.3.3.3:1", "SE"),
    ], to: &state, now: t0)
    #expect(state.trunk == Trunk(bridge: .snowflake, guardRelay: nil))
}

@Test func aNewCircuitKeepsTheAppsActivity() {
    var state = EngineState()
    state.apps = [AppRoute(app: AppID("a"), middle: Relay(nickname: "m", country: "PL", address: "9.9.9.9"),
                           exit: Relay(nickname: "e", country: "FI", address: "8.8.8.8"), connections: 3, lastActive: t0)]
    StateMapping.apply(site: "a", bridge: nil, hops: [
        hop("guard", "G", "1.1.1.1:1", "DE"), hop("middle", "M2", "2.2.2.2:1", "NL"), hop("exit", "E2", "3.3.3.3:1", "SE"),
    ], to: &state, now: t0.addingTimeInterval(60))
    #expect(state.apps.count == 1)
    #expect(state.apps[0].exit.address == "3.3.3.3")
    #expect(state.apps[0].connections == 3)
    #expect(state.apps[0].lastActive == t0)
}

@Test func statusFromBootstrap() {
    #expect(StateMapping.status(phase: "bridge", percent: 10, blocked: nil, bridge: .snowflake)
            == .starting(step: "Reaching the bridge", progress: 0.1))
    #expect(StateMapping.status(phase: "bridge", percent: 10, blocked: nil, bridge: nil)
            == .starting(step: "Reaching a guard", progress: 0.1))
    #expect(StateMapping.status(phase: "directory", percent: 55, blocked: nil, bridge: nil)
            == .starting(step: "Loading the network", progress: 0.55))
    #expect(StateMapping.status(phase: "directory", percent: 55, blocked: "Can't reach the bridge", bridge: .obfs4)
            == .starting(step: "Can't reach the bridge", progress: 0.55))
    #expect(StateMapping.status(phase: "ready", percent: 100, blocked: nil, bridge: nil) == .on)
}

@Test func bridgeKindsByTheHelpersNames() {
    #expect(StateMapping.helperName(nil) == "none")
    #expect(StateMapping.helperName(.webtunnel) == "webtunnel")
    #expect(StateMapping.bridge("snowflake") == .snowflake)
    #expect(StateMapping.bridge("none") == nil)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'StateMapping' in scope`.

- [ ] **Step 3: Implement**

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/StateMapping.swift`:

```swift
import Foundation
import TortugaKit

/// The helper's events in the UI's terms (`EngineState`).
public enum StateMapping {
    /// Apply a `circuit` event: the trunk (bridge, guard) and the app's middle
    /// and exit. An app's connection count and last activity are kept; a new
    /// app starts with none, at `now`.
    public static func apply(site: String, bridge: String?, hops: [HelperHop], to state: inout EngineState, now: Date) {
        let kind = bridge.flatMap(Self.bridge)
        state.trunk = Trunk(bridge: kind, guardRelay: hops.first { $0.role == "guard" }.map(relay))
        guard let middle = hops.first(where: { $0.role == "middle" }).map(relay),
              let exit = hops.last(where: { $0.role == "exit" }).map(relay) else { return }
        if let i = state.apps.firstIndex(where: { $0.app.id == site }) {
            state.apps[i].middle = middle
            state.apps[i].exit = exit
        } else {
            state.apps.append(AppRoute(app: AppID(site), middle: middle, exit: exit, connections: 0, lastActive: now))
        }
    }

    public static func status(phase: String, percent: Int, blocked: String?, bridge: BridgeKind?) -> Status {
        if phase == "ready" { return .on }
        let progress = Double(percent) / 100
        if let blocked { return .starting(step: blocked, progress: progress) }
        let step = switch phase {
        case "bridge": bridge == nil ? "Reaching a guard" : "Reaching the bridge"
        default: "Loading the network"
        }
        return .starting(step: step, progress: progress)
    }

    /// The helper's name for a bridge choice.
    public static func helperName(_ kind: BridgeKind?) -> String { kind?.rawValue ?? "none" }

    public static func bridge(_ name: String) -> BridgeKind? { BridgeKind(rawValue: name) }

    static func relay(_ hop: HelperHop) -> Relay {
        Relay(nickname: String(hop.id.prefix(8)), country: hop.country ?? "??", address: hop.addr.map(host) ?? "hidden")
    }

    /// "1.2.3.4:443" → "1.2.3.4"; "[2001:db8::1]:443" → "2001:db8::1".
    static func host(_ addr: String) -> String {
        if addr.hasPrefix("["), let close = addr.firstIndex(of: "]") {
            return String(addr[addr.index(after: addr.startIndex)..<close])
        }
        if let colon = addr.lastIndex(of: ":") { return String(addr[..<colon]) }
        return addr
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "warning:|error:|recorded an issue|Test run with"`
Expected: every test passes, no warnings.

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaProxyKit
git commit -m "feat(macos): map the helper's circuits and status to the UI's state" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: CI and docs

**Files:**
- Modify: `.github/workflows/release.yml` (the `macos-app` job)
- Modify: `macos/README.md`

- [ ] **Step 1: Test the new package in CI, without the helper phase**

In the `macos-app` job of `.github/workflows/release.yml`:
- In the "Package tests" step, add the line
  `swift test --package-path macos/Packages/TortugaProxyKit`.
- Add `env: TORTUGA_SKIP_HELPER: "1"` to the "Build and UI tests" step.

The real-helper test is skipped there, because the helper isn't built in
that job.

- [ ] **Step 2: Add a section to macos/README.md**

Append:

````markdown
## Real Tor (in progress)

`TortugaProxy` is a system extension that will send the whole Mac through
Tor (spec: `docs/superpowers/specs/2026-11-10-macos-real-tor-design.md`).
It needs your team's signing:

1. Sign in to your developer account in Xcode → Settings → Accounts.
2. Copy `Local.xcconfig.example` to `Local.xcconfig` and put in your team ID.
3. Run `scripts/install-dev.sh`: macOS activates system extensions only
   from /Applications.

Without `Local.xcconfig` the app builds and runs on `DemoEngine`, but can't
install its extension.

`Packages/TortugaProxyKit` holds the extension's logic. Its tests run with
`swift test --package-path Packages/TortugaProxyKit`; one of them talks to
the real helper if `helper/target/release/tortuga-helper` is built.
````

- [ ] **Step 3: Check the workflow parses, then commit**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); puts "ok"'`
Expected: `ok`

```bash
git add .github/workflows/release.yml macos/README.md
git commit -m "ci(macos): test TortugaProxyKit; docs for the extension's setup" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Done when

- **The spike:** it ran on the user's Mac, and `docs/spike-findings.md`
  answers Q1–Q6.
- **The helper:** answers `tor.resolve`, lists `apps` in its features, and
  all its tests and clippy pass.
- **`TortugaProxyKit`:** passes all its tests, the real-helper test
  included.
- **Unsigned builds:** the app still builds and its UI tests pass without
  `Local.xcconfig`.
- **Plan 2:** written from the spike's findings.
