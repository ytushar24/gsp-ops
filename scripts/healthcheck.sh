#!/usr/bin/env bash
# Host-side checker, run from cron every minute. Complements the external
# GitHub Actions check: this one can see the backup and disk state, the
# external one can see the network path. Either on its own has a blind spot.
#
# Alerts after FAIL_THRESHOLD consecutive failures and again on recovery, so
# one slow request doesn't page anyone.
set -uo pipefail
SCRIPT_NAME=healthcheck
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups/local}"
BACKUP_MAX_AGE_MIN="${BACKUP_MAX_AGE_MIN:-90}"
DISK_MAX_PCT="${DISK_MAX_PCT:-85}"
STATE="$ROOT_DIR/deploy/.health"
mkdir -p "$(dirname "$STATE")"

check() {
  local name="$1" ok="$2" detail="$3"
  local f="$STATE.$name" fails=0 alerted=0
  [[ -f "$f" ]] && read -r fails alerted < "$f"
  if [[ "$ok" == 1 ]]; then
    if (( alerted == 1 )); then
      notify "RECOVERED: ${name} on $(hostname). ${detail}"
    fi
    echo "0 0" > "$f"
  else
    fails=$((fails + 1))
    if (( fails >= FAIL_THRESHOLD && alerted == 0 )); then
      notify "ALERT: ${name} failing on $(hostname) (${fails} checks). ${detail} Runbook: README.md#site-is-down-at-2am"
      alerted=1
    fi
    echo "$fails $alerted" > "$f"
    log "${name} failing (${fails}): ${detail}"
  fi
}

# 1. the site, through nginx
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${PUBLIC_URL}/readyz")"
check readyz "$([[ "$code" == 200 ]] && echo 1 || echo 0)" "GET /readyz -> ${code}."

# 2. backups are actually happening (a silent backup failure is the worst kind)
age_min=99999
if [[ -f "$BACKUP_DIR/.last_success" ]]; then
  age_min=$(( ( $(date +%s) - $(cat "$BACKUP_DIR/.last_success") ) / 60 ))
fi
check backup_freshness "$([[ $age_min -le $BACKUP_MAX_AGE_MIN ]] && echo 1 || echo 0)" \
  "Last successful backup ${age_min} min ago (limit ${BACKUP_MAX_AGE_MIN})."

# 3. disk (docker logs and backups both live here)
pct="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
check disk "$([[ $pct -lt $DISK_MAX_PCT ]] && echo 1 || echo 0)" "Root filesystem at ${pct}%."
