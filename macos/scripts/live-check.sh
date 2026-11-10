#!/bin/sh
# Checks Tortuga with Tor on: run after switching Tortuga to Tor and waiting
# for "Tor on". Needs sudo for tcpdump and for killing the helper.
set -u
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAILED=1; }
FAILED=0
# Ask for the password now, so tcpdump is capturing before dig runs.
sudo -v || exit 1

echo "1. Through Tor"
CURL=$(curl -s --max-time 30 https://check.torproject.org/api/ip)
echo "$CURL" | grep -q '"IsTor":true' && ok "curl: $CURL" || bad "curl: $CURL"

echo "2. Two apps, two exits"
PY=$(/usr/bin/python3 -I -c 'import json,urllib.request;print(json.load(urllib.request.urlopen("https://check.torproject.org/api/ip",timeout=30))["IP"])' 2>&1)
C=$(echo "$CURL" | sed -E 's/.*"IP":"([^"]+)".*/\1/')
[ -n "$PY" ] && [ "$PY" != "$C" ] && ok "curl $C, python $PY" || bad "curl $C, python $PY (same exit, or python failed)"

echo "3. DNS through Tor, none on the wire"
sudo tcpdump -i en0 -n -c 5 'port 53' > /tmp/tortuga-dns.txt 2>/dev/null &
TCPDUMP=$!
sleep 1
A=$(dig +short +time=10 example.com | head -1)
sleep 2
sudo kill $TCPDUMP 2>/dev/null
[ -n "$A" ] && ok "dig example.com → $A" || bad "dig example.com: no answer"
grep -q ' IP' /tmp/tortuga-dns.txt && bad "DNS on en0: $(grep ' IP' /tmp/tortuga-dns.txt | head -2)" || ok "no DNS packets on en0"

echo "4. Nothing goes out while Tor is down"
sudo pkill -x tortuga-helper
sleep 1
curl -s --max-time 8 -o /dev/null https://example.com && bad "curl got through with the helper dead" || ok "curl fails with the helper dead"
echo "   waiting for Tortuga to restart Tor…"
for i in $(seq 1 60); do
  curl -s --max-time 8 https://check.torproject.org/api/ip | grep -q '"IsTor":true' && break
  sleep 2
done
curl -s --max-time 20 https://check.torproject.org/api/ip | grep -q '"IsTor":true' && ok "back through Tor" || bad "Tor didn't come back"

exit $FAILED
