#!/usr/bin/env bash
# Restore MongoDB from an encrypted backup.
#
#   scripts/restore.sh --identity ~/.config/gsp/backup-identity.txt [--source offsite|offsite-dir|local] [--file NAME] [--yes]
#
# Defaults to the newest backup in the off-site location, because if you're
# running this for real the local disk is probably what you lost.
#
# Prints a timing line per phase so the RTO is measured, not guessed.
set -euo pipefail
SCRIPT_NAME=restore
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require docker age sha256sum curl jq

BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups/local}"
OFFSITE_REMOTE="${OFFSITE_REMOTE:-}"
OFFSITE_DIR="${OFFSITE_DIR:-}"
IDENTITY="${AGE_IDENTITY_FILE:-}"
SOURCE=""
FILE=""
YES=0

while (( $# )); do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --source)   SOURCE="$2"; shift 2 ;;
    --file)     FILE="$2"; shift 2 ;;
    --yes)      YES=1; shift ;;
    -h|--help)  sed -n '2,11p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$IDENTITY" && -s "$IDENTITY" ]] || die "need the backup private key: --identity FILE"
if [[ -z "$SOURCE" ]]; then
  if [[ -n "$OFFSITE_REMOTE" ]]; then SOURCE=offsite
  elif [[ -n "$OFFSITE_DIR" ]]; then SOURCE=offsite-dir
  else SOURCE=local; fi
fi

t0=$(date +%s)
phase_start=$t0
phase() {
  local now; now=$(date +%s)
  log "phase '$1' took $(( now - phase_start ))s"
  phase_start=$now
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. pick and fetch
case "$SOURCE" in
  offsite)
    require rclone
    [[ -n "$FILE" ]] || FILE="$(rclone lsf "$OFFSITE_REMOTE" --include 'gsp-mongo-*.age' | sort | tail -1)"
    [[ -n "$FILE" ]] || die "no backups found in $OFFSITE_REMOTE"
    rclone copy "$OFFSITE_REMOTE/$FILE" "$work/"
    rclone copy "$OFFSITE_REMOTE/$FILE.sha256" "$work/"
    ;;
  offsite-dir|local)
    dir="$OFFSITE_DIR"; [[ "$SOURCE" == local ]] && dir="$BACKUP_DIR"
    [[ -n "$FILE" ]] || FILE="$(find "$dir" -maxdepth 1 -name 'gsp-mongo-*.age' -printf '%f\n' | sort | tail -1)"
    [[ -n "$FILE" ]] || die "no backups found in $dir"
    cp "$dir/$FILE" "$dir/$FILE.sha256" "$work/"
    ;;
  *) die "unknown source: $SOURCE" ;;
esac
backup_ts="$(sed -E 's/^gsp-mongo-([0-9TZ]+)\..*/\1/' <<<"$FILE")"
log "using $FILE from $SOURCE (taken ${backup_ts})"
phase fetch

# 2. integrity before we touch anything
( cd "$work" && sha256sum -c --quiet "$FILE.sha256" ) || die "checksum mismatch, refusing to restore"
age -d -i "$IDENTITY" "$work/$FILE" >/dev/null || die "cannot decrypt with the given identity"
phase verify

if (( YES == 0 )); then
  read -r -p "This DROPS and replaces the '${MONGO_DB}' database. Type the db name to continue: " answer
  [[ "$answer" == "$MONGO_DB" ]] || die "aborted"
fi

# 3. make sure mongo is up (a fresh volume re-runs the init script and
#    recreates the app/ops users)
dc up -d mongo
wait_healthy mongo 180 || die "mongo not healthy"
phase mongo_ready

# 4. decrypt straight into mongorestore, nothing plaintext touches disk
# shellcheck disable=SC2016
age -d -i "$IDENTITY" "$work/$FILE" | dc exec -T mongo sh -c '
  umask 077
  cfg=$(mktemp)
  printf "password: %s\n" "$(cat /run/secrets/mongo_ops_password)" > "$cfg"
  mongorestore --quiet --username ops --authenticationDatabase admin \
    --config "$cfg" --archive --gzip --drop --nsInclude "${MONGO_DB}.*"
  rc=$?
  rm -f "$cfg"
  exit $rc
'
phase restore

# 5. app healthy again through the front door
ok=0
for _ in $(seq 1 60); do
  if curl_app "${PUBLIC_URL}/readyz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
(( ok == 1 )) || die "restore finished but ${PUBLIC_URL}/readyz is not healthy"
phase app_ready

total=$(( $(date +%s) - t0 ))
log "restore complete in ${total}s; data is as of ${backup_ts}"
echo "RESTORE_FILE=$FILE"
echo "RESTORE_BACKUP_TS=$backup_ts"
echo "RESTORE_SECONDS=$total"
