#!/usr/bin/env python3
"""End-to-end check of tortuga-helper, acting as the browser.

Usage: nm_client.py HELPER_BINARY KIND [KIND...]   (KIND: none | snowflake)

Starts the helper, says hello, starts Tor, fetches check.torproject.org through
the SOCKS port as two sites, renews one site's circuit, and stops Tor. Prints
every message with the seconds since start. Exits non-zero on any failure.
"""
import json, queue, struct, subprocess, sys, threading, time

T0 = time.monotonic()

def log(*a):
    print(f"[{time.monotonic() - T0:6.1f}s]", *a, flush=True)

def send(p, msg):
    b = json.dumps(msg).encode()
    p.stdin.write(struct.pack("=I", len(b)) + b)
    p.stdin.flush()

def reader(p, q):
    while True:
        h = p.stdout.read(4)
        if len(h) < 4:
            q.put(None)
            return
        q.put(json.loads(p.stdout.read(struct.unpack("=I", h)[0])))

def wait_for(q, pred, timeout, seen):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            m = q.get(timeout=max(0.1, end - time.monotonic()))
        except queue.Empty:
            break
        if m is None:
            sys.exit("helper exited")
        log(json.dumps(m))
        seen.append(m)
        if pred(m):
            return m
    sys.exit("timed out")

def fetch(port, site):
    out = subprocess.run(
        ["curl", "-s", "--max-time", "60", "-x", f"socks5h://{site}:x@127.0.0.1:{port}",
         "https://check.torproject.org/api/ip"],
        capture_output=True, text=True)
    log(f"curl as {site}:", out.stdout.strip() or out.stderr.strip())
    if '"IsTor":true' not in out.stdout:
        sys.exit(f"{site}: not through Tor")

def main():
    helper, kinds = sys.argv[1], sys.argv[2:]
    p = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    q, seen = queue.Queue(), []
    threading.Thread(target=reader, args=(p, q), daemon=True).start()

    send(p, {"id": 1, "type": "hello", "payload": {"protocol": 1}})
    wait_for(q, lambda m: m.get("id") == 1 and m["type"] == "hello", 10, seen)

    # Each kind runs in the same helper process: the second start reconfigures
    # the client that the first one created.
    for n, kind in enumerate(kinds):
        base = 10 * (n + 1)
        log(f"--- bridge: {kind}")
        send(p, {"id": base, "type": "tor.start", "payload": {"bridge": {"kind": kind}}})
        ready = wait_for(q, lambda m: m.get("id") == base and m["type"] in ("tor.ready", "error"), 300, seen)
        if ready["type"] == "error":
            sys.exit("tor.start failed")
        port = ready["payload"]["socksPort"]
        log(f"Tor ready on port {port}")

        for site in ("site-a.test", "site-b.test"):
            fetch(port, site)
        time.sleep(1)
        circuits = {}
        while not q.empty():
            m = q.get()
            log(json.dumps(m))
            if m and m["type"] == "circuit":
                circuits[m["payload"]["site"]] = m["payload"]
        if set(circuits) != {"site-a.test", "site-b.test"}:
            sys.exit(f"expected circuit events for both sites, got {sorted(circuits)}")
        if circuits["site-a.test"]["hops"] == circuits["site-b.test"]["hops"]:
            sys.exit("both sites share a circuit")
        want_bridge = None if kind == "none" else kind
        if any(c["bridge"] != want_bridge for c in circuits.values()):
            sys.exit(f"circuits do not go through bridge {want_bridge}")

        send(p, {"id": base + 1, "type": "tor.newCircuit", "payload": {"site": "site-a.test"}})
        wait_for(q, lambda m: m.get("id") == base + 1, 10, seen)
        fetch(port, "site-a.test")
        renewed = wait_for(q, lambda m: m["type"] == "circuit" and m["payload"]["site"] == "site-a.test", 30, seen)
        if renewed["payload"]["hops"] == circuits["site-a.test"]["hops"]:
            sys.exit("new circuit has the same path")

        send(p, {"id": base + 2, "type": "tor.stop"})
        wait_for(q, lambda m: m.get("id") == base + 2 and m["type"] == "ok", 10, seen)
    p.stdin.close()
    p.wait(timeout=10)
    log("PASS")

main()
