#!/usr/bin/env bash
# Sonix Manual Test Script
# Runs end-to-end checks for NFC, backend API, VLC, PulseAudio, Bluetooth, and mDNS
# Usage: bash sonix_manual_test.sh [--bt-mac AA:BB:CC:DD:EE:FF]

set -euo pipefail
IFS=$'\n\t'

HOST="${HOST:-localhost}"
PORT="${PORT:-5000}"
BASE_URL="http://${HOST}:${PORT}"
TEST_URL="${TEST_URL:-https://youtu.be/dQw4w9WgXcQ}"
BT_MAC=""

for arg in "$@"; do
  case "$arg" in
    --bt-mac=*) BT_MAC="${arg#*=}" ;;
  esac
done

SUDO=""
if [[ $(id -u) -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
fi

pass=0
fail=0

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red() { printf "\033[31m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
info() { printf "\033[36m%s\033[0m\n" "$*"; }

ok() { green "[PASS] $*"; pass=$((pass+1)); }
ko() { red "[FAIL] $*"; fail=$((fail+1)); }

curl_json() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sS -m 10 -H 'Content-Type: application/json' -X "$method" --data "$data" "$BASE_URL$path" || true
  else
    curl -sS -m 10 -X "$method" "$BASE_URL$path" || true
  fi
}

python_read_json_field() {
  python3 - "$1" <<'PY'
import sys, json
key=sys.argv[1]
try:
  data=json.load(sys.stdin)
  # Simple key lookup at top-level only
  print(data.get(key, ''))
except Exception:
  print('')
PY
}

section() {
  echo ""
  echo "==== $* ===="
}

section "Service status"
services=( pulseaudio-system sonix-backend sonix-nfc bluetooth avahi-daemon )
for svc in "${services[@]}"; do
  if $SUDO systemctl is-active --quiet "$svc"; then ok "Service $svc is active"; else ko "Service $svc is NOT active"; fi
done

section "I2C and PN532 detection"
if $SUDO i2cdetect -y 1 | grep -E "(24|48)" -q; then
  ok "PN532 appears on I2C bus (0x24/0x48)"
else
  ko "PN532 not detected on I2C (check wiring, I2C enabled)"
fi

section "Backend API reachability"
if curl -sS -m 5 "$BASE_URL/api/status" >/dev/null; then ok "Backend reachable at $BASE_URL"; else ko "Backend not reachable at $BASE_URL"; fi

section "Resolve test URL"
resolve_resp=$(curl_json POST /api/resolve "{\"url\":\"$TEST_URL\"}")
stream=$(printf '%s' "$resolve_resp" | python_read_json_field stream)
title=$(printf '%s' "$resolve_resp" | python_read_json_field title)
if [[ -n "$stream" ]]; then ok "Resolved stream ok"; else ko "Failed to resolve stream"; fi
if [[ -n "$title" ]]; then ok "Obtained title: $title"; else ko "Failed to obtain title"; fi

section "VLC playback start via backend"
play_resp=$(curl_json POST /api/control "{\"cmd\":\"play\",\"url\":\"$TEST_URL\",\"stream\":\"$stream\"}") || true
sleep 2

# Poll for status up to 20 seconds
got_progress=0
for i in $(seq 1 20); do
  status=$(curl_json GET /api/status)
  pos=$(printf '%s' "$status" | python3 - <<'PY'
import sys, json
try:
  d=json.load(sys.stdin)
  print(int(d.get('position') or 0))
except Exception:
  print(0)
PY
)
  dur=$(printf '%s' "$status" | python3 - <<'PY'
import sys, json
try:
  d=json.load(sys.stdin)
  print(int(d.get('duration') or 0))
except Exception:
  print(0)
PY
)
  if [[ "$dur" -gt 0 || "$pos" -gt 0 ]]; then got_progress=1; break; fi
  sleep 1
done
if [[ $got_progress -eq 1 ]]; then ok "Playback started (pos=$pos dur=$dur)"; else ko "Playback did not start (no position/duration)"; fi

section "Seek test"
seek_resp=$(curl_json POST /api/seek "{\"seconds\":30}")
sleep 2
status2=$(curl_json GET /api/status)
pos2=$(printf '%s' "$status2" | python3 - <<'PY'
import sys, json
try:
  d=json.load(sys.stdin)
  print(int(d.get('position') or 0))
except Exception:
  print(0)
PY
)
if [[ "$pos2" -ge 25 ]]; then ok "Seek successful (position=$pos2)"; else ko "Seek failed (position=$pos2)"; fi

section "Volume test"
export PULSE_SERVER=unix:/var/run/pulse/native
curl_json POST /api/control "{\"cmd\":\"volume\",\"value\":30}" >/dev/null || true
sleep 1
vol_line=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null || true)
if echo "$vol_line" | grep -E "([1-9][0-9]?|100)%" -q; then ok "Volume set (line: $vol_line)"; else ko "Could not verify volume (pactl unavailable or no sink)"; fi

section "Queue and skip"
u1="$TEST_URL"
u2="https://youtu.be/5NV6Rdv1a3I"
curl_json POST /api/queue "{\"url\":\"$u1\",\"title\":\"T1\"}" >/dev/null
curl_json POST /api/queue "{\"url\":\"$u2\",\"title\":\"T2\"}" >/dev/null
curl_json POST /api/control "{\"cmd\":\"skip\"}" >/dev/null
sleep 2
status3=$(curl_json GET /api/status)
now_url=$(printf '%s' "$status3" | python3 - <<'PY'
import sys, json
try:
  d=json.load(sys.stdin)
  now=d.get('now') or {}
  print(now.get('url') or '')
except Exception:
  print('')
PY
)
if [[ "$now_url" == "$u2" ]]; then ok "Skip advanced to next queue item"; else ko "Skip did not advance (now=$now_url)"; fi

section "Stop playback"
curl_json POST /api/control "{\"cmd\":\"stop\"}" >/dev/null
sleep 1
status4=$(curl_json GET /api/status)
now4=$(printf '%s' "$status4" | python_read_json_field now)
if [[ -z "$now4" || "$now4" == "None" ]]; then ok "Playback stopped"; else ko "Stop failed (now still set)"; fi

section "NFC read tool"
if $SUDO /opt/sonix/venv/bin/python /opt/sonix/tools/nfc_read.py >/tmp/sonix_nfc_read.out 2>&1; then
  if grep -q "Found URL:" /tmp/sonix_nfc_read.out; then ok "NFC read tool detected URL"; else yellow "NFC read ran but no URL found (check tag)"; fi
else
  ko "NFC read tool failed (see /tmp/sonix_nfc_read.out)"
fi

section "NFC autoplay (tap within 15s)"
if $SUDO systemctl is-active --quiet sonix-nfc; then
  $SUDO systemctl restart sonix-nfc || true
  sleep 2
  yellow "Please tap a written tag on the reader now (15s window)..."
  for i in $(seq 1 15); do sleep 1; done
  ast=$(curl_json GET /api/status)
  nowp=$(printf '%s' "$ast" | python3 - <<'PY'
import sys, json
try:
  d=json.load(sys.stdin)
  now=d.get('now') or {}
  print(now.get('url') or '')
except Exception:
  print('')
PY
)
  if [[ -n "$nowp" ]]; then ok "Autoplay triggered via NFC (now=$nowp)"; else ko "Autoplay did not trigger. Check sonix-nfc logs: journalctl -u sonix-nfc -n 100"; fi
else
  ko "sonix-nfc service inactive; cannot test autoplay"
fi

section "Bluetooth (optional)"
scan=$(curl_json GET /api/bt/scan)
if echo "$scan" | grep -q "devices"; then ok "BT scan API responded"; else ko "BT scan API failed"; fi
if [[ -n "$BT_MAC" ]]; then
  pair_resp=$(curl_json POST /api/bt/pair "{\"mac\":\"$BT_MAC\"}")
  if echo "$pair_resp" | grep -q "$BT_MAC"; then ok "BT pair request sent for $BT_MAC"; else ko "BT pair request failed"; fi
  sleep 5
  if pactl list short sinks 2>/dev/null | grep -qi bluez; then ok "BlueZ sink present"; else yellow "BlueZ sink not found (ensure speaker in pairing mode)"; fi
fi

section "mDNS (sonix.local)"
if ping -c1 -W2 sonix.local >/dev/null 2>&1; then ok "mDNS reachable (sonix.local)"; else yellow "mDNS ping failed (avahi may need time or firewall rules)"; fi

echo ""
echo "==== SUMMARY ===="
echo "Passed: $pass"
echo "Failed: $fail"
if [[ $fail -gt 0 ]]; then exit 1; else exit 0; fi

