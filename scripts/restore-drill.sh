#!/usr/bin/env bash
# The restore drill. Destroys the MongoDB volume for real, restores from the
# newest OFF-SITE backup and measures:
#
#   RTO = seconds from "volume destroyed" to "/readyz is 200 through nginx"
#   RPO = age of the backup at the moment of destruction, plus the number of
#         records written after that backup that did not come back
#
# By default it uses whatever backup already exists (i.e. the last scheduled
# one), because taking a fresh backup a second before the "disaster" would
# make the RPO number meaningless. --fresh-backup is there for a first run on
# an empty stack.
#
#   scripts/restore-drill.sh --identity ~/.config/gsp/backup-identity.txt [--fresh-backup] [--yes]
#
# Writes a report to docs/evidence/restore-drill-<timestamp>.md
set -euo pipefail
SCRIPT_NAME=drill
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require docker curl jq

IDENTITY="${AGE_IDENTITY_FILE:-}"
FRESH=0
YES=0
while (( $# )); do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --fresh-backup) FRESH=1; shift ;;
    --yes) YES=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -s "$IDENTITY" ]] || die "need --identity (backup private key)"

PROJECT="${COMPOSE_PROJECT_NAME:-gsp}"
VOLUME="${PROJECT}_mongo_data"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
report="$ROOT_DIR/docs/evidence/restore-drill-${stamp}.md"
mkdir -p "$(dirname "$report")"

count_notes() { curl_app "${PUBLIC_URL}/api/notes?limit=1" | jq -r '.total'; }

log "preflight"
curl_app "${PUBLIC_URL}/readyz" >/dev/null || die "stack is not healthy before the drill, fix that first"
version="$(curl_app "${PUBLIC_URL}/readyz" | jq -r '.color + " " + .version')"

if (( FRESH == 1 )); then
  log "taking a fresh backup (--fresh-backup)"
  "$ROOT_DIR/scripts/backup.sh"
fi

# Write something after the last backup. This record SHOULD be lost; if it
# survives, the drill didn't actually destroy anything.
marker="drill-marker-${stamp}"
curl_app -X POST -H 'Content-Type: application/json' \
  -d "{\"title\":\"${marker}\",\"body\":\"written after the last backup\"}" \
  "${PUBLIC_URL}/api/notes" >/dev/null
before="$(count_notes)"
log "records before destruction: ${before} (includes marker ${marker})"

if (( YES == 0 )); then
  read -r -p "About to DELETE docker volume ${VOLUME}. Type 'destroy' to continue: " answer
  [[ "$answer" == destroy ]] || die "aborted"
fi

# --- disaster ---
t_destroy=$(date +%s)
log "destroying mongo container and volume ${VOLUME}"
dc rm -sf mongo >/dev/null
docker volume rm "$VOLUME" >/dev/null
sleep 2
down_status="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${PUBLIC_URL}/readyz" || true)"
log "readyz during outage: HTTP ${down_status}"

# --- recovery ---
restore_out="$("$ROOT_DIR/scripts/restore.sh" --identity "$IDENTITY" --yes | tee /dev/stderr)"
t_ready=$(date +%s)

backup_file="$(grep '^RESTORE_FILE=' <<<"$restore_out" | cut -d= -f2)"
backup_ts="$(grep '^RESTORE_BACKUP_TS=' <<<"$restore_out" | cut -d= -f2)"
backup_epoch="$(date -u -d "$(sed -E 's/(....)(..)(..)T(..)(..)(..)Z/\1-\2-\3 \4:\5:\6/' <<<"$backup_ts")" +%s)"

after="$(count_notes)"
marker_back="$(curl_app "${PUBLIC_URL}/api/notes?limit=100" | jq --arg m "$marker" '[.items[] | select(.title == $m)] | length')"

rto=$(( t_ready - t_destroy ))
rpo=$(( t_destroy - backup_epoch ))
lost=$(( before - after ))

cat > "$report" <<MD
# Restore drill ${stamp}

| | |
|---|---|
| Host | $(hostname) |
| App before drill | ${version} |
| Backup used | \`${backup_file}\` (off-site copy) |
| Backup taken (UTC) | $(date -u -d "@${backup_epoch}" +'%F %T') |
| Volume destroyed (UTC) | $(date -u -d "@${t_destroy}" +'%F %T') |
| App healthy again (UTC) | $(date -u -d "@${t_ready}" +'%F %T') |
| readyz during outage | HTTP ${down_status} |
| **Measured RTO** | **${rto}s** (destroy -> /readyz 200 through nginx) |
| **Measured RPO** | **${rpo}s** (age of backup at time of loss) |
| Records before / after | ${before} / ${after} (lost: ${lost}) |
| Post-backup marker restored? | $([[ "$marker_back" == 0 ]] && echo "no, as expected" || echo "YES, investigate") |

RTO here is recovery time only. It does not include time to notice the
outage (up to 10 min with the 5 min checker and 2-failure threshold) or to
decide to restore. See README "Recovery objectives" for the full budget.
MD

log "RTO ${rto}s, RPO ${rpo}s, lost ${lost} record(s). Report: ${report#"$ROOT_DIR"/}"
