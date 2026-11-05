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
