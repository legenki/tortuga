# Installers and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Installable helper packages for macOS (.pkg), Linux (.deb) and Windows (zip + per-user `install.ps1`), extension packages for the Chrome Web Store and AMO (with a reproducible source zip), a CI workflow that builds, installs and smoke-tests all of them, and the release steps written down.

**Architecture:** One generator (`helper/packaging/hosts.py`) writes the `org.tortuga.helper` native host manifests for every platform, reading the extension ids from the manifests themselves (Firefox add-on id; Chrome id from a pinned public key). Each platform has a build script under `helper/packaging/<os>/`; `smoke.py` starts an installed helper and checks it answers `hello` with the right version. `.github/workflows/release.yml` runs it all on macOS, Linux (amd64, arm64) and Windows runners and publishes a GitHub release on `v*` tags.

**Tech Stack:** bash, Python 3, `pkgutil` / `mkbom` / `cpio` / `productbuild` (macOS), `dpkg-deb` (Debian), PowerShell (Windows), GitHub Actions, Node for the extension zips.

Spec: `docs/superpowers/specs/2026-11-05-tortuga-design.md` (*Release*).

## Global Constraints

- Install locations: macOS `/Library/Application Support/Tortuga/` (system-wide, root:admin); Linux `/usr/lib/tortuga/`; Windows `%LOCALAPPDATA%\Tortuga\` (per user, no admin). `lyrebird` and `pt_config.json` sit in `pt/` next to the helper (the helper looks there).
- Manifest locations — macOS: `/Library/Application Support/Mozilla/NativeMessagingHosts/`, `/Library/Google/Chrome/NativeMessagingHosts/`, `/Library/Application Support/Chromium/NativeMessagingHosts/`; Linux: `/usr/lib/mozilla/native-messaging-hosts/`, `/etc/opt/chrome/native-messaging-hosts/`, `/etc/chromium/native-messaging-hosts/`; Windows: files next to the helper, registered under `HKCU\Software\{Mozilla,Google\Chrome,Chromium}\NativeMessagingHosts\org.tortuga.helper`.
- Chrome manifests are written only once the Chrome ID is pinned (`manifest.json` "key"); until then installers register Firefox only and say so.
- Transports come from Tor Expert Bundle 16.0 for the target platform, checked against Tor's signed SHA-256 list.
- Signing / notarisation run only when the Developer ID variables or CI secrets exist; nothing in the repo holds keys.
- What can't be checked on a Mac (planning machine: Apple Silicon, Homebrew Rust without rustup, no signing identity, Docker Desktop for Linux): the universal macOS binary, signing, notarisation, the Windows build and install, and the CI run itself — these are checked by the CI workflow after a push, which is the user's call.

## File Structure

| File | Responsibility |
|---|---|
| `helper/scripts/fetch-pt.sh` | Transports for any platform into any folder |
| `helper/packaging/hosts.py`, `test_hosts.py` | Host manifests, extension ids, Chrome key pinning |
| `helper/packaging/smoke.py` | Start a helper, check hello and version |
| `helper/packaging/macos/build-pkg.sh`, `uninstall.sh` | macOS package |
| `helper/packaging/linux/build-deb.sh`, `docker-build.sh` | Debian package, and a Docker build + install test |
| `helper/packaging/windows/build-zip.sh`, `install.ps1`, `uninstall.ps1` | Windows zip and per-user installer |
| `.github/workflows/release.yml` | CI for all platforms and the release |
| `extension/scripts/package.mjs`, `extension/package.json`, `extension/BUILD.md` | Store zips, AMO source zip, build notes |
| `extension/scripts/register-dev-host.sh` | Dev host via `hosts.py` (Chrome too once pinned) |
| `RELEASE.md` | How to release |

Listings are final content: write each file as shown (for changed files, replace the whole file); `chmod +x` every `.sh`, `smoke.py` and `hosts.py`.

---

### Task 1: Transports for any platform, host manifests, a helper that always starts

**Files:**
- Modify: `helper/scripts/fetch-pt.sh`, `helper/tortuga-helper/src/config.rs`
- Create: `helper/packaging/hosts.py`, `helper/packaging/test_hosts.py`, `helper/packaging/smoke.py`

Two bugs the planning install test found, fixed here because every package
depends on them: the helper refused to start (`Error: no Downloads folder`)
where the system names no XDG download dir — servers, containers — taking
Tor down with it; and the Expert Bundle's `pt_config.json` is owner-only
(0600), so installed as root no user's helper could read the default
Snowflake bridges.

**Interfaces:**
- `fetch-pt.sh [VERSION [PLATFORM [OUT_DIR]]]` (PLATFORM: macos-aarch64, macos-x86_64, linux-x86_64, linux-aarch64, windows-x86_64; default this machine; OUT_DIR default `helper/resources/pt`).
- `hosts.py manifests HELPER_PATH OUT_DIR` → `firefox.json` (+ `chrome.json` when pinned); `hosts.py chrome-id`; `hosts.py ids` → `{"firefox": …, "chrome": … | null}`; `hosts.py set-chrome-key PEM`. Python: `chrome_id_from_bytes`, `chrome_id`, `firefox_id`, `manifests`, `write_manifests`, `set_chrome_key`.
- `smoke.py HELPER_EXECUTABLE` → exit 0 when it answers hello with the version in `Cargo.toml`.

- [ ] **Step 1: Tests first**

In `helper/tortuga-helper/src/config.rs` add the test `downloads_folder_falls_back_to_home` from the listing in Step 2.
Run: `cd helper && cargo test -p tortuga-helper config`
Expected: `cannot find function downloads_dir`.

`helper/packaging/test_hosts.py`:

```python
"""Tests for hosts.py. Run: python3 -m unittest discover -s helper/packaging"""
import base64
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

import hosts


class ChromeId(unittest.TestCase):
    def test_chromium_vector(self):
        # crx_file::id_util::GenerateId("test") in Chromium's own tests.
        self.assertEqual(hosts.chrome_id_from_bytes(b"test"), "jpignaibiiemhngfjkcpokkamffknabf")

    def test_set_key_pins_the_id(self):
        with tempfile.TemporaryDirectory() as d:
            d = pathlib.Path(d)
            pem = d / "key.pem"
            subprocess.run(["openssl", "genrsa", "-out", str(pem), "2048"], check=True, capture_output=True)
            manifest = d / "manifest.json"
            manifest.write_text(json.dumps({"manifest_version": 3, "name": "Tortuga — Tor routing"}))
            cid = hosts.set_chrome_key(pem, manifest)
            self.assertRegex(cid, r"^[a-p]{32}$")
            m = json.loads(manifest.read_text())
            self.assertEqual(m["name"], "Tortuga — Tor routing")
            self.assertEqual(hosts.chrome_id(manifest), cid)
            self.assertEqual(hosts.chrome_id_from_bytes(base64.b64decode(m["key"])), cid)

    def test_unpinned(self):
        with tempfile.TemporaryDirectory() as d:
            manifest = pathlib.Path(d) / "manifest.json"
            manifest.write_text("{}")
            self.assertIsNone(hosts.chrome_id(manifest))


