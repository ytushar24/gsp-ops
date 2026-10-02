#!/usr/bin/env bash
# Hourly MongoDB backup.
#
#   mongodump (as the least-privilege "ops" user)
#     -> gzip archive
#     -> age-encrypted to the backup public key
#     -> local copy + sha256
#     -> off-site copy (rclone remote and/or a second directory)
#
# Only the PUBLIC key is on this host, so whoever owns this box can create
# backups but can't read old ones.
set -euo pipefail
SCRIPT_NAME=backup
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require docker age sha256sum

BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups/local}"
RECIPIENT_FILE="${AGE_RECIPIENT_FILE:-$ROOT_DIR/secrets/backup.age.pub}"
LOCAL_RETENTION_HOURS="${LOCAL_RETENTION_HOURS:-48}"
OFFSITE_REMOTE="${OFFSITE_REMOTE:-}"   # e.g. r2:gsp-backups/mongo
OFFSITE_DIR="${OFFSITE_DIR:-}"         # e.g. /mnt/offsite/gsp (simulated second location)

[[ -s "$RECIPIENT_FILE" ]] || die "no age recipient at $RECIPIENT_FILE (run scripts/init-secrets.sh)"
[[ -n "$OFFSITE_REMOTE" || -n "$OFFSITE_DIR" ]] || die "no off-site target configured (OFFSITE_REMOTE or OFFSITE_DIR)"

mkdir -p "$BACKUP_DIR"
exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || die "previous backup still running"

tmp=""
on_exit() {
  local rc=$?
  [[ -n "$tmp" ]] && rm -f "$tmp"
  if (( rc != 0 )); then
    notify "MongoDB backup FAILED on $(hostname) at $(date -u +%FT%TZ) (exit ${rc}). Check /var/log/gsp/backup.log."
  fi
}
trap on_exit EXIT

ts="$(date -u +%Y%m%dT%H%M%SZ)"
name="gsp-mongo-${ts}.archive.gz.age"
tmp="$BACKUP_DIR/.${name}.partial"
start=$(date +%s)

# The password goes into a throwaway --config file inside the container
# instead of onto the command line, where anyone on the host could read it
# from ps. printf is a shell builtin so it never appears as a process either.
# shellcheck disable=SC2016
dc exec -T mongo sh -c '
  umask 077
  cfg=$(mktemp)
  printf "password: %s\n" "$(cat /run/secrets/mongo_ops_password)" > "$cfg"
  mongodump --quiet --username ops --authenticationDatabase admin \
    --config "$cfg" --db "$MONGO_DB" --archive --gzip
  rc=$?
  rm -f "$cfg"
  exit $rc
' | age -R "$RECIPIENT_FILE" > "$tmp"

size=$(stat -c %s "$tmp")
(( size > 200 )) || die "backup suspiciously small (${size} bytes)"

mv "$tmp" "$BACKUP_DIR/$name"
tmp=""
( cd "$BACKUP_DIR" && sha256sum "$name" > "$name.sha256" )

if [[ -n "$OFFSITE_REMOTE" ]]; then
  require rclone
  # --immutable: never overwrite an existing object. Pair this with a bucket
  # lifecycle rule for retention and a write-only token, so this host
  # can't delete history. See docs/decisions.md.
  # One call per file: `rclone copy` takes exactly one source and one dest.
  rclone copy --immutable --no-traverse "$BACKUP_DIR/$name" "$OFFSITE_REMOTE"
  rclone copy --immutable --no-traverse "$BACKUP_DIR/$name.sha256" "$OFFSITE_REMOTE"
  log "shipped to $OFFSITE_REMOTE"
fi

if [[ -n "$OFFSITE_DIR" ]]; then
  mkdir -p "$OFFSITE_DIR"
  cp "$BACKUP_DIR/$name" "$BACKUP_DIR/$name.sha256" "$OFFSITE_DIR/"
  ( cd "$OFFSITE_DIR" && sha256sum -c --quiet "$name.sha256" )
  log "copied to $OFFSITE_DIR"
fi

find "$BACKUP_DIR" -maxdepth 1 -name 'gsp-mongo-*' -mmin +$((LOCAL_RETENTION_HOURS * 60)) -delete

date -u +%s > "$BACKUP_DIR/.last_success"
log "ok: $name ($(numfmt --to=iec "$size"), $(( $(date +%s) - start ))s)"
