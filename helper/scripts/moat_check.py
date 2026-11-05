#!/usr/bin/env python3
"""End-to-end check of bridges.fetch, acting as the browser.

Usage: moat_check.py HELPER_BINARY

1. obfs4 lines straight from bridges.torproject.org;
2. WebTunnel: lines, or the "none for this network" error;
3. with the direct way switched off (TORTUGA_MOAT_NO_DIRECT): an error that
   points at Snowflake, then the same request through Tor on Snowflake;
4. Tor restarted on the fetched obfs4 lines, and a page fetched through it.
Set TORTUGA_PT_DIR and a throwaway TORTUGA_DATA_DIR. Exits non-zero on failure.
"""
import json, os, queue, struct, subprocess, sys, threading, time

T0 = time.monotonic()

def log(*a):
    print(f"[{time.monotonic() - T0:6.1f}s]", *a, flush=True)

class Helper:
    def __init__(self, binary, env):
        self.p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        self.q = queue.Queue()
        self.next = 1
        self.circuits = []
        threading.Thread(target=self.read, daemon=True).start()
        self.ask("hello", {"protocol": 1}, 10)

    def read(self):
        while True:
            h = self.p.stdout.read(4)
            if len(h) < 4:
                self.q.put(None)
                return
            m = json.loads(self.p.stdout.read(struct.unpack("=I", h)[0]))
            if m.get("type") == "circuit":
                self.circuits.append(m["payload"])
            elif "id" in m:
                self.q.put(m)

    def ask(self, type, payload, timeout):
        id = self.next
        self.next += 1
        msg = {"id": id, "type": type} | ({"payload": payload} if payload is not None else {})
        b = json.dumps(msg).encode()
        self.p.stdin.write(struct.pack("=I", len(b)) + b)
        self.p.stdin.flush()
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                m = self.q.get(timeout=max(0.1, end - time.monotonic()))
            except queue.Empty:
                break
            if m is None:
                sys.exit("helper exited")
            if m.get("id") == id:
                return m
        sys.exit(f"no answer to {type}")

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=10)

def curl(port):
    out = subprocess.run(["curl", "-s", "--max-time", "60", "-x", f"socks5h://check:x@127.0.0.1:{port}",
                          "https://check.torproject.org/api/ip"], capture_output=True, text=True)
    return out.stdout.strip()

def main():
    binary = sys.argv[1]
    env = dict(os.environ)

    h = Helper(binary, env)
    r = h.ask("bridges.fetch", {"kind": "obfs4"}, 60)
    log("1. obfs4 direct:", r["type"], json.dumps(r.get("payload"))[:200])
    if r["type"] != "bridges.lines" or not r["payload"]["lines"] or r["payload"]["viaTor"]:
        sys.exit("no obfs4 lines")
    obfs4 = r["payload"]["lines"]
    r = h.ask("bridges.fetch", {"kind": "webtunnel"}, 60)
    log("2. webtunnel:", r["type"], json.dumps(r.get("payload"))[:200])
    if r["type"] == "error" and not r["payload"]["message"].startswith("bridges.torproject.org has no webtunnel bridges"):
        sys.exit("unexpected webtunnel error")
    h.close()

    h = Helper(binary, env | {"TORTUGA_MOAT_NO_DIRECT": "1"})
    r = h.ask("bridges.fetch", {"kind": "obfs4"}, 30)
    log("3a. no direct, Tor off:", r["type"], r["payload"].get("message", "")[:160])
    if r["type"] != "error" or "Snowflake" not in r["payload"]["message"]:
        sys.exit("expected the Snowflake hint")
    r = h.ask("tor.start", {"bridge": {"kind": "snowflake"}}, 300)
    if r["type"] != "tor.ready":
        sys.exit(f"Snowflake didn't start: {r}")
    log("3b. Tor on Snowflake, port", r["payload"]["socksPort"])
    r = h.ask("bridges.fetch", {"kind": "obfs4"}, 120)
    log("3c. obfs4 through Tor:", r["type"], json.dumps(r.get("payload"))[:200])
    if r["type"] != "bridges.lines" or not r["payload"]["viaTor"]:
        sys.exit("no lines through Tor")

    h.close()

    # A fresh process and data dir: on a running client a bridge change reports
    # ready before the new bridges are proven (see the spec), and some built-in
    # bridges don't answer from every network, so give Arti time to try them.
    h = Helper(binary, env | {"TORTUGA_DATA_DIR": env["TORTUGA_DATA_DIR"] + "-obfs4"})
    r = h.ask("tor.start", {"bridge": {"kind": "obfs4", "lines": [f"Bridge {l}" for l in obfs4]}}, 300)
    if r["type"] != "tor.ready":
        sys.exit(f"obfs4 didn't start: {r}")
    port = r["payload"]["socksPort"]
    answer = curl(port) or curl(port)
    log("4. Tor on the fetched obfs4 lines, port", port, "->", answer)
    time.sleep(1)
    last = h.circuits[-1] if h.circuits else None
    log("   circuit:", json.dumps(last)[:220] if last else None)
    if not last or last["bridge"] != "obfs4" or last["hops"][0]["role"] != "bridge":
        sys.exit("not through an obfs4 bridge")
    h.close()
    log("PASS")

main()
