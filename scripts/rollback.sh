#!/usr/bin/env bash
# Flip traffic back to the previous colour. Takes seconds because the previous
# container is still running from the last deploy.
#
# If the previous colour isn't healthy any more (host rebooted, it was stopped),
# redeploy a known-good tag instead:
#   tail deploy/history.log          # find the last good tag
#   scripts/deploy.sh <that-tag>
set -euo pipefail
SCRIPT_NAME=rollback
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require docker curl jq

exec 9>"$ROOT_DIR/deploy/.deploy.lock"
flock -n 9 || die "a deploy is in progress"

active="$(active_color)"
prev="$(state_get PREVIOUS_COLOR)"
[[ -n "$active" && -n "$prev" ]] || die "no previous colour recorded, nothing to roll back to"

prev_tag="$(state_get "${prev^^}_TAG")"
status="$(container_health "app_${prev}")"
if [[ "$status" != "healthy" ]]; then
  die "app_${prev} is '${status}', can't flip to it. Redeploy a good tag: scripts/deploy.sh <tag> (see deploy/history.log)"
fi

log "rolling back: ${active} -> ${prev} (${prev_tag})"
set_live "$prev"

body="$(curl_app "${PUBLIC_URL}/readyz" || true)"
log "now answering: $(jq -c '{color,version}' <<<"$body" 2>/dev/null || echo "$body")"

state_set ACTIVE_COLOR "$prev"
state_set PREVIOUS_COLOR "$active"
echo "$(date -u +%FT%TZ) ${prev} ${prev_tag} (rollback)" >> "$ROOT_DIR/deploy/history.log"
notify "Rolled back to ${prev_tag} (${prev})."
