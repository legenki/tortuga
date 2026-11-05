#!/usr/bin/env python3
"""End-to-end check of the helper's torrents, acting as the browser.

Usage: torrent_check.py HELPER_BINARY MAGNET

Inspects the magnet (name, size), adds it, watches progress for 15 s, pauses,
resumes, then removes it with its files. Set TORTUGA_DOWNLOADS and
TORTUGA_DATA_DIR to throwaway folders. Exits non-zero on any failure.
"""
import json, os, queue, struct, subprocess, sys, threading, time

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

def reply(q, id, timeout):
    """The reply to request `id`; progress events on the way are kept in `rows`."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            m = q.get(timeout=max(0.1, end - time.monotonic()))
        except queue.Empty:
            break
        if m is None:
            sys.exit("helper exited")
        if m.get("type") == "torrent.progress":
            rows[:] = m["payload"]["torrents"]
            continue
        if m.get("id") == id:
            return m
    sys.exit(f"no reply to {id}")

rows = []

def watch(q, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            m = q.get(timeout=0.5)
        except queue.Empty:
            continue
        if m and m.get("type") == "torrent.progress":
            rows[:] = m["payload"]["torrents"]
    return rows[0] if rows else None

def main():
    helper, magnet = sys.argv[1], sys.argv[2]
    p = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    q = queue.Queue()
    threading.Thread(target=reader, args=(p, q), daemon=True).start()
    send(p, {"id": 1, "type": "hello", "payload": {"protocol": 1}})
    reply(q, 1, 10)

    send(p, {"id": 2, "type": "torrent.inspect", "payload": {"source": {"url": magnet}}})
    info = reply(q, 2, 120)
    log("inspect:", json.dumps(info))
    if info["type"] != "torrent.info":
        sys.exit("inspect failed")
    tid = info["payload"]["id"]

    send(p, {"id": 3, "type": "torrent.add", "payload": {"source": {"url": magnet}}})
    added = reply(q, 3, 60)
    log("add:", json.dumps(added))
    if added["type"] != "torrent.info" or added["payload"]["files"] != info["payload"]["files"] or added["payload"]["size"] != info["payload"]["size"]:
        sys.exit("add reply differs from inspect")
    row = watch(q, 15)
    log("after 15 s:", json.dumps(row))
    if not row or row["id"] != tid or row["done"] <= 0 or row["state"] not in ("downloading", "seeding"):
        sys.exit("no download progress")

    send(p, {"id": 4, "type": "torrent.pause", "payload": {"id": tid}})
    log("pause:", reply(q, 4, 10)["type"])
    row = watch(q, 3)
    log("paused row:", row["state"], row["downRate"])
    if row["state"] != "paused":
        sys.exit("not paused")

    send(p, {"id": 5, "type": "torrent.resume", "payload": {"id": tid}})
    log("resume:", reply(q, 5, 10)["type"])
    row = watch(q, 3)
    log("resumed row:", row["state"])

    folder = info["payload"]["folder"]
    before = os.listdir(folder)
    send(p, {"id": 6, "type": "torrent.remove", "payload": {"id": tid, "deleteFiles": True}})
    log("remove:", reply(q, 6, 20)["type"])
    watch(q, 2)
    log("rows after remove:", len(rows), "| folder before:", before, "after:", os.listdir(folder))
    if rows or os.listdir(folder):
        sys.exit("files or rows left after remove")

    send(p, {"id": 7, "type": "torrent.add", "payload": {"source": {"url": "javascript:alert(1)"}}})
    bad = reply(q, 7, 10)
    log("bad link:", json.dumps(bad))
    if bad["type"] != "error" or bad["payload"]["code"] != "torrent_failed":
        sys.exit("bad link not refused")
    p.stdin.close()
    p.wait(timeout=10)
    log("PASS")

main()
