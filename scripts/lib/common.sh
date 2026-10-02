# shellcheck shell=bash
# Shared helpers. Sourced, not executed.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/compose/docker-compose.yml"
STATE_FILE="$ROOT_DIR/deploy/state.env"
LIVE_DIR="$ROOT_DIR/nginx/live"
LIVE_FILE="$LIVE_DIR/color"
mkdir -p "$ROOT_DIR/deploy"

# .env holds non-secret settings (ports, bucket name, webhook URL path etc).
if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
fi

MONGO_DB="${MONGO_DB:-gsp}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
PUBLIC_URL="${PUBLIC_URL:-https://localhost:${HTTPS_PORT}}"

log()  { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${SCRIPT_NAME:-gsp}" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

require() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

# Every compose call goes through here so the deploy state (which tag each
# colour runs) is always applied. Without this, a stray "docker compose up -d"
# would recreate a colour with the wrong image.
dc() {
  local args=(--project-directory "$ROOT_DIR/compose" -f "$COMPOSE_FILE")
  [[ -f "$ROOT_DIR/.env" ]] && args+=(--env-file "$ROOT_DIR/.env")
  [[ -f "$STATE_FILE" ]] && args+=(--env-file "$STATE_FILE")
  docker compose "${args[@]}" "$@"
}

state_get() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  # `|| true`: a key that isn't set yet is normal (the first deploy of a
  # colour). Without it grep exits 1, and under `set -e` that kills the
  # caller before it has logged anything.
  { grep -E "^${key}=" "$STATE_FILE" || true; } | tail -1 | cut -d= -f2-
}

state_set() {
  local key="$1" value="$2" tmp
  mkdir -p "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  tmp="$(mktemp "$STATE_FILE.XXXX")"
  grep -vE "^${key}=" "$STATE_FILE" > "$tmp" || true
  echo "${key}=${value}" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}

active_color() { state_get ACTIVE_COLOR; }
other_color()  { [[ "$1" == "blue" ]] && echo green || echo blue; }

# The traffic switch. nginx reads this file on every request (nginx/njs/live.js),
# so replacing it atomically moves new requests to the other colour while
# requests already in flight finish where they started. No reload involved.
set_live() {
  local color="$1" tmp
  [[ "$color" == blue || "$color" == green ]] || die "bad colour: $color"
  mkdir -p "$LIVE_DIR"
  tmp="$(mktemp "$LIVE_DIR/.color.XXXX")"
  echo "$color" > "$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$LIVE_FILE"
}

live_color() { [[ -f "$LIVE_FILE" ]] && cat "$LIVE_FILE"; }

container_health() {
  local svc="$1" id
  id="$(dc ps -q "$svc")"
  [[ -n "$id" ]] || { echo "missing"; return; }
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id"
}

wait_healthy() {
  local svc="$1" timeout="${2:-90}" waited=0 status
  while (( waited < timeout )); do
    status="$(container_health "$svc")"
    [[ "$status" == "healthy" ]] && return 0
    [[ "$status" == "unhealthy" || "$status" == "exited" ]] && break
    sleep 2
    waited=$((waited + 2))
  done
  log "$svc did not become healthy (last status: ${status:-unknown})"
  return 1
}

# curl against our own nginx; -k because the local cert is self-signed.
curl_app() {
  curl -fsS -k --max-time 5 "$@"
}

notify() {
  local msg="$1"
  [[ -n "${ALERT_WEBHOOK_URL:-}" ]] || { log "no ALERT_WEBHOOK_URL set, alert not sent: $msg"; return 0; }
  local payload
  if [[ "$ALERT_WEBHOOK_URL" == *discord* ]]; then
    payload="$(jq -n --arg c "$msg" '{content: $c}')"
  else
    payload="$(jq -n --arg t "$msg" '{text: $t}')"
  fi
  curl -fsS --max-time 10 -H 'Content-Type: application/json' -d "$payload" "$ALERT_WEBHOOK_URL" >/dev/null \
    || log "webhook post failed"
}
