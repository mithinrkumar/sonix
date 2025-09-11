#!/usr/bin/env bash
# Sonix Uninstall Script
# Removes Sonix services, files, and optional system changes.
# Usage:
#   sudo bash sonix_uninstall.sh [--purge-user] [--revert-pulseaudio] [--revert-dns] [--disable-pulseaudio]

set -euo pipefail
IFS=$'\n\t'

if [[ $(id -u) -ne 0 ]]; then
  echo "This script must be run as root. Use: sudo bash sonix_uninstall.sh" >&2
  exit 1
fi

PURGE_USER=0
REVERT_PA=0
REVERT_DNS=0
DISABLE_PA=0

for arg in "$@"; do
  case "$arg" in
    --purge-user) PURGE_USER=1 ;;
    --revert-pulseaudio) REVERT_PA=1 ;;
    --revert-dns) REVERT_DNS=1 ;;
    --disable-pulseaudio) DISABLE_PA=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP_ROOT="/opt/sonix"
LOG_DIR="/var/log/sonix"
RUN_DIR="/run/sonix"
SONIX_USER="sonix"

echo "==> Stopping Sonix services (ignore errors if not present)..."
systemctl stop sonix-backend.service 2>/dev/null || true
systemctl stop sonix-nfc.service 2>/dev/null || true
systemctl stop sonix-apply-audio.service 2>/dev/null || true

echo "==> Disabling Sonix services..."
systemctl disable sonix-backend.service 2>/dev/null || true
systemctl disable sonix-nfc.service 2>/dev/null || true
systemctl disable sonix-apply-audio.service 2>/dev/null || true

echo "==> Removing systemd unit files..."
rm -f /etc/systemd/system/sonix-backend.service
rm -f /etc/systemd/system/sonix-nfc.service
rm -f /etc/systemd/system/sonix-apply-audio.service
systemctl daemon-reload || true

echo "==> Removing Sonix binaries and configs..."
rm -f /usr/local/bin/sonix-play
rm -f /usr/local/bin/sonix-apply-audio-target
rm -rf /etc/sonix
rm -rf "$APP_ROOT"
rm -rf "$LOG_DIR"

echo "==> Cleaning runtime files and compatibility symlinks..."
rm -f /run/sonix_vlc.sock /run/sonix_player.pid
rm -rf "$RUN_DIR"

if [[ $DISABLE_PA -eq 1 ]]; then
  echo "==> Disabling PulseAudio system service (sonix installed it)..."
  systemctl stop pulseaudio-system.service 2>/dev/null || true
  systemctl disable pulseaudio-system.service 2>/dev/null || true
  rm -f /etc/systemd/system/pulseaudio-system.service
  systemctl daemon-reload || true
fi

if [[ $REVERT_PA -eq 1 ]]; then
  echo "==> Reverting PulseAudio configuration adjustments..."
  # Remove Sonix drop-in if present
  rm -f /etc/pulse/system.pa.d/sonix.pa 2>/dev/null || true
  # Remove auth-anonymous=1 token from native protocol line in system.pa
  if [[ -f /etc/pulse/system.pa ]]; then
    sed -i -E 's/(^\s*load-module\s+module-native-protocol-unix)\s+auth-anonymous=1(\s|$)/\1\2/' /etc/pulse/system.pa || true
  fi
  systemctl restart pulseaudio-system.service 2>/dev/null || true
fi

if [[ $REVERT_DNS -eq 1 ]]; then
  echo "==> Reverting DNS changes (if Sonix backup exists)..."
  latest_bak=$(ls -1t /etc/resolv.conf.backup-sonix-* 2>/dev/null | head -n1 || true)
  if [[ -n "${latest_bak:-}" && -f "$latest_bak" ]]; then
    cp "$latest_bak" /etc/resolv.conf
    echo "Restored /etc/resolv.conf from $latest_bak"
  fi
  # Remove static domain name servers line Sonix appended in dhcpcd.conf
  if [[ -f /etc/dhcpcd.conf ]]; then
    sed -i '/^static domain_name_servers=/d' /etc/dhcpcd.conf || true
    systemctl restart dhcpcd 2>/dev/null || true
  fi
fi

if [[ $PURGE_USER -eq 1 ]]; then
  echo "==> Removing user 'sonix' and home directory..."
  # Stop any lingering processes
  pkill -u "$SONIX_USER" 2>/dev/null || true
  # Delete user and home
  if id -u "$SONIX_USER" >/dev/null 2>&1; then
    userdel -r "$SONIX_USER" 2>/dev/null || true
  fi
  # Attempt to remove group if empty
  if getent group "$SONIX_USER" >/dev/null 2>&1; then
    groupdel "$SONIX_USER" 2>/dev/null || true
  fi
fi

echo "==> Sonix has been uninstalled."
echo "   - Services removed"
echo "   - Files under /opt/sonix and /var/log/sonix deleted"
echo "   - Binaries removed"
if [[ $DISABLE_PA -eq 1 ]]; then echo "   - pulseaudio-system disabled"; fi
if [[ $REVERT_PA -eq 1 ]]; then echo "   - PulseAudio config reverted"; fi
if [[ $REVERT_DNS -eq 1 ]]; then echo "   - DNS settings reverted"; fi
if [[ $PURGE_USER -eq 1 ]]; then echo "   - user 'sonix' removed"; fi

exit 0

