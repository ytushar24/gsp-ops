#!/usr/bin/env bash
# Blue/green deploy behind nginx.
#
#   scripts/deploy.sh <image-tag>
#
# 1. start the idle colour on the new tag
# 2. wait for its Docker healthcheck (which hits /readyz, so DB access is checked)
# 3. flip nginx/live/color to it (nginx picks it up on the next request, no
#    reload; in-flight requests on the old colour finish normally)
# 4. confirm through nginx that the new version is what's answering
#
# If 1-2 fail, nothing user-facing has changed. If 4 fails, the switch is
# undone before exiting. The old colour keeps running as the rollback target,
# so scripts/rollback.sh is one file write.
set -euo pipefail
SCRIPT_NAME=deploy
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require docker curl jq

TAG="${1:-}"
[[ -n "$TAG" ]] || die "usage: $0 <image-tag>"
APP_IMAGE="${APP_IMAGE:-gsp-notes}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"

exec 9>"$ROOT_DIR/deploy/.deploy.lock"
flock -n 9 || die "another deploy is running"

active="$(active_color)"
if [[ -z "$active" ]]; then
  target=blue
  log "no active colour recorded, treating this as the first deploy"
else
  target="$(other_color "$active")"
fi
target_svc="app_${target}"
TARGET_KEY="${target^^}_TAG"
previous_target_tag="$(state_get "$TARGET_KEY")"

log "deploying ${APP_IMAGE}:${TAG} to ${target} (active: ${active:-none})"

if ! docker image inspect "${APP_IMAGE}:${TAG}" >/dev/null 2>&1; then
  log "pulling ${APP_IMAGE}:${TAG}"
  docker pull "${APP_IMAGE}:${TAG}" >/dev/null
fi

dc up -d mongo
wait_healthy mongo 120 || die "mongo is not healthy, refusing to deploy"

state_set "$TARGET_KEY" "$TAG"
dc up -d --no-deps --force-recreate "$target_svc"

if ! wait_healthy "$target_svc" "$HEALTH_TIMEOUT"; then
  log "new container failed its healthcheck, last logs:"
  dc logs --tail 40 "$target_svc" >&2 || true
  dc stop "$target_svc" >/dev/null || true
  if [[ -n "$previous_target_tag" ]]; then
    state_set "$TARGET_KEY" "$previous_target_tag"
  fi
  notify "Deploy of ${TAG} aborted: ${target} failed health checks. Traffic untouched on ${active:-none}."
  die "deploy aborted, traffic was never switched"
fi

set_live "$target"
if [[ -z "$(dc ps -q nginx)" ]]; then
  dc up -d nginx
  wait_healthy nginx 30 || die "nginx did not come up"
fi

# Verify the switch from the outside: the version answering through nginx has
# to be the one we just deployed.
ok=0
for _ in 1 2 3 4 5; do
  body="$(curl_app "${PUBLIC_URL}/readyz" 2>/dev/null || true)"
  if [[ "$(jq -r '.color + ":" + .version' <<<"$body" 2>/dev/null)" == "${target}:${TAG}" ]]; then
    ok=1
    break
  fi
  sleep 1
done

if (( ok == 0 )); then
  log "smoke test through nginx failed (got: ${body:-nothing})"
  if [[ -n "$active" ]]; then
    set_live "$active"
    notify "Deploy of ${TAG} rolled back automatically: smoke test through nginx failed."
    die "switched back to ${active}"
  fi
  die "first deploy failed smoke test"
fi

state_set ACTIVE_COLOR "$target"
if [[ -n "$active" ]]; then
  state_set PREVIOUS_COLOR "$active"
fi
state_set DEPLOYED_AT "$(date -u +%FT%TZ)"
echo "$(date -u +%FT%TZ) ${target} ${TAG}" >> "$ROOT_DIR/deploy/history.log"

log "live: ${target} on ${TAG}. ${active:+${active} left running for rollback (scripts/rollback.sh).}"
