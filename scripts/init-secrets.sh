#!/usr/bin/env bash
# Generates local secrets and the backup encryption keypair. Safe to re-run:
# existing files are left alone.
#
# Everything lands in ./secrets (gitignored, dir mode 0700) except the age
# private key, which goes outside the repo. See docs/decisions.md#backup-keys.
set -euo pipefail
SCRIPT_NAME=init-secrets
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require openssl age-keygen

SECRETS_DIR="$ROOT_DIR/secrets"
IDENTITY_FILE="${AGE_IDENTITY_FILE:-$HOME/.config/gsp/backup-identity.txt}"

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Files are 0644 because the containers run as their own uids (mongodb=999,
# node=1000) and compose file secrets are plain bind mounts. The 0700 on the
# directory is what keeps other host users out.
put() {
  local name="$1" value="$2" path="$SECRETS_DIR/$1"
  if [[ -s "$path" ]]; then
    log "keeping existing $name"
    return
  fi
  ( umask 022; printf '%s' "$value" > "$path" )
  log "wrote $name"
}

gen() { openssl rand -hex 24; }

put mongo_root_user "root"
put mongo_root_password "$(gen)"
put mongo_ops_password "$(gen)"
put mongo_app_password "$(gen)"

# The app gets a full URI so it never has to assemble credentials itself.
app_pw="$(cat "$SECRETS_DIR/mongo_app_password")"
put mongo_app_uri "mongodb://app:${app_pw}@mongo:27017/${MONGO_DB}?authSource=${MONGO_DB}"

if [[ ! -s "$SECRETS_DIR/backup.age.pub" ]]; then
  if [[ ! -s "$IDENTITY_FILE" ]]; then
    mkdir -p "$(dirname "$IDENTITY_FILE")"
    ( umask 077; age-keygen -o "$IDENTITY_FILE" 2>/dev/null )
    log "generated backup identity at $IDENTITY_FILE"
  fi
  age-keygen -y "$IDENTITY_FILE" > "$SECRETS_DIR/backup.age.pub"
  log "wrote backup.age.pub (public recipient)"
  cat >&2 <<MSG

  The backup PRIVATE key is at: $IDENTITY_FILE
  On a real server this must not stay on the box that takes the backups.
  Copy it to your password manager / an offline location and to the
  BACKUP_AGE_IDENTITY GitHub secret (used by the nightly verify job), then
  remove it from the server. restore.sh takes it via --identity when needed.

MSG
fi
