# Tortuga for macOS

A native app that will send the whole Mac through Tor
(design: `docs/superpowers/specs/2026-11-09-macos-app-design.md`). This is
part 1: the full interface on `DemoEngine`, a simulated engine. **It does not
use Tor or the network yet.**

## Needs

- macOS 26 or later, Xcode 26 or later
- XcodeGen: `brew install xcodegen`

## Build and run

```sh
cd macos
xcodegen generate                       # writes Tortuga.xcodeproj (not in git)
open Tortuga.xcodeproj                  # or build from the command line:
xcodebuild -project Tortuga.xcodeproj -scheme Tortuga -derivedDataPath build build
open build/Build/Products/Debug/Tortuga.app
```

It runs from the menu bar (a tortoise). The window opens at first launch and
from "Open Tortuga".

To sign with your team, copy `Local.xcconfig.example` to `Local.xcconfig`
and put in your team ID. Without it, builds are signed to run locally.

## Demo scenarios

Debug builds have a Demo tab in Settings (⌘,). You can also launch with
`-scenario <name>`:

| Scenario | What happens |
|---|---|
| `normal` | Tor connects in ~4 s, four apps appear, Mail is an exception |
| `slowBootstrap` | connecting takes 30 s |
| `bridgeFails` | Snowflake never connects; switch to obfs4 ("Get lines") to recover |
| `torDies` | Tor stops 5 s after connecting; Restart brings it back |
| `manyApps` | 30 apps, half of them idle |
| `empty` | Tor on, no apps |

## Tests

```sh
swift test --package-path Packages/TortugaKit
swift test --package-path Packages/TortugaUI
xcodebuild test -project Tortuga.xcodeproj -scheme Tortuga -destination 'platform=macOS' -derivedDataPath build
```

The UI tests keep screenshots of the window in the result bundle. Add
`-resultBundlePath build/ui.xcresult` to the last command, then run
`xcrun xcresulttool export attachments --path build/ui.xcresult --output-path <folder>`.
The first run asks to let Xcode's test runner control the computer; allow it
in System Settings.

## A SwiftUI note

Don't put `glassEffect` directly on a view that has buttons inside it: on
macOS 27 the glass takes their clicks. Use `glassCard(cornerRadius:)` from
`Theme.swift`, which draws the glass behind the content.

## Real Tor (in progress)

`TortugaProxy` is a system extension that will send the whole Mac through
Tor (spec: `docs/superpowers/specs/2026-11-10-macos-real-tor-design.md`).
It needs your team's signing:

1. Sign in to your developer account in Xcode → Settings → Accounts.
2. Copy `Local.xcconfig.example` to `Local.xcconfig` and put in your team ID.
3. Run `scripts/install-dev.sh`: macOS activates system extensions only
   from /Applications.

Without `Local.xcconfig` the app builds and runs on `DemoEngine`, but can't
install its extension. Building the extension also builds the helper
(`cargo`) and fetches lyrebird (`gpg`); set `TORTUGA_SKIP_HELPER=1` to skip
that.

`Packages/TortugaProxyKit` holds the extension's logic. Its tests run with
`swift test --package-path Packages/TortugaProxyKit`; one of them talks to
the real helper if `helper/target/release/tortuga-helper` is built.
