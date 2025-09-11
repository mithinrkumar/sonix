#!/usr/bin/env bash
# fix_4.sh - DNS, VLC audio output, and PN532 robustness
# - Force reliable DNS (Cloudflare + Google) persistently
# - Force VLC to use PulseAudio output and ensure run dir perms
# - Improve PN532 init loops in nfc_read.py and nfc_autoplay.py

set -euo pipefail
IFS=$'\n\t'

if [[ $(id -u) -ne 0 ]]; then
  echo "Run as root: sudo bash fix_4.sh" >&2
  exit 1
fi

msg(){ printf "\033[36m==> %s\033[0m\n" "$*"; }
ok(){ printf "\033[32m[OK]\033[0m %s\n" "$*"; }

APP_ROOT="/opt/sonix"

msg "Setting resilient DNS (Cloudflare + Google)..."
if [[ -f /etc/resolv.conf ]]; then
  cp /etc/resolv.conf /etc/resolv.conf.backup-sonix-$(date +%s) || true
  cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:2
EOF
  ok "Updated /etc/resolv.conf"
fi

if grep -q '^interface ' /etc/dhcpcd.conf 2>/dev/null; then
  if ! grep -q '^static domain_name_servers=' /etc/dhcpcd.conf 2>/dev/null; then
    echo 'static domain_name_servers=1.1.1.1 1.0.0.1 8.8.8.8' >> /etc/dhcpcd.conf
    ok "Persisted DNS in /etc/dhcpcd.conf"
  fi
  systemctl restart dhcpcd || true
fi

msg "Forcing VLC to use PulseAudio and fixing /run/sonix perms..."
install -d -m 0775 -o sonix -g sonix /run/sonix
if grep -q "--extraintf rc --rc-unix" /usr/local/bin/sonix-play; then
  sed -i -E 's/cvlc (.*)--extraintf rc --rc-unix/cvlc --aout=pulse \1--extraintf rc --rc-unix/' /usr/local/bin/sonix-play
  ok "Added --aout=pulse to VLC"
fi

msg "Hardening PN532 init (read + autoplay scripts)..."
READ_PY="${APP_ROOT}/tools/nfc_read.py"
AUTO_PY="${APP_ROOT}/tools/nfc_autoplay.py"
for f in "$READ_PY" "$AUTO_PY"; do
  if [[ -f "$f" ]]; then
    # Ensure frequency=100000 and add firmware check loop
    sed -i -E 's/busio\.I2C\(board\.SCL, board\.SDA(, frequency=[0-9]+)?\)/busio.I2C(board.SCL, board.SDA, frequency=100000)/' "$f"
    if ! grep -q 'firmware_version' "$f"; then
      sed -i -E 's/PN532_I2C\(i2c, debug=False\)/PN532_I2C(i2c, debug=False)/' "$f"
    fi
    # Insert firmware probe after PN532_I2C creation
    if ! grep -q 'get firmware' "$f"; then
      sed -i -E "s/(pn\s*=\s*PN532_I2C\(i2c, debug=False\)[^\n]*\n)/\1        try:\n            _fv = pn.firmware_version\n        except Exception:\n            pass\n/" "$f"
    fi
  fi
done

systemctl restart sonix-backend || true
systemctl restart sonix-nfc || true
ok "Applied fixes. Test playback again and NFC read/autoplay."

