#!/usr/bin/env bash
# fix_3.sh - Resolve PulseAudio auth, ensure VLC socket compatibility, and NFC deps
# - Modify /etc/pulse/system.pa to allow anonymous unix clients (no duplicate loads)
# - Remove prior drop-in to avoid bind() conflicts
# - Create backward-compat symlinks for old VLC pid/socket paths
# - Ensure Blinka libs present in Sonix venv
# - Restart services

set -euo pipefail
IFS=$'\n\t'

if [[ $(id -u) -ne 0 ]]; then
  echo "Run as root: sudo bash fix_3.sh" >&2
  exit 1
fi

msg(){ printf "\033[36m==> %s\033[0m\n" "$*"; }
ok(){ printf "\033[32m[OK]\033[0m %s\n" "$*"; }

PULSE_SYSTEM_PA="/etc/pulse/system.pa"
DROPIN="/etc/pulse/system.pa.d/sonix.pa"

msg "Adjusting PulseAudio system.pa to allow anonymous unix clients..."
if [[ -f "$PULSE_SYSTEM_PA" ]]; then
  # If the native unix protocol line lacks auth-anonymous, add it
  if grep -E '^\s*load-module\s+module-native-protocol-unix(\s|$)' "$PULSE_SYSTEM_PA" | grep -vq 'auth-anonymous=1'; then
    sed -i -E 's/^\s*load-module\s+module-native-protocol-unix(.*)$/load-module module-native-protocol-unix auth-anonymous=1 \1/' "$PULSE_SYSTEM_PA"
    ok "Updated module-native-protocol-unix with auth-anonymous=1"
  else
    ok "system.pa already allows anonymous unix clients"
  fi
else
  echo "Warning: $PULSE_SYSTEM_PA not found; skipping edit" >&2
fi

if [[ -f "$DROPIN" ]]; then
  rm -f "$DROPIN"
  ok "Removed drop-in $DROPIN to avoid duplicate module load"
fi

msg "Creating backward-compat symlinks for VLC paths..."
mkdir -p /run/sonix
chown sonix:sonix /run/sonix || true
chmod 775 /run/sonix || true
[[ -e /run/sonix_vlc.sock ]] || ln -s /run/sonix/vlc.sock /run/sonix_vlc.sock || true
[[ -e /run/sonix_player.pid ]] || ln -s /run/sonix/player.pid /run/sonix_player.pid || true
ok "Symlinks ready"

msg "Ensuring Blinka libs in Sonix venv (for PN532)..."
/opt/sonix/venv/bin/pip install --no-cache-dir -q adafruit-blinka adafruit-circuitpython-pn532 || true
ok "Blinka ensured"

msg "Reloading PulseAudio and Sonix services..."
systemctl daemon-reload
systemctl restart pulseaudio-system || true
sleep 1
PULSE_SERVER=unix:/var/run/pulse/native pactl info >/dev/null 2>&1 && ok "PulseAudio now accepting clients" || echo "Note: pactl still cannot connect; check PulseAudio logs"
systemctl restart sonix-backend || true
systemctl restart sonix-nfc || true
ok "Services restarted"

echo ""
echo "Next:"
echo "  - Re-run: bash /workspace/sonix_manual_test.sh"
echo "  - If VLC still shows DNS failures, fix system DNS (e.g., /etc/resolv.conf or router). Try playing a local MP3 to validate audio path."

