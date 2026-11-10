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

## Real Tor

With Tor on, every app on the Mac goes through Tor, each on its own circuit;
DNS goes through Tor; nothing leaves directly while Tor isn't ready.
Excepted apps, local networks, and Tortuga's own helper go out directly.
An exception covers the process that connects: `curl` started from an
excepted terminal still goes through Tor.

It needs your team's signing (`Local.xcconfig`, from `Local.xcconfig.example`)
and the app in /Applications:

```sh
scripts/install-dev.sh            # build fresh, verify, install to /Applications, open
```

The first time Tor is switched on, macOS asks you to allow Tortuga's network
extension (System Settings → General → Login Items & Extensions → Network
Extensions). `scripts/live-check.sh` checks it from the terminal with Tor on.
The extension logs to the unified log (`log stream --predicate 'subsystem == "org.tortuga.app"'`):
statuses, each flow's app and decision, DNS paths; never host names.

Builds launched with `-scenario <name>`, and the Demo tab in debug builds,
use `DemoEngine` instead.
