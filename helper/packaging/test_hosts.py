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