class Manifests(unittest.TestCase):
    def test_both_browsers(self):
        m = hosts.manifests("/Library/Application Support/Tortuga/tortuga-helper", "abcdefghijklmnopabcdefghijklmnop", "tortuga@legenki.com")
        self.assertEqual(m["firefox"], {
            "name": "org.tortuga.helper", "description": "Tortuga helper",
            "path": "/Library/Application Support/Tortuga/tortuga-helper", "type": "stdio",
            "allowed_extensions": ["tortuga@legenki.com"],
        })
        self.assertEqual(m["chrome"]["allowed_origins"], ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"])

    def test_no_chrome_without_id(self):
        self.assertEqual(set(hosts.manifests("/x", None, "tortuga@legenki.com")), {"firefox"})

    def test_firefox_id_from_the_repo(self):
        self.assertEqual(hosts.firefox_id(), "tortuga@legenki.com")

    def test_ids_command(self):
        out = subprocess.run([sys.executable, str(pathlib.Path(hosts.__file__)), "ids"], check=True, capture_output=True, text=True).stdout
        ids = json.loads(out)
        self.assertEqual(ids["firefox"], "tortuga@legenki.com")
        self.assertEqual(ids["chrome"], hosts.chrome_id())


if __name__ == "__main__":
    unittest.main()
```

Run: `python3 -m unittest discover -s helper/packaging`
Expected: `ModuleNotFoundError: No module named 'hosts'`.

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
    /// Where torrents are saved: `TORTUGA_DOWNLOADS`, else `~/Downloads/Tortuga`.
    pub downloads: PathBuf,
    /// The torrent list, resumed on the next start.
    pub torrent_state: PathBuf,
}

impl Paths {
    /// Data under `TORTUGA_DATA_DIR` if set (tests, cold-start runs), else the
    /// platform's data and cache dirs. Transports under `TORTUGA_PT_DIR` if
    /// set, else `pt/` next to the executable.
    pub fn discover() -> anyhow::Result<Self> {
        let (state_dir, cache_dir, torrent_state) = match std::env::var_os("TORTUGA_DATA_DIR") {
            Some(d) => {
                let d = PathBuf::from(d);
                (d.join("state"), d.join("cache"), d.join("torrents"))
            }
            None => {
                let dirs = directories::ProjectDirs::from("org", "Tortuga", "tortuga-helper")
                    .ok_or_else(|| anyhow::anyhow!("no home directory"))?;
                (dirs.data_dir().join("arti-state"), dirs.cache_dir().join("arti-cache"), dirs.data_dir().join("torrents"))
            }
        };
        let user = directories::UserDirs::new();
        let downloads = downloads_dir(
            std::env::var_os("TORTUGA_DOWNLOADS").map(PathBuf::from),
            user.as_ref().and_then(|u| u.download_dir().map(|d| d.to_path_buf())),
            user.as_ref().map(|u| u.home_dir().to_path_buf()),
        )
        .ok_or_else(|| anyhow::anyhow!("no home folder for downloads"))?;
        let pt_dir = match std::env::var_os("TORTUGA_PT_DIR") {
            Some(d) => PathBuf::from(d),
            None => std::env::current_exe()?
                .parent()
                .ok_or_else(|| anyhow::anyhow!("executable has no directory"))?
                .join("pt"),
        };
        let exe = if cfg!(windows) { "lyrebird.exe" } else { "lyrebird" };
        Ok(Self {
            state_dir,
            cache_dir,
            lyrebird: pt_dir.join(exe),
            pt_config: pt_dir.join("pt_config.json"),
            downloads,
            torrent_state,
        })
    }
}

/// Where torrents go: `TORTUGA_DOWNLOADS`, else `Tortuga` in the user's
/// Downloads folder — `~/Downloads` when the system names none (servers and
/// containers often don't set XDG user dirs; the helper must still start).
pub fn downloads_dir(env: Option<PathBuf>, downloads: Option<PathBuf>, home: Option<PathBuf>) -> Option<PathBuf> {
    env.or_else(|| downloads.or_else(|| home.map(|h| h.join("Downloads"))).map(|d| d.join("Tortuga")))
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
/// The bridge lines `choice` runs on: its own, or the default Snowflake ones.
pub fn bridge_lines(choice: &BridgeChoice, default_snowflake: &[String]) -> Vec<String> {
    match choice.kind {
        BridgeKind::None => Vec::new(),
        BridgeKind::Snowflake if choice.lines.is_empty() => default_snowflake.to_vec(),
        _ => choice.lines.clone(),
    }
}

pub fn tor_config(choice: &BridgeChoice, paths: &Paths, default_snowflake: &[String]) -> anyhow::Result<TorClientConfig> {
    let mut builder = TorClientConfigBuilder::from_directories(&paths.state_dir, &paths.cache_dir);
    let protocol = match choice.kind {
        BridgeKind::None => return Ok(builder.build()?),
        BridgeKind::Snowflake => "snowflake",
        BridgeKind::Obfs4 => "obfs4",
        BridgeKind::Webtunnel => "webtunnel",
    };
    let lines = bridge_lines(choice, default_snowflake);
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
            downloads: "/tmp/tortuga-test/downloads".into(),
            torrent_state: "/tmp/tortuga-test/torrents".into(),
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
    fn downloads_folder_falls_back_to_home() {
        let some = |s: &str| Some(PathBuf::from(s));
        assert_eq!(downloads_dir(some("/x"), some("/home/u/Downloads"), some("/home/u")), some("/x"));
        assert_eq!(downloads_dir(None, some("/home/u/Downloads"), some("/home/u")), some("/home/u/Downloads/Tortuga"));
        // No XDG download dir (servers, containers): ~/Downloads, not a failure.
        assert_eq!(downloads_dir(None, None, some("/home/u")), some("/home/u/Downloads/Tortuga"));
        assert_eq!(downloads_dir(None, None, None), None);
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

`helper/packaging/hosts.py`:

```python
#!/usr/bin/env python3
"""Native messaging host manifests for org.tortuga.helper, and the Chrome ID.

  hosts.py manifests HELPER_PATH OUT_DIR   write OUT_DIR/firefox.json and,
                                           when the Chrome ID is pinned,
                                           OUT_DIR/chrome.json
  hosts.py chrome-id                       print the pinned Chrome ID
  hosts.py ids                             print {"firefox": …, "chrome": … or null}
                                           (for installers that write the
                                           manifests on the user's machine)
  hosts.py set-chrome-key PEM              pin the Chrome ID: put PEM's public
                                           key into extension/manifest.json

The extension ids come from the manifests themselves: the Firefox add-on id
from manifest.firefox.json, the Chrome id from manifest.json's "key" (Chrome
derives an extension's id from its public key, so a pinned key gives unpacked
builds and installers the same id as the store's copy).
"""
import base64
import hashlib
import json
import pathlib
import subprocess
import sys

HOST_NAME = "org.tortuga.helper"
ROOT = pathlib.Path(__file__).resolve().parents[2]
CHROME_MANIFEST = ROOT / "extension" / "manifest.json"
FIREFOX_MANIFEST = ROOT / "extension" / "manifest.firefox.json"


def chrome_id_from_bytes(data: bytes) -> str:
    """Chrome's id for `data` (a public key in DER): the first 128 bits of its
    SHA-256, each hex digit written as a letter a–p."""
    return "".join(chr(ord("a") + int(c, 16)) for c in hashlib.sha256(data).hexdigest()[:32])


def chrome_id(manifest: pathlib.Path = CHROME_MANIFEST) -> str | None:
    key = json.loads(manifest.read_text()).get("key")
    return chrome_id_from_bytes(base64.b64decode(key)) if key else None


def firefox_id(manifest: pathlib.Path = FIREFOX_MANIFEST) -> str:
    return json.loads(manifest.read_text())["browser_specific_settings"]["gecko"]["id"]


def manifests(helper_path: str, chrome: str | None, firefox: str) -> dict[str, dict]:
    """The host manifests by browser; Chrome only when its id is known."""
    base = {"name": HOST_NAME, "description": "Tortuga helper", "path": helper_path, "type": "stdio"}
    out = {"firefox": base | {"allowed_extensions": [firefox]}}
    if chrome:
        out["chrome"] = base | {"allowed_origins": [f"chrome-extension://{chrome}/"]}
    return out


def write_manifests(helper_path: str, out_dir: pathlib.Path) -> list[pathlib.Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for browser, m in manifests(helper_path, chrome_id(), firefox_id()).items():
        p = out_dir / f"{browser}.json"
        p.write_text(json.dumps(m, indent=2) + "\n")
        written.append(p)
    return written


def public_key_der(pem: pathlib.Path) -> bytes:
    return subprocess.run(["openssl", "rsa", "-in", str(pem), "-pubout", "-outform", "DER"],
                          check=True, capture_output=True).stdout


def set_chrome_key(pem: pathlib.Path, manifest: pathlib.Path = CHROME_MANIFEST) -> str:
    """Put PEM's public key into the Chrome manifest; return the id it gives."""
    der = public_key_der(pem)
    m = json.loads(manifest.read_text())
    m["key"] = base64.b64encode(der).decode()
    manifest.write_text(json.dumps(m, indent=2, ensure_ascii=False) + "\n")
    return chrome_id_from_bytes(der)


def main(argv: list[str]) -> int:
    match argv:
        case ["manifests", helper_path, out_dir]:
            for p in write_manifests(helper_path, pathlib.Path(out_dir)):
                print(p)
            if chrome_id() is None:
                print("no Chrome manifest: pin the Chrome ID first (hosts.py set-chrome-key)", file=sys.stderr)
        case ["chrome-id"]:
            cid = chrome_id()
            if cid is None:
                print("not pinned: extension/manifest.json has no \"key\"", file=sys.stderr)
                return 1
            print(cid)
        case ["ids"]:
            print(json.dumps({"firefox": firefox_id(), "chrome": chrome_id()}))
        case ["set-chrome-key", pem]:
            print(set_chrome_key(pathlib.Path(pem)))
        case _:
            print(__doc__, file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

`helper/packaging/smoke.py`:

```python
#!/usr/bin/env python3
"""Start an installed helper and check it answers hello with this version.

Usage: smoke.py HELPER_EXECUTABLE
Exits non-zero when it doesn't start, doesn't answer, or reports another version.
"""
import json
import pathlib
import re
import struct
import subprocess
import sys

CARGO = pathlib.Path(__file__).resolve().parents[1] / "tortuga-helper" / "Cargo.toml"


def main() -> int:
    want = re.search(r'^version = "(.+)"', CARGO.read_text(), re.M).group(1)
    p = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    body = json.dumps({"id": 1, "type": "hello", "payload": {"protocol": 1}}).encode()
    p.stdin.write(struct.pack("=I", len(body)) + body)
    p.stdin.flush()
    header = p.stdout.read(4)
    if len(header) < 4:
        print("the helper exited without answering", file=sys.stderr)
        return 1
    reply = json.loads(p.stdout.read(struct.unpack("=I", header)[0]))
    p.stdin.close()
    p.wait(timeout=10)
    print(json.dumps(reply))
    got = reply.get("payload", {}).get("version")
    if reply.get("type") != "hello" or got != want:
        print(f"expected hello with version {want}, got {got}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

`helper/scripts/fetch-pt.sh`:

```bash
#!/usr/bin/env bash
# Put lyrebird and pt_config.json from the official Tor Expert Bundle into a
# folder, after checking the bundle's SHA-256 against Tor's signed sums list.
#
# Usage: helper/scripts/fetch-pt.sh [VERSION [PLATFORM [OUT_DIR]]]
#   VERSION   Tor Browser version of the bundle (default 16.0)
#   PLATFORM  macos-aarch64, macos-x86_64, linux-x86_64, linux-aarch64,
#             windows-x86_64 (default: this machine)
#   OUT_DIR   default helper/resources/pt
set -euo pipefail
V="${1:-16.0}"
P="${2:-}"
if [ -z "$P" ]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) P=macos-aarch64 ;;
    Darwin-x86_64) P=macos-x86_64 ;;
    Linux-x86_64) P=linux-x86_64 ;;
    Linux-aarch64 | Linux-arm64) P=linux-aarch64 ;;
    MINGW*-x86_64 | MSYS*-x86_64 | CYGWIN*-x86_64) P=windows-x86_64 ;;
    *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
  esac
