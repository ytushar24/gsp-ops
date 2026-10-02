#!/usr/bin/env bash
# One screen of "what is the state of things". First thing to run when paged.
set -uo pipefail
SCRIPT_NAME=status
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups/local}"

echo "== containers"
dc ps --format 'table {{.Service}}\t{{.Status}}\t{{.Image}}'

echo
echo "== traffic"
echo "live (nginx)  : $(live_color)"
echo "active colour : $(active_color) (previous: $(state_get PREVIOUS_COLOR))"
echo "blue tag      : $(state_get BLUE_TAG)"
echo "green tag     : $(state_get GREEN_TAG)"
echo "deployed at   : $(state_get DEPLOYED_AT)"
printf 'readyz        : '
curl -sk --max-time 5 -w ' (HTTP %{http_code})\n' "${PUBLIC_URL}/readyz" || echo "no response"

echo
echo "== backups"
if [[ -f "$BACKUP_DIR/.last_success" ]]; then
  echo "last success  : $(( ( $(date +%s) - $(cat "$BACKUP_DIR/.last_success") ) / 60 )) min ago"
else
  echo "last success  : never"
fi
find "$BACKUP_DIR" -maxdepth 1 -name 'gsp-mongo-*.age' -printf '%f  %s bytes\n' 2>/dev/null | sort | tail -3

echo
echo "== host"
df -h / | tail -1 | awk '{print "disk /        : " $5 " used (" $4 " free)"}'
uptime
