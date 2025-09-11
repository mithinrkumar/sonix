#!/usr/bin/env bash
# fix_2.sh - Apply Sonix fixes based on collected logs
# - PulseAudio: enable anonymous unix socket with fixed path
# - VLC: use /run/sonix for PID and RC socket; ensure dir exists
# - Backend: use new RC socket path
# - NFC service: unbuffered Python for visible logs
# - Restart services

set -euo pipefail
IFS=$'\n\t'

require_root() { if [[ $(id -u) -ne 0 ]]; then echo "Run as root: sudo bash fix_2.sh" >&2; exit 1; fi; }
msg(){ printf "\033[36m==> %s\033[0m\n" "$*"; }
ok(){ printf "\033[32m[OK]\033[0m %s\n" "$*"; }

require_root

APP_ROOT="/opt/sonix"
BACKEND_FILE="${APP_ROOT}/backend/app.py"
SONIX_PLAY="/usr/local/bin/sonix-play"
NFC_UNIT="/etc/systemd/system/sonix-nfc.service"

if [[ ! -f "$BACKEND_FILE" || ! -f "$SONIX_PLAY" ]]; then
  echo "Missing backend or sonix-play. Ensure SONIX is installed." >&2
  exit 2
fi

msg "Configuring PulseAudio native unix socket with anonymous auth..."
mkdir -p /etc/pulse/system.pa.d
cat > /etc/pulse/system.pa.d/sonix.pa << 'PA'
# Sonix overrides for system-wide PulseAudio
### Native unix protocol with anonymous auth on a fixed socket path
load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native
PA
ok "Wrote /etc/pulse/system.pa.d/sonix.pa"

msg "Updating sonix-play to use /run/sonix for PID and RC socket..."
RUN_DIR="/run/sonix"
mkdir -p "$RUN_DIR"
chown sonix:sonix "$RUN_DIR" || true
chmod 775 "$RUN_DIR" || true

tmpfile=$(mktemp)
cat > "$tmpfile" << 'SH'
#!/usr/bin/env bash
set -e
export PULSE_SERVER=unix:/var/run/pulse/native

RUN_DIR="/run/sonix"
PID_FILE="$RUN_DIR/player.pid"
RC_SOCK="$RUN_DIR/vlc.sock"
LOG_FILE="/var/log/sonix/player_cvlc.log"
VENV_YTDLP="/opt/sonix/venv/bin/yt-dlp"

mkdir -p "$RUN_DIR"
chown sonix:sonix "$RUN_DIR" 2>/dev/null || true

URL="$1"

if [[ "$1" == "--stop" ]]; then
  if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  rm -f "$RC_SOCK" 2>/dev/null || true
  exit 0
fi

if [[ -z "$URL" ]]; then
  echo "usage: sonix-play <URL>"
  exit 2
fi

STREAM="$URL"
if [[ "$URL" =~ ^https?:// && ! "$URL" =~ (googlevideo|manifest\.googlevideo|\.m3u8|\.m4a|\.opus|\.mp3) ]]; then
  if [[ -x "$VENV_YTDLP" ]]; then
    STREAM=$("$VENV_YTDLP" -g -f "bestaudio[abr<=160]/bestaudio/best" --no-playlist "$URL" 2>/dev/null | head -n1 || true)
    [[ -z "$STREAM" ]] && STREAM="$URL"
  fi
fi

if [[ -f "$PID_FILE" ]]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
  rm -f "$PID_FILE"
fi
rm -f "$RC_SOCK" 2>/dev/null || true

cvlc --no-video --intf dummy --extraintf rc --rc-unix "$RC_SOCK" \
     --play-and-exit --network-caching=300 "$STREAM" >> "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
SH
install -m 0755 "$tmpfile" "$SONIX_PLAY"
rm -f "$tmpfile"
ok "Updated $SONIX_PLAY"

msg "Pointing backend to new RC socket path..."
sed -i -E 's|UNIX-CONNECT:/run/sonix_vlc.sock|UNIX-CONNECT:/run/sonix/vlc.sock|g' "$BACKEND_FILE"
sed -i -E 's|\"/run/sonix_vlc.sock\"|\"/run/sonix/vlc.sock\"|g' "$BACKEND_FILE"
ok "Backend socket references updated"

msg "Making NFC service python unbuffered for logs..."
if grep -q 'ExecStart=/opt/sonix/venv/bin/python /opt/sonix/tools/nfc_autoplay.py' "$NFC_UNIT"; then
  sed -i 's|ExecStart=/opt/sonix/venv/bin/python /opt/sonix/tools/nfc_autoplay.py|ExecStart=/opt/sonix/venv/bin/python -u /opt/sonix/tools/nfc_autoplay.py|' "$NFC_UNIT"
  ok "Updated $NFC_UNIT for unbuffered output"
else
  ok "NFC unit already unbuffered or different"
fi

msg "Reloading and restarting services..."
systemctl daemon-reload
systemctl restart pulseaudio-system
systemctl restart sonix-backend
systemctl restart sonix-nfc
ok "Done. Re-run manual tests. If VLC still fails to resolve hosts, verify internet DNS and try playing a direct .mp3 URL."