fi
HELPER="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${3:-$HELPER/resources/pt}"
F="tor-expert-bundle-$P-$V.tar.gz"
EXE=lyrebird
case "$P" in windows-*) EXE=lyrebird.exe ;; esac
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sSf -o "$TMP/$F" "https://dist.torproject.org/torbrowser/$V/$F"
curl -sSf -o "$TMP/sums.txt" "https://dist.torproject.org/torbrowser/$V/sha256sums-signed-build.txt"
if command -v sha256sum >/dev/null; then SUM="sha256sum -c -"; else SUM="shasum -a 256 -c -"; fi
(cd "$TMP" && grep " $F\$" sums.txt | $SUM)
tar -xzf "$TMP/$F" -C "$TMP"
mkdir -p "$OUT"
cp "$TMP/tor/pluggable_transports/$EXE" "$TMP/tor/pluggable_transports/pt_config.json" "$OUT/"
# The bundle's files are owner-only (0600); installed as root, every user's
# helper must still read pt_config.json and run lyrebird.
chmod 644 "$OUT/pt_config.json"
chmod 755 "$OUT/$EXE"
if [ "$(uname -s)" = Darwin ]; then xattr -d com.apple.quarantine "$OUT/$EXE" 2>/dev/null || true; fi
echo "$EXE and pt_config.json ($P) are in $OUT"
```

- [ ] **Step 3: Run**

Run: `(cd helper && cargo test -p tortuga-helper && cargo build --release -p tortuga-helper) && python3 -m unittest discover -s helper/packaging && python3 helper/packaging/hosts.py ids && python3 helper/packaging/smoke.py helper/target/release/tortuga-helper`
Expected: `test result: ok. 41 passed`; `Ran 7 tests … OK`; `{"firefox": "tortuga@legenki.com", "chrome": null}`; a hello line with `"version": "0.1.0"`. (`test_chromium_vector` is Chromium's own: `GenerateId("test")` = `jpignaibiiemhngfjkcpokkamffknabf`.)

Run: `for p in macos-x86_64 linux-aarch64 windows-x86_64; do helper/scripts/fetch-pt.sh 16.0 $p helper/target/pt-$p; done; file helper/target/pt-*/lyrebird*`
Expected: three `… OK` sum checks; `Mach-O 64-bit executable x86_64`, `ELF 64-bit LSB executable, ARM aarch64`, `PE32+ executable (console) x86-64`; `ls -l helper/target/pt-*` shows `-rwxr-xr-x` lyrebird and `-rw-r--r--` pt_config.json.

- [ ] **Step 4: Commit**

```bash
git add helper/scripts/fetch-pt.sh helper/packaging helper/tortuga-helper/src/config.rs
git commit -m "packaging: host manifests from one place, transports for any platform; helper starts without an XDG Downloads dir"
```

---

### Task 2: macOS package

**Files:**
- Create: `helper/packaging/macos/build-pkg.sh`, `helper/packaging/macos/uninstall.sh`
- Modify: `helper/.gitignore` (packages land in `helper/dist/`)

- [ ] **Step 1: Scripts**

`helper/.gitignore`:

```
/target/
/resources/
/dist/
```

`helper/packaging/macos/build-pkg.sh`:

```bash
#!/usr/bin/env bash
# Build Tortuga-Helper-<version>-macos.pkg in helper/dist/.
#
# Usage: helper/packaging/macos/build-pkg.sh [--universal]
#   --universal  arm64 + x86_64 in one binary (needs rustup targets
#                aarch64-apple-darwin and x86_64-apple-darwin); otherwise
#                this Mac's architecture only.
#
# Signing and notarisation happen only when these are set:
#   DEVELOPER_ID_APP        "Developer ID Application: Name (TEAMID)"
#   DEVELOPER_ID_INSTALLER  "Developer ID Installer: Name (TEAMID)"
#   NOTARY_PROFILE          a `xcrun notarytool store-credentials` profile
#
# The package installs (as root, for every user):
#   /Library/Application Support/Tortuga/{tortuga-helper, pt/, uninstall.sh}
#   the org.tortuga.helper manifests for Firefox, and — once the Chrome ID is
#   pinned (helper/packaging/hosts.py) — for Chrome and Chromium.
set -euo pipefail
HELPER="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$HELPER/tortuga-helper/Cargo.toml" | head -1)"
UNIVERSAL=0
[ "${1:-}" = --universal ] && UNIVERSAL=1
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP_DIR="Library/Application Support/Tortuga"
INSTALLED="/$APP_DIR/tortuga-helper"
ROOT="$STAGE/root"
mkdir -p "$ROOT/$APP_DIR/pt"

# 1. The helper.
cd "$HELPER"
TARGET_DIR="${CARGO_TARGET_DIR:-target}"
if [ $UNIVERSAL = 1 ]; then
  cargo build --release -p tortuga-helper --target aarch64-apple-darwin
  cargo build --release -p tortuga-helper --target x86_64-apple-darwin
  lipo -create -output "$ROOT/$INSTALLED" \
    "$TARGET_DIR/aarch64-apple-darwin/release/tortuga-helper" "$TARGET_DIR/x86_64-apple-darwin/release/tortuga-helper"
