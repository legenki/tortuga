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
