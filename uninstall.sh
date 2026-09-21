#!/usr/bin/env bash
# Remove llama-idle-watchdog from this machine.
# Does not stop or remove llama-server.service.
#   sudo ./uninstall.sh

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

UNIT=llama-idle-watchdog.service

if systemctl list-unit-files --plain --no-legend "$UNIT" 2>/dev/null | grep -q .; then
  systemctl disable --now "$UNIT" 2>/dev/null || true
  systemctl stop "$UNIT" 2>/dev/null || true
fi

rm -f /etc/systemd/system/llama-idle-watchdog.service
rm -f /etc/systemd/system/multi-user.target.wants/llama-idle-watchdog.service
rm -f /usr/local/bin/llama-idle-watchdog.sh
rm -f /etc/default/llama-idle-watchdog
rm -rf /var/lib/llama-idle-watchdog

systemctl daemon-reload
systemctl reset-failed "$UNIT" 2>/dev/null || true

echo "Removed llama-idle-watchdog."
echo "llama-server.service was left running."
echo
echo "Confirm:"
echo "  systemctl status llama-idle-watchdog.service"