else
  cargo build --release -p tortuga-helper
  cp "$TARGET_DIR/release/tortuga-helper" "$ROOT/$INSTALLED"
fi

# 2. lyrebird for the same architectures, from the Tor Expert Bundle.
if [ $UNIVERSAL = 1 ]; then
  scripts/fetch-pt.sh 16.0 macos-aarch64 "$STAGE/pt-arm64"
  scripts/fetch-pt.sh 16.0 macos-x86_64 "$STAGE/pt-x86_64"
  lipo -create -output "$ROOT/$APP_DIR/pt/lyrebird" "$STAGE/pt-arm64/lyrebird" "$STAGE/pt-x86_64/lyrebird"
  cp "$STAGE/pt-arm64/pt_config.json" "$ROOT/$APP_DIR/pt/"
else
  scripts/fetch-pt.sh 16.0 "" "$ROOT/$APP_DIR/pt"
fi

# 3. Native messaging host manifests.
python3 packaging/hosts.py manifests "$INSTALLED" "$STAGE/manifests" >/dev/null
mkdir -p "$ROOT/Library/Application Support/Mozilla/NativeMessagingHosts"
cp "$STAGE/manifests/firefox.json" "$ROOT/Library/Application Support/Mozilla/NativeMessagingHosts/org.tortuga.helper.json"
if [ -f "$STAGE/manifests/chrome.json" ]; then
  for dir in "Library/Google/Chrome/NativeMessagingHosts" "Library/Application Support/Chromium/NativeMessagingHosts"; do
    mkdir -p "$ROOT/$dir"
    cp "$STAGE/manifests/chrome.json" "$ROOT/$dir/org.tortuga.helper.json"
  done
else
  echo "note: Chrome ID not pinned — the package registers the helper for Firefox only" >&2
fi
cp packaging/macos/uninstall.sh "$ROOT/$APP_DIR/uninstall.sh"
chmod 755 "$ROOT/$INSTALLED" "$ROOT/$APP_DIR/pt/lyrebird" "$ROOT/$APP_DIR/uninstall.sh"

# 4. Sign the programs (hardened runtime, as notarisation requires).
if [ -n "${DEVELOPER_ID_APP:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APP" "$ROOT/$INSTALLED" "$ROOT/$APP_DIR/pt/lyrebird"
fi

# 5. The package, built by hand rather than with pkgbuild: pkgbuild packs
# extended attributes (com.apple.provenance, which can't be removed) as ._
# files that would be installed too. The payload is a cpio archive (bsdcpio
# leaves xattrs out with COPYFILE_DISABLE) and both it and the bill of
# materials say root:admin, whoever built the package.
export COPYFILE_DISABLE=1
COMP="$STAGE/component"
mkdir -p "$COMP"
(cd "$ROOT" && find . | cpio -o --format odc -R 0:80 --quiet) | gzip -9 -c > "$COMP/Payload"
ME="$(id -u)/$(id -g)"
mkbom "$ROOT" "$STAGE/own.bom"
lsbom "$STAGE/own.bom" | sed -e "s#	$ME	#	0/80	#" -e "s#	$ME\$#	0/80#" > "$STAGE/bom.txt"
mkbom -i "$STAGE/bom.txt" "$COMP/Bom"
FILES="$(find "$ROOT" | wc -l | tr -d ' ')"
KBYTES="$(du -sk "$ROOT" | cut -f1)"
cat > "$COMP/PackageInfo" <<XML
<?xml version="1.0" encoding="utf-8"?>
<pkg-info format-version="2" identifier="org.tortuga.helper" version="$VERSION" install-location="/" auth="root">
  <payload numberOfFiles="$FILES" installKBytes="$KBYTES"/>
</pkg-info>
XML
pkgutil --flatten "$COMP" "$STAGE/component.pkg"
mkdir -p "$HELPER/dist"
OUT="$HELPER/dist/Tortuga-Helper-$VERSION-macos.pkg"
SIGN=()
[ -n "${DEVELOPER_ID_INSTALLER:-}" ] && SIGN=(--sign "$DEVELOPER_ID_INSTALLER")
# ${SIGN[@]+…}: macOS's bash 3.2 calls an empty array unbound under set -u.
productbuild --identifier org.tortuga.helper --version "$VERSION" --package "$STAGE/component.pkg" ${SIGN[@]+"${SIGN[@]}"} "$OUT" >/dev/null

# 6. Notarise and staple.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
fi
echo "$OUT"
```

`helper/packaging/macos/uninstall.sh`:

```sh
#!/bin/sh
# Remove the Tortuga helper installed by Tortuga-Helper-*-macos.pkg.
# Run with: sudo "/Library/Application Support/Tortuga/uninstall.sh"
# Each user's data (~/Library/Application Support/org.Tortuga.tortuga-helper)
# and downloads (~/Downloads/Tortuga) are left alone.
set -e
if [ "$(id -u)" != 0 ]; then
  echo "run with sudo" >&2
  exit 1
fi
rm -f "/Library/Application Support/Mozilla/NativeMessagingHosts/org.tortuga.helper.json"
rm -f "/Library/Google/Chrome/NativeMessagingHosts/org.tortuga.helper.json"
rm -f "/Library/Application Support/Chromium/NativeMessagingHosts/org.tortuga.helper.json"
rm -rf "/Library/Application Support/Tortuga"
pkgutil --forget org.tortuga.helper >/dev/null 2>&1 || true
echo "Tortuga helper removed."
```

Why the payload is built by hand: `pkgbuild` packed the files' extended attributes (`com.apple.provenance`, which can't be removed — `xattr -c` fails with "Permission denied") as `._*` files that would be installed beside the real ones; `COPYFILE_DISABLE` doesn't change that for `pkgbuild` but does for `cpio`. `-R 0:80` and the rewritten bill of materials make everything root:admin whoever builds it. On macOS's bash 3.2 an empty array is "unbound" under `set -u`, hence `${SIGN[@]+"${SIGN[@]}"}`.

- [ ] **Step 2: Build and inspect (no install: that needs admin rights)**

```bash
helper/packaging/macos/build-pkg.sh
P=helper/dist/Tortuga-Helper-0.1.0-macos.pkg
pkgutil --payload-files $P | grep -c '/\._'
pkgutil --payload-files $P | grep -vE '/\.$|^\.$'
X=helper/target/pkg-check && rm -rf $X && pkgutil --expand-full $P $X
lsbom "$(find $X -name Bom | head -1)" | grep -E 'tortuga-helper|lyrebird|org.tortuga'
python3 helper/packaging/smoke.py "$(find $X -path '*Tortuga/tortuga-helper' | head -1)"
```

Expected: `note: Chrome ID not pinned — the package registers the helper for Firefox only`; an 18 MB package; `0` `._` files; the payload lists exactly `Mozilla/NativeMessagingHosts/org.tortuga.helper.json`, `Tortuga/tortuga-helper`, `Tortuga/uninstall.sh`, `Tortuga/pt/pt_config.json`, `Tortuga/pt/lyrebird` (plus their folders); `lsbom` shows `100755 0/80` for `tortuga-helper` and `lyrebird`, `100644 0/80` for the manifest and for `pt_config.json` (it was `100600` before Task 1's fix); the smoke test prints hello with version 0.1.0.

- [ ] **Step 3: Commit**

```bash
git add helper/.gitignore helper/packaging/macos
git commit -m "packaging: macOS .pkg (signed and notarised when Developer ID is set)"
```

---

### Task 3: Debian package

**Files:**
- Create: `helper/packaging/linux/build-deb.sh`, `helper/packaging/linux/docker-build.sh`

- [ ] **Step 1: Scripts**

`helper/packaging/linux/build-deb.sh`:

```bash
#!/usr/bin/env bash
# Build tortuga-helper_<version>_<arch>.deb in helper/dist/, on Debian or
# Ubuntu with cargo, python3, curl and dpkg-deb (or in Docker: docker-build.sh).
#
# DEB_MAINTAINER ("Name <email>") is the package's Maintainer field; it
# defaults to this machine's git user.
#
# The package installs:
#   /usr/lib/tortuga/{tortuga-helper, pt/}
#   /usr/lib/mozilla/native-messaging-hosts/org.tortuga.helper.json
#   and, once the Chrome ID is pinned, the Chrome and Chromium manifests in
#   /etc/opt/chrome/native-messaging-hosts and /etc/chromium/native-messaging-hosts.
set -euo pipefail
HELPER="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$HELPER/tortuga-helper/Cargo.toml" | head -1)"
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64) PT=linux-x86_64 ;; arm64) PT=linux-aarch64 ;; *) echo "unsupported: $ARCH" >&2; exit 1 ;; esac
MAINTAINER="${DEB_MAINTAINER:-$(git config user.name 2>/dev/null) <$(git config user.email 2>/dev/null)>}"
case "$MAINTAINER" in " <>" | *"<>"*) echo "set DEB_MAINTAINER=\"Name <email>\"" >&2; exit 1 ;; esac
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/root"
LIB=usr/lib/tortuga
mkdir -p "$ROOT/$LIB/pt" "$ROOT/DEBIAN"

