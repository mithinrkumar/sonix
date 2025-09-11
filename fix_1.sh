#!/usr/bin/env bash
# fix_1.sh - Apply Sonix fixes based on manual test results
# - Make backend non-blocking for play/skip (let VLC resolve)
# - Shorten resolve/title timeouts to avoid API timeouts
# - Load PulseAudio ALSA devices in system mode
# - Ensure I2C baudrate is set for PN532 stability
# - Restart services

set -euo pipefail
IFS=$'\n\t'

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "This script must run as root. Use: sudo bash fix_1.sh" >&2
    exit 1
  fi
}

msg() { printf "\033[36m==> %s\033[0m\n" "$*"; }
ok() { printf "\033[32m[OK]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\033[31m[ERR]\033[0m %s\n" "$*"; }

require_root

APP_ROOT="/opt/sonix"
BACKEND_FILE="${APP_ROOT}/backend/app.py"
PULSE_SYSTEM_PA="/etc/pulse/system.pa"

if [[ ! -f "$BACKEND_FILE" ]]; then
  err "Backend file not found: $BACKEND_FILE"
  exit 2
fi

msg "Patching backend to avoid blocking resolves and shorten timeouts..."
# Shorten yt-dlp resolve/title timeouts
sed -i -E 's/timeout=25/timeout=8/' "$BACKEND_FILE" || true
sed -i -E 's/timeout=10/timeout=6/' "$BACKEND_FILE" || true

# Make play non-blocking: pass URL directly to VLC, set title quickly
sed -i -E 's/stream = d.get\("stream"\) or resolve_stream\(url\)/stream = d.get("stream") or url/' "$BACKEND_FILE"
sed -i -E 's/"title": get_title\(url\)/"title": url/' "$BACKEND_FILE"

# Make skip non-blocking similarly
sed -i -E 's/stream = nxt.get\("stream"\) or resolve_stream\(nxt\["url"\]\)/stream = nxt.get("stream") or nxt["url"]/g' "$BACKEND_FILE"
sed -i -E 's/nxt.get\("title"\) or get_title\(nxt\["url"\]\)/nxt.get("title") or nxt["url"]/g' "$BACKEND_FILE"

ok "Backend updated"

msg "Ensuring PulseAudio system loads ALSA devices (module-udev-detect)..."
if ! grep -q '^load-module module-udev-detect' "$PULSE_SYSTEM_PA" 2>/dev/null; then
  echo 'load-module module-udev-detect' >> "$PULSE_SYSTEM_PA"
  ok "Added module-udev-detect to $PULSE_SYSTEM_PA"
else
  ok "module-udev-detect already present"
fi

msg "Ensuring I2C baudrate set (100kHz) for stability..."
CFG="/boot/firmware/config.txt"
if [[ ! -f "$CFG" ]]; then CFG="/boot/config.txt"; fi
if [[ -f "$CFG" ]]; then
  if ! grep -q '^dtparam=i2c_arm_baudrate=' "$CFG"; then
    echo 'dtparam=i2c_arm_baudrate=100000' >> "$CFG"
    ok "Added dtparam=i2c_arm_baudrate=100000 to $CFG (reboot to apply)"
  else
    ok "I2C baudrate already configured in $CFG"
  fi
else
  warn "No boot config found at /boot/firmware/config.txt or /boot/config.txt"
fi

msg "Reloading and restarting services..."
systemctl daemon-reload || true
systemctl restart pulseaudio-system || true
systemctl restart sonix-backend || true
systemctl restart sonix-nfc || true

ok "Fixes applied. Recommended: reboot if I2C baudrate was newly added."

echo ""
echo "Quick sanity check:"
echo "  - Backend status:"; systemctl is-active sonix-backend || true
echo "  - PulseAudio status:"; systemctl is-active pulseaudio-system || true
echo "  - NFC autoplay status:"; systemctl is-active sonix-nfc || true
echo "  - Try: curl -s http://localhost:5000/api/status | head -c 200; echo"

