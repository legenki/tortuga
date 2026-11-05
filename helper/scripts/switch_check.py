#!/usr/bin/env python3
"""End-to-end check of a bridge change on a running helper.

Usage: switch_check.py HELPER_BINARY

Starts Tor on Snowflake, gets obfs4 lines with bridges.fetch, switches the
same helper to them, and requires that right after tor.ready a page loads
(one retry allowed) through one of the new bridges (a change used to report ready before the new
bridges had answered). Set TORTUGA_PT_DIR and TORTUGA_DATA_DIR (not under a
world-writable directory). Exits non-zero on failure.
"""
import json, queue, struct, subprocess, sys, threading, time

T0 = time.monotonic()

def log(*a):
    print(f"[{time.monotonic() - T0:6.1f}s]", *a, flush=True)

p = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
q = queue.Queue()
circuits = []
status_seen = [None]

def read():
    while True:
        h = p.stdout.read(4)
        if len(h) < 4:
            q.put(None)
            return
        m = json.loads(p.stdout.read(struct.unpack("=I", h)[0]))
        if m.get("type") == "circuit":
            circuits.append(m["payload"])
        elif m.get("type") == "tor.status":
            st = m["payload"]
            key = (st["phase"], st["percent"] // 10, st["blocked"])
            if key != status_seen[0]:
                status_seen[0] = key
                log("   status:", st["phase"], f'{st["percent"]}%', st["blocked"] or "")
        elif "id" in m:
            q.put(m)

threading.Thread(target=read, daemon=True).start()

def ask(id, type, payload, timeout):
    b = json.dumps({"id": id, "type": type, "payload": payload}).encode()
    p.stdin.write(struct.pack("=I", len(b)) + b)
    p.stdin.flush()
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            m = q.get(timeout=1)
        except queue.Empty:
            continue
        if m is None:
            sys.exit("helper exited")
        if m.get("id") == id:
            return m
    sys.exit(f"no answer to {type}")

def page(port, site):
    r = subprocess.run(["curl", "-s", "--max-time", "45", "-x", f"socks5h://{site}:x@127.0.0.1:{port}",
                        "https://check.torproject.org/api/ip"], capture_output=True, text=True)
    return r.stdout.strip()

ask(1, "hello", {"protocol": 1}, 10)
# A cold Snowflake start took up to ~250 s in testing ("connection seems to be filtered").
r = ask(2, "tor.start", {"bridge": {"kind": "snowflake"}}, 600)
if r["type"] != "tor.ready":
    sys.exit(f"Snowflake didn't start: {r}")
log("Tor on Snowflake")
r = ask(3, "bridges.fetch", {"kind": "obfs4"}, 120)
if r["type"] != "bridges.lines":
    sys.exit(f"no obfs4 lines: {r}")
lines = ["Bridge " + l for l in r["payload"]["lines"]]
new = {l.split()[2].rsplit(":", 1)[0].strip("[]") for l in lines}
log(f"{len(lines)} obfs4 lines:", ", ".join(sorted(new)))

started = time.monotonic()
r = ask(4, "tor.start", {"bridge": {"kind": "obfs4", "lines": lines}}, 420)
if r["type"] != "tor.ready":
    sys.exit(f"switch failed: {r}")
log(f"switched to obfs4, ready after {time.monotonic() - started:.1f}s")
# Ready means a circuit ran through a new bridge. A further new circuit can
# still try a dead bridge from the same set first, so allow one retry; before
# the fix, pages failed for minutes after ready.
port = r["payload"]["socksPort"]
for attempt in (1, 2):
    t = time.monotonic()
    answer = page(port, "after-switch")
    log(f"page attempt {attempt} right after ready ({time.monotonic() - t:.1f}s):", answer or "(failed)")
    if '"IsTor":true' in answer:
        break
else:
    sys.exit("the page didn't load after ready")
time.sleep(1)
first = next((c["hops"][0] for c in reversed(circuits) if c["site"] == "after-switch"), None)
log("first hop:", json.dumps(first))
if not first or first["role"] != "bridge" or first["addr"] not in new:
    sys.exit("not through one of the new bridges")
p.stdin.close()
p.wait(timeout=10)
log("PASS")
