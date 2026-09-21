#!/usr/bin/env bash
# Install llama-idle-watchdog on this machine.
# Run from the directory that contains these files:
#   sudo ./install.sh

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"

install -m 0755 "${HERE}/llama-idle-watchdog.sh" /usr/local/bin/llama-idle-watchdog.sh
install -m 0644 "${HERE}/llama-idle-watchdog.service" /etc/systemd/system/llama-idle-watchdog.service

if [[ ! -f /etc/default/llama-idle-watchdog ]]; then
  install -m 0644 "${HERE}/llama-idle-watchdog.default" /etc/default/llama-idle-watchdog
else
  echo "Keeping existing /etc/default/llama-idle-watchdog"
fi

mkdir -p /var/lib/llama-idle-watchdog

systemctl daemon-reload
systemctl enable --now llama-idle-watchdog.service

echo
systemctl --no-pager --full status llama-idle-watchdog.service || true
echo
echo "Installed. Follow logs with:"
echo "  journalctl -u llama-idle-watchdog.service -f"
echo
echo "Edit settings in /etc/default/llama-idle-watchdog then:"
echo "  systemctl restart llama-idle-watchdog.service"