cd "$HELPER"
cargo build --release -p tortuga-helper
install -m 755 "${CARGO_TARGET_DIR:-target}/release/tortuga-helper" "$ROOT/$LIB/tortuga-helper"
scripts/fetch-pt.sh 16.0 "$PT" "$ROOT/$LIB/pt"
chmod 755 "$ROOT/$LIB/pt/lyrebird"

python3 packaging/hosts.py manifests "/$LIB/tortuga-helper" "$STAGE/manifests" >/dev/null
install -D -m 644 "$STAGE/manifests/firefox.json" "$ROOT/usr/lib/mozilla/native-messaging-hosts/org.tortuga.helper.json"
if [ -f "$STAGE/manifests/chrome.json" ]; then
  install -D -m 644 "$STAGE/manifests/chrome.json" "$ROOT/etc/opt/chrome/native-messaging-hosts/org.tortuga.helper.json"
  install -D -m 644 "$STAGE/manifests/chrome.json" "$ROOT/etc/chromium/native-messaging-hosts/org.tortuga.helper.json"
else
  echo "note: Chrome ID not pinned — the package registers the helper for Firefox only" >&2
fi

cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: tortuga-helper
Version: $VERSION
Architecture: $ARCH
Maintainer: $MAINTAINER
Depends: libc6 (>= 2.34), libgcc-s1, libssl3 | libssl3t64
Section: net
Priority: optional
Homepage: https://github.com/legenki/tortuga
Description: Tor and torrents for the Tortuga browser extension
 The native messaging host the Tortuga extension starts: Tor (Arti) with
 per-site circuits and bridges (Snowflake, obfs4, WebTunnel through the
 bundled lyrebird), and torrent downloads, which go directly, not through Tor.
CONTROL
mkdir -p "$HELPER/dist"
OUT="$HELPER/dist/tortuga-helper_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$ROOT" "$OUT" >/dev/null
echo "$OUT"
```

`helper/packaging/linux/docker-build.sh`:

```bash
#!/usr/bin/env bash
# Build the .deb in a rust:1-bookworm container for this machine's
# architecture (helper/dist/), then install it in a clean debian:bookworm-slim
# container and check, as an ordinary user, that the files are readable and
# the helper starts and answers hello. Run from a folder Docker can mount
# (Docker Desktop doesn't share /private/tmp).
# Usage: helper/packaging/linux/docker-build.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
MAINTAINER="${DEB_MAINTAINER:-$(git config user.name) <$(git config user.email)>}"
# A separate target dir: the host's helper/target holds macOS builds.
docker run --rm -v "$REPO:/src" -v tortuga-cargo:/usr/local/cargo/registry \
  -e CARGO_TARGET_DIR=/src/helper/target/linux -e DEB_MAINTAINER="$MAINTAINER" \
  -w /src rust:1-bookworm bash -c '
    apt-get update -qq && apt-get install -qq -y python3 >/dev/null && helper/packaging/linux/build-deb.sh'
DEB="$(ls -t "$REPO"/helper/dist/tortuga-helper_*.deb | head -1)"
echo "built $DEB"
# Install as root, run as an ordinary user: root can read anything, so only a
# user shows whether the installed files are readable by everyone.
docker run --rm -v "$DEB:/tmp/helper.deb:ro" -v "$REPO/helper:/helper:ro" debian:bookworm-slim bash -c '
  apt-get update -qq && apt-get install -qq -y /tmp/helper.deb python3 >/dev/null 2>&1 &&
  ls -l /usr/lib/tortuga /usr/lib/tortuga/pt /usr/lib/mozilla/native-messaging-hosts &&
  useradd -m tester &&
  su tester -c "cat /usr/lib/tortuga/pt/pt_config.json > /dev/null && echo pt_config.json is readable by users" &&
  su tester -c "python3 /helper/packaging/smoke.py /usr/lib/tortuga/tortuga-helper"'
```

- [ ] **Step 2: Build and install in Docker**

Docker Desktop can't mount folders under `/private/tmp`, so run from the checkout (under `/Users`). The first run pulls `rust:1-bookworm` (~1.5 GB) and compiles Arti and librqbit.

Run: `helper/packaging/linux/docker-build.sh`
Expected: `built …/helper/dist/tortuga-helper_0.1.0_arm64.deb` (amd64 on an Intel host); then, from the clean container, `ls -l` showing `/usr/lib/tortuga/tortuga-helper` and `pt/lyrebird` as `-rwxr-xr-x root root`, `pt/pt_config.json` and the Firefox manifest as `-rw-r--r-- root root`; `pt_config.json is readable by users`; and, run as the ordinary user `tester` (who has no XDG Downloads dir), `{"id": 1, "type": "hello", "payload": {"protocol": 1, "version": "0.1.0"}}`. While planning this test is what found both Task 1 bugs: before them it ended with `Error: no Downloads folder` and a `0600` pt_config.json.

- [ ] **Step 3: Commit**

```bash
git add helper/packaging/linux
git commit -m "packaging: Debian package, built and install-tested in Docker"
```

---

### Task 4: Windows zip and per-user installer

**Files:**
- Create: `helper/packaging/windows/build-zip.sh`, `helper/packaging/windows/install.ps1`, `helper/packaging/windows/uninstall.ps1`

- [ ] **Step 1: Scripts**

`helper/packaging/windows/build-zip.sh`:

```bash
#!/usr/bin/env bash
# Build Tortuga-Helper-<version>-windows-x86_64.zip in helper/dist/, in Git
# Bash on Windows with cargo, python and curl. The zip holds the helper,
# lyrebird.exe, ids.json and install.ps1 / uninstall.ps1; install.ps1 copies
# them to %LOCALAPPDATA%\Tortuga and registers the host (no admin needed).
set -euo pipefail
HELPER="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$HELPER/tortuga-helper/Cargo.toml" | head -1)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
NAME="Tortuga-Helper-$VERSION-windows-x86_64"
OUT_DIR="$STAGE/$NAME"
mkdir -p "$OUT_DIR/pt"
cd "$HELPER"
cargo build --release -p tortuga-helper
cp "${CARGO_TARGET_DIR:-target}/release/tortuga-helper.exe" "$OUT_DIR/"
scripts/fetch-pt.sh 16.0 windows-x86_64 "$OUT_DIR/pt"
python packaging/hosts.py ids > "$OUT_DIR/ids.json"
cp packaging/windows/install.ps1 packaging/windows/uninstall.ps1 "$OUT_DIR/"
mkdir -p "$HELPER/dist"
OUT="$HELPER/dist/$NAME.zip"
rm -f "$OUT"
(cd "$STAGE" && powershell -NoProfile -Command "Compress-Archive -Path '$NAME' -DestinationPath '$NAME.zip'")
mv "$STAGE/$NAME.zip" "$OUT"
echo "$OUT"
```

`helper/packaging/windows/install.ps1`:

```powershell
# Install the Tortuga helper for this Windows user (no admin rights needed):
# copy it to %LOCALAPPDATA%\Tortuga and register it as the org.tortuga.helper
# native messaging host for Firefox, and — when the Chrome ID is pinned — for
# Chrome and Chromium. Run from the unzipped folder:
#   powershell -ExecutionPolicy Bypass -File install.ps1
$ErrorActionPreference = 'Stop'
$from = $PSScriptRoot
$to = Join-Path $env:LOCALAPPDATA 'Tortuga'
New-Item -ItemType Directory -Force -Path (Join-Path $to 'pt') | Out-Null
Copy-Item (Join-Path $from 'tortuga-helper.exe') $to -Force
Copy-Item (Join-Path $from 'pt\*') (Join-Path $to 'pt') -Force
Copy-Item (Join-Path $from 'uninstall.ps1') $to -Force

