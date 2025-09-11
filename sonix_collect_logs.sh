#!/usr/bin/env bash
# Sonix log collector
# Usage: sudo bash sonix_collect_logs.sh

set -euo pipefail
IFS=$'\n\t'

OUT="/tmp/sonix_diagnostic_$(date +%s).log"

green() { printf "\033[32m%s\033[0m\n" "$*"; }
section() { echo ""; echo "==== $* ====\n"; }

exec > >(tee "$OUT") 2>&1

section "System info"
uname -a || true
cat /etc/os-release || true
date || true

section "Service status"
for s in pulseaudio-system sonix-backend sonix-nfc bluetooth avahi-daemon; do
  systemctl status "$s" --no-pager || true
done

section "I2C and PN532 presence"
i2cdetect -y 1 || true

python3 - <<'PY' || true
print("PN532 probe...")
try:
  import time
  import board, busio
  from adafruit_pn532.i2c import PN532_I2C
  i2c = busio.I2C(board.SCL, board.SDA, frequency=100000)
  time.sleep(0.5)
  pn = PN532_I2C(i2c, debug=False)
  time.sleep(0.5)
  try:
    pn.SAM_configuration()
  except Exception:
    pass
  try:
    fv = pn.firmware_version
    print("PN532 firmware:", fv)
  except Exception as e:
    print("Firmware read error:", e)
  try:
    uid = pn.read_passive_target(timeout=1)
    print("UID:", uid)
  except Exception as e:
    print("Read target error:", e)
except Exception as e:
  print("Import/init error:", e)
PY

section "PulseAudio sinks"
export PULSE_SERVER=unix:/var/run/pulse/native
pulseaudio --version || true
cat /etc/pulse/system.pa || true
pactl info || true
pactl list short sinks || true

section "Backend logs"
journalctl -u sonix-backend -n 300 --no-pager || true

section "NFC autoplay logs"
journalctl -u sonix-nfc -n 300 --no-pager || true

section "VLC player log"
tail -n 200 /var/log/sonix/player_cvlc.log || true
ls -l /run/sonix_vlc.sock || true
ps aux | grep -E "(cvlc|vlc)" | grep -v grep || true

section "Backend API probes"
curl -sS -m 5 http://localhost:5000/api/status || true
echo
time curl -sS -m 12 -H 'Content-Type: application/json' -X POST \
  --data '{"url":"https://youtu.be/dQw4w9WgXcQ"}' http://localhost:5000/api/resolve || true
echo
time curl -sS -m 8 -H 'Content-Type: application/json' -X POST \
  --data '{"cmd":"play","url":"https://youtu.be/dQw4w9WgXcQ"}' http://localhost:5000/api/control || true
echo
sleep 3
curl -sS -m 5 http://localhost:5000/api/status || true
echo

section "Done"
green "Logs saved to: $OUT"