$ids = Get-Content (Join-Path $from 'ids.json') -Raw | ConvertFrom-Json
$exe = Join-Path $to 'tortuga-helper.exe'

function Write-HostManifest($file, $allowedKey, $allowed) {
  $manifest = [ordered]@{
    name = 'org.tortuga.helper'
    description = 'Tortuga helper'
    path = $exe
    type = 'stdio'
  }
  $manifest[$allowedKey] = @($allowed)
  $path = Join-Path $to $file
  # UTF-8 without a byte-order mark: browsers read the manifest as JSON.
  [System.IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding $false))
  return $path
}

function Register-Host($registryKey, $manifestPath) {
  $key = "HKCU:\Software\$registryKey\NativeMessagingHosts\org.tortuga.helper"
  New-Item -Force -Path $key | Out-Null
  Set-Item -Path $key -Value $manifestPath
}

$firefox = Write-HostManifest 'firefox.json' 'allowed_extensions' $ids.firefox
Register-Host 'Mozilla' $firefox
Write-Output "Firefox: $firefox"
if ($ids.chrome) {
  $chrome = Write-HostManifest 'chrome.json' 'allowed_origins' "chrome-extension://$($ids.chrome)/"
  Register-Host 'Google\Chrome' $chrome
  Register-Host 'Chromium' $chrome
  Write-Output "Chrome and Chromium: $chrome"
} else {
  Write-Output 'Chrome ID not pinned: registered for Firefox only.'
}
Write-Output "Installed in $to"
```

`helper/packaging/windows/uninstall.ps1`:

```powershell
# Remove the Tortuga helper installed by install.ps1 for this Windows user.
# The helper's data (%APPDATA%\Tortuga\tortuga-helper) and downloads
# (Downloads\Tortuga) are left alone.
$ErrorActionPreference = 'SilentlyContinue'
foreach ($k in 'Mozilla', 'Google\Chrome', 'Chromium') {
  Remove-Item -Path "HKCU:\Software\$k\NativeMessagingHosts\org.tortuga.helper" -Force
}
$to = Join-Path $env:LOCALAPPDATA 'Tortuga'
foreach ($f in 'tortuga-helper.exe', 'firefox.json', 'chrome.json', 'uninstall.ps1') {
  Remove-Item -Path (Join-Path $to $f) -Force
}
Remove-Item -Path (Join-Path $to 'pt') -Recurse -Force
Write-Output 'Tortuga helper removed.'
```

- [ ] **Step 2: Parse-check here; the real run is in CI (Task 5)**

```bash
docker run --rm --platform linux/amd64 -v "$PWD/helper/packaging/windows:/w:ro" mcr.microsoft.com/powershell:latest pwsh -NoProfile -Command '
foreach ($f in "/w/install.ps1", "/w/uninstall.ps1") {
  $tokens = $null; $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors) | Out-Null
  "{0}: {1} parse errors" -f $f, $errors.Count
}'
```

Expected: `0 parse errors` for both. (The image is amd64-only: `--platform linux/amd64` runs it under emulation on Apple Silicon.)

- [ ] **Step 3: Commit**

```bash
git add helper/packaging/windows
git commit -m "packaging: Windows zip with a per-user installer"
```

---

### Task 5: CI workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Workflow**

`.github/workflows/release.yml`:

```yaml
# Build, test and package the helper on every platform; on a v* tag, also
# build the extension packages and publish everything as a GitHub release.
#
# macOS signing and notarisation run only when these secrets exist:
#   APPLE_CERTIFICATES_P12   base64 of a .p12 with both Developer ID certificates
#   APPLE_CERTIFICATES_PASSWORD, APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#   DEVELOPER_ID_APP, DEVELOPER_ID_INSTALLER   (the certificate names)
# Without them the .pkg is unsigned (fine for testing, blocked by Gatekeeper).
name: release

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  macos:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: rustup target add aarch64-apple-darwin x86_64-apple-darwin
      - name: Unit tests
        run: |
          (cd helper && cargo test -p tortuga-helper)
          python3 -m unittest discover -s helper/packaging
      - name: Signing keychain
        env:
          P12: ${{ secrets.APPLE_CERTIFICATES_P12 }}
          P12_PASSWORD: ${{ secrets.APPLE_CERTIFICATES_PASSWORD }}
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
          APPLE_APP_PASSWORD: ${{ secrets.APPLE_APP_PASSWORD }}
          DEVELOPER_ID_APP: ${{ secrets.DEVELOPER_ID_APP }}
          DEVELOPER_ID_INSTALLER: ${{ secrets.DEVELOPER_ID_INSTALLER }}
        if: ${{ env.P12 != '' }}
        run: |
          KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
          security create-keychain -p ci "$KEYCHAIN"
          security set-keychain-settings -lut 3600 "$KEYCHAIN"
          security unlock-keychain -p ci "$KEYCHAIN"
          echo "$P12" | base64 --decode > "$RUNNER_TEMP/certs.p12"
          security import "$RUNNER_TEMP/certs.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/productsign -T /usr/bin/productbuild
          security set-key-partition-list -S apple-tool:,apple: -s -k ci "$KEYCHAIN"
          # Put the signing keychain first in the search list, keeping the others.
          security list-keychains -d user | tr -d '"' | xargs security list-keychains -d user -s "$KEYCHAIN"
          xcrun notarytool store-credentials tortuga --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --keychain "$KEYCHAIN"
          {
            echo "DEVELOPER_ID_APP=$DEVELOPER_ID_APP"
            echo "DEVELOPER_ID_INSTALLER=$DEVELOPER_ID_INSTALLER"
            echo "NOTARY_PROFILE=tortuga"
          } >> "$GITHUB_ENV"
      - name: Package
        run: helper/packaging/macos/build-pkg.sh --universal
      - name: Smoke test the packaged helper
        run: |
          pkgutil --expand-full helper/dist/*.pkg "$RUNNER_TEMP/pkg"
          BIN="$(find "$RUNNER_TEMP/pkg" -path '*Tortuga/tortuga-helper' | head -1)"
          lipo -archs "$BIN"
          python3 helper/packaging/smoke.py "$BIN"
      - uses: actions/upload-artifact@v4
        with:
          name: helper-macos
          path: helper/dist/*.pkg

  linux:
    strategy:
      matrix:
        runner: [ubuntu-24.04, ubuntu-24.04-arm]
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - name: Unit tests
        run: |
          (cd helper && cargo test -p tortuga-helper)
          python3 -m unittest discover -s helper/packaging
      - name: Package
        env:
          DEB_MAINTAINER: ${{ vars.DEB_MAINTAINER }}
        run: helper/packaging/linux/build-deb.sh
      - name: Install and smoke test
        run: |
          sudo apt-get install -y ./helper/dist/tortuga-helper_*.deb
          cat /usr/lib/mozilla/native-messaging-hosts/org.tortuga.helper.json
          python3 helper/packaging/smoke.py /usr/lib/tortuga/tortuga-helper
      - uses: actions/upload-artifact@v4
        with:
          name: helper-${{ matrix.runner }}
          path: helper/dist/*.deb

  windows:
    runs-on: windows-latest
    defaults:
      run:
        shell: bash
    steps:
      - uses: actions/checkout@v4
      - name: Unit tests
        run: |
          (cd helper && cargo test -p tortuga-helper)
          python -m unittest discover -s helper/packaging
      - name: Package
        run: helper/packaging/windows/build-zip.sh
      - name: Install and smoke test
        shell: pwsh
        run: |
          $zip = Get-ChildItem helper/dist/*.zip | Select-Object -First 1
          Expand-Archive $zip.FullName -DestinationPath $env:RUNNER_TEMP
          & (Get-ChildItem "$env:RUNNER_TEMP/Tortuga-Helper-*/install.ps1").FullName
          (Get-Item 'HKCU:\Software\Mozilla\NativeMessagingHosts\org.tortuga.helper').GetValue('')
          python helper/packaging/smoke.py "$env:LOCALAPPDATA\Tortuga\tortuga-helper.exe"
          if ($LASTEXITCODE -ne 0) { exit 1 }
      - uses: actions/upload-artifact@v4
        with:
          name: helper-windows
          path: helper/dist/*.zip

  extension:
    runs-on: ubuntu-24.04
    defaults:
      run:
        working-directory: extension
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - run: npm ci
      - run: npm test
      - run: npm run package
      - run: npm run package:firefox
      - run: npm run lint:firefox
      - uses: actions/upload-artifact@v4
        with:
          name: extension
          path: 'extension/tortuga-*.zip'

  release:
    if: startsWith(github.ref, 'refs/tags/v')
    needs: [macos, linux, windows, extension]
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: artifacts
          merge-multiple: true
      - env:
          GH_TOKEN: ${{ github.token }}
        run: gh release create "$GITHUB_REF_NAME" artifacts/* --repo "$GITHUB_REPOSITORY" --title "Tortuga $GITHUB_REF_NAME" --generate-notes
```

- [ ] **Step 2: Lint**

Run: `docker run --rm -v "$PWD:/repo:ro" -w /repo rhysd/actionlint:latest -no-color`
Expected: no output. (While planning it caught `${{ … }}` inside a one-line `with: { … }` — not valid YAML — and an unquoted `$( … )`; both fixed in the listing.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: build, install-test and release the helper on every platform"
```

- [ ] **Step 4: First CI run — ask before pushing**

CI only runs on GitHub. Pushing is the user's decision; with their go-ahead: push the branch, open a PR, and read the run. Expected: all jobs green — `macos` (universal: `lipo -archs` prints `x86_64 arm64`; unsigned unless the secrets exist), both `linux` jobs, `windows` (install.ps1 registers `HKCU\Software\Mozilla\NativeMessagingHosts\org.tortuga.helper`, smoke test passes), `extension`. Fix anything red before Task 6's tag.

---

### Task 6: Extension packages and dev host

**Files:**
- Create: `extension/scripts/package.mjs`, `extension/BUILD.md`
- Modify: `extension/package.json`, `extension/scripts/register-dev-host.sh`

- [ ] **Step 1: Files**

`extension/scripts/package.mjs`:

```js
// Store packages, written next to package.json:
//   node scripts/package.mjs chrome   dist/ → tortuga-chrome-<version>.zip
//   node scripts/package.mjs firefox  dist-firefox/ → tortuga-firefox-<version>.zip
//                                     + tortuga-firefox-<version>-source.zip
//                                       (extension/ at HEAD, for AMO review)
// The Chrome Web Store sets the extension's key itself, so the store zip
// leaves out manifest.json's "key" (kept for unpacked builds: it pins the id).
import { execFileSync } from 'node:child_process';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const { version } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const which = process.argv[2];

function zipDir(dir, out) {
  rmSync(out, { force: true });
  execFileSync('zip', ['-qrX', out, '.'], { cwd: dir });
  console.log(out);
}

if (which === 'chrome') {
  const stage = mkdtempSync(join(tmpdir(), 'tortuga-chrome-'));
  cpSync(join(root, 'dist'), stage, { recursive: true });
  const manifest = JSON.parse(readFileSync(join(stage, 'manifest.json'), 'utf8'));
  delete manifest.key;
  writeFileSync(join(stage, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  zipDir(stage, join(root, `tortuga-chrome-${version}.zip`));
  rmSync(stage, { recursive: true, force: true });
} else if (which === 'firefox') {
  zipDir(join(root, 'dist-firefox'), join(root, `tortuga-firefox-${version}.zip`));
  const source = join(root, `tortuga-firefox-${version}-source.zip`);
  // From the repository's top: run in a subfolder, git archive only takes
  // paths under it.
  const top = execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd: root, encoding: 'utf8' }).trim();
  execFileSync('git', ['archive', '--format=zip', '-o', source, 'HEAD', 'extension'], { cwd: top });
  console.log(source);
} else {
  console.error('usage: node scripts/package.mjs chrome|firefox');
  process.exit(2);
}
```

`extension/package.json`:

```json
{
  "name": "tortuga-extension",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "npm run typecheck && npm run build:background && npm run build:theme && npm run build:content && npm run build:popup && npm run build:options && npm run build:confirm",
    "build:background": "vite build --config vite.config.background.ts",
    "build:theme": "vite build --config vite.config.theme.ts",
    "build:content": "vite build --config vite.config.content.ts",
    "build:popup": "vite build --config vite.config.popup.ts",
    "build:options": "vite build --config vite.config.options.ts",
    "build:confirm": "vite build --config vite.config.confirm.ts",
    "build:firefox": "TARGET=firefox npm run build",
    "package": "npm run build && node scripts/package.mjs chrome",
    "package:firefox": "npm run build:firefox && node scripts/package.mjs firefox",
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

`extension/BUILD.md`:

```markdown
# Building the Tortuga extension

The extension is TypeScript bundled with [Vite](https://vitejs.dev) (open
source). One code base builds both browsers; `TARGET=firefox` selects the
Firefox manifest and code paths at build time.

## Requirements

- Node.js 20 or later and npm (released builds: Node 26.13.0, npm 11.20.0)
- `zip` and `git` for the packaging scripts

## Firefox (addons.mozilla.org)

From `tortuga-firefox-<version>-source.zip` (the `extension/` folder of the
repository at the released commit):

```sh
cd extension
npm ci
npm run build:firefox
```

`dist-firefox/` is the extension: the same files as `tortuga-firefox-<version>.zip`.
`npm run lint:firefox` runs `web-ext lint`.

## Chrome (Chrome Web Store)

```sh
npm ci
npm run package    # → tortuga-chrome-<version>.zip (dist/ without manifest "key")
```

## What ends up in the package

| Output | Built from |
|---|---|
| `background.js` | `src/background/` |
| `links.js` | `src/content/links.ts` (catches clicks on torrent links) |
| `popup.html/js/css` | `src/popup/`, `src/styles/` |
| `options.html/js/css` | `src/options/` |
| `confirm.html/js/css` | `src/confirm/` |
| `theme.js` | `src/lib/theme-boot.ts` |
| `fonts/` | `public/fonts/` (Twemoji country flags, CC-BY 4.0) |

Third-party code bundled: `tldts` (public suffix list, MIT).

## The helper

The extension does nothing without the Tortuga helper, a separate program
(`helper/` in the repository, Rust) that the browser starts through native
messaging. It is not part of the extension package; it ships as installers
on the GitHub releases page.
```

`extension/scripts/register-dev-host.sh`:

```bash
#!/usr/bin/env bash
# Install the helper's release build as the org.tortuga.helper native host for
# development: Firefox always; Chrome and Chromium when the Chrome ID is pinned
# (helper/packaging/hosts.py set-chrome-key) or given as an argument (the
# unpacked extension's id from chrome://extensions). Run it again after every
# helper build.
#
# The binary and its transports are copied out of the repository because macOS
# doesn't let browsers run programs from ~/Documents, ~/Desktop or ~/Downloads.
#
# Usage: extension/scripts/register-dev-host.sh [CHROME_EXTENSION_ID]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/helper/target/release/tortuga-helper"
PT="$ROOT/helper/resources/pt"
[ -x "$BIN" ] || { echo "build the helper first: (cd helper && cargo build --release -p tortuga-helper)" >&2; exit 1; }
[ -f "$PT/lyrebird" ] || { echo "fetch transports first: helper/scripts/fetch-pt.sh" >&2; exit 1; }
case "$(uname -s)" in
  Darwin) DEV="$HOME/Library/Application Support/Tortuga/dev"
          FF="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
          CR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
          CM="$HOME/Library/Application Support/Chromium/NativeMessagingHosts" ;;
  Linux)  DEV="$HOME/.local/share/tortuga/dev"
          FF="$HOME/.mozilla/native-messaging-hosts"
          CR="$HOME/.config/google-chrome/NativeMessagingHosts"
          CM="$HOME/.config/chromium/NativeMessagingHosts" ;;
  *) echo "unsupported OS" >&2; exit 1 ;;
esac

# The helper looks for pt/ next to itself.
mkdir -p "$DEV/pt"
cp "$BIN" "$DEV/tortuga-helper"
cp "$PT/lyrebird" "$PT/pt_config.json" "$DEV/pt/"
echo "Helper:   $DEV/tortuga-helper"

MANIFESTS="$(mktemp -d)"
trap 'rm -rf "$MANIFESTS"' EXIT
python3 "$ROOT/helper/packaging/hosts.py" manifests "$DEV/tortuga-helper" "$MANIFESTS" >/dev/null 2>&1
mkdir -p "$FF"
cp "$MANIFESTS/firefox.json" "$FF/org.tortuga.helper.json"
echo "Firefox:  $FF/org.tortuga.helper.json"

if [ ! -f "$MANIFESTS/chrome.json" ] && [ $# -ge 1 ]; then
  # Not pinned: register for the unpacked extension's id instead.
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m.pop("allowed_extensions"); m["allowed_origins"]=["chrome-extension://%s/" % sys.argv[2]]; open(sys.argv[3],"w").write(json.dumps(m, indent=2)+"\n")' \
    "$MANIFESTS/firefox.json" "$1" "$MANIFESTS/chrome.json"
fi
if [ -f "$MANIFESTS/chrome.json" ]; then
  for dir in "$CR" "$CM"; do
    mkdir -p "$dir"
    cp "$MANIFESTS/chrome.json" "$dir/org.tortuga.helper.json"
  done
  echo "Chrome:   $CR/org.tortuga.helper.json (and Chromium)"
fi
```

- [ ] **Step 2: Commit, then build the packages**

The source zip is `git archive` of `HEAD`, so commit first:

```bash
git add extension && git commit -m "extension: store packages, AMO source zip and build notes"
cd extension && npm run package && npm run package:firefox
unzip -p tortuga-chrome-0.1.0.zip manifest.json | grep -c '"key"'
unzip -l tortuga-firefox-0.1.0-source.zip | tail -1
```

Expected: `tortuga-chrome-0.1.0.zip`, `tortuga-firefox-0.1.0.zip`, `tortuga-firefox-0.1.0-source.zip`; `0` (no key in the store zip); about 86 files in the source zip.

- [ ] **Step 3: The source zip rebuilds the Firefox package byte for byte**

```bash
X=$(mktemp -d "$PWD/../helper/target/srccheck.XXXX") && unzip -q tortuga-firefox-0.1.0-source.zip -d $X
(cd $X/extension && npm ci && npm run build:firefox) && mkdir $X/store && unzip -q tortuga-firefox-0.1.0.zip -d $X/store
diff -r $X/store $X/extension/dist-firefox && echo identical; rm -rf $X
```

Expected: `identical`. (While planning, `git archive` run from `extension/` produced an empty zip: in a subfolder it only takes paths under it — `package.mjs` runs it from the repository's top.)

- [ ] **Step 4: Dev host still works**

Run: `FAKE=$(mktemp -d "$PWD/../helper/target/fakehome.XXXX") && HOME=$FAKE scripts/register-dev-host.sh abcdefghijklmnopabcdefghijklmnop && python3 ../helper/packaging/smoke.py "$FAKE/Library/Application Support/Tortuga/dev/tortuga-helper"; rm -rf $FAKE`
Expected: Helper / Firefox / Chrome lines (Chrome from the argument while the ID isn't pinned), then hello 0.1.0. Then run the three live checks (`scripts/live-check/run.sh`, `… downloads`, `… bridges`): `ALL PASSED`.

---

### Task 7: Release notes and spec

**Files:**
- Create: `RELEASE.md`
- Modify: `docs/superpowers/specs/2026-11-05-tortuga-design.md`

- [ ] **Step 1: RELEASE.md**

`RELEASE.md`:

```markdown
# Releasing Tortuga

A release is the helper's installers (GitHub release) and the extension
(Chrome Web Store, addons.mozilla.org). CI (`.github/workflows/release.yml`)
builds and tests everything on each push; a `v*` tag also publishes the
GitHub release.

## Once: pin the Chrome extension ID

Installers register the helper for one Chrome extension ID, so it must be
fixed before the first release:

1. Generate a key and keep it out of the repository (and backed up):
   `openssl genrsa -out ~/tortuga-chrome-key.pem 2048`
2. `python3 helper/packaging/hosts.py set-chrome-key ~/tortuga-chrome-key.pem`
   writes its public key into `extension/manifest.json` and prints the ID.
3. First upload to the Chrome Web Store: put a copy of the key, named
   `key.pem`, at the top of `tortuga-chrome-<version>.zip`, so the store keeps
   that ID. Check the ID in the developer dashboard against
   `python3 helper/packaging/hosts.py chrome-id`. If they differ, copy the
   dashboard's public key into `manifest.json` "key" instead and rebuild the
   installers.

## Once: macOS signing (optional, needed for Gatekeeper)

Add the secrets listed at the top of the workflow (a .p12 with the Developer
ID Application and Developer ID Installer certificates, its password, the
certificate names, Apple ID, team ID and an app-specific password). Without
them the .pkg is unsigned. Locally: `DEVELOPER_ID_APP=… DEVELOPER_ID_INSTALLER=…
NOTARY_PROFILE=… helper/packaging/macos/build-pkg.sh --universal`.

Set the repository variable `DEB_MAINTAINER` ("Name <email>") for the .deb.

## Each release

1. Bump the version in `helper/tortuga-helper/Cargo.toml`,
   `extension/package.json`, `extension/manifest.json`,
   `extension/manifest.firefox.json`; commit.
2. Tag and push: `git tag v<version> && git push origin main v<version>`.
3. CI publishes the release with `Tortuga-Helper-<v>-macos.pkg`,
   `tortuga-helper_<v>_amd64.deb`, `tortuga-helper_<v>_arm64.deb`,
   `Tortuga-Helper-<v>-windows-x86_64.zip` and the extension zips.
4. Upload `tortuga-chrome-<v>.zip` to the Chrome Web Store and
   `tortuga-firefox-<v>.zip` with `tortuga-firefox-<v>-source.zip` to AMO
   (reviewers build it with `extension/BUILD.md`).

## Checks before tagging

```sh
(cd helper && cargo test -p tortuga-helper)
python3 -m unittest discover -s helper/packaging
(cd extension && npm test && npm run lint:firefox)
extension/scripts/live-check/run.sh && extension/scripts/live-check/run.sh downloads && extension/scripts/live-check/run.sh bridges
```

Local packages: `helper/packaging/macos/build-pkg.sh` (this Mac's arch,
unsigned), `helper/packaging/linux/docker-build.sh` (a .deb built and
installed in Docker; run it from a folder Docker can mount, e.g. under
/Users).
```

- [ ] **Step 2: Spec**

Replace the *Release* section of the spec with:

```markdown
## Release

- Extension: Chrome Web Store (`tortuga-chrome-<v>.zip`, without the
  manifest's "key") and AMO (`tortuga-firefox-<v>.zip` plus a source zip that
  rebuilds it byte for byte).
- Helper, from the GitHub release: macOS `.pkg` (universal; signed and
  notarised when the Developer ID secrets exist) installing to
  `/Library/Application Support/Tortuga/`; Debian `.deb` for amd64 and arm64
  installing to `/usr/lib/tortuga/`; Windows zip with `install.ps1`, a
  per-user install to `%LOCALAPPDATA%\Tortuga` registered in `HKCU` (no admin
  rights). No AppImage: a native host must be registered in fixed places,
  which an AppImage doesn't do. Each installer bundles `lyrebird` and
  `pt_config.json` from Tor Expert Bundle 16.0 for its platform.
- Native host manifests come from `helper/packaging/hosts.py`. The Chrome
  extension ID is pinned with a key generated once (`hosts.py
  set-chrome-key`); until then installers register Firefox only.
- `RELEASE.md` has the steps; CI (`.github/workflows/release.yml`) builds,
  installs and smoke-tests every package and publishes the release on a
  `v*` tag.
```

- [ ] **Step 3: Commit**

```bash
git add RELEASE.md docs/superpowers/specs/2026-11-05-tortuga-design.md
git commit -m "docs: release steps; spec follows the installers"
```
