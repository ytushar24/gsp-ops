#!/usr/bin/env bash
# Proves a deploy drops nothing: runs load against the live stack, deploys
# NEW_TAG in the middle, and saves the load generator's report.
#
#   scripts/zero-downtime-test.sh <new-tag> [seconds]
set -euo pipefail
SCRIPT_NAME=zdt
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require node

TAG="${1:?usage: $0 <new-tag> [seconds]}"
SECONDS_TOTAL="${2:-60}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$ROOT_DIR/docs/evidence/zero-downtime-${stamp}.txt"
mkdir -p "$(dirname "$out")"
# the two part-files are merged into $out at the end; clean them up even if
# the deploy in the middle fails, so a failed run leaves no litter behind.
trap 'rm -f "$out.load" "$out.deploy"' EXIT

node "$ROOT_DIR/scripts/loadgen.js" --url "${PUBLIC_URL}/readyz" \
  --seconds "$SECONDS_TOTAL" --concurrency "${CONCURRENCY:-20}" > "$out.load" &
load_pid=$!

sleep $(( SECONDS_TOTAL / 3 ))
log "deploying ${TAG} under load"
"$ROOT_DIR/scripts/deploy.sh" "$TAG" 2> "$out.deploy"

set +e
wait "$load_pid"
load_rc=$?
set -e

{
  echo "# zero-downtime deploy check, ${stamp}"
  echo
  echo "## load generator"
  cat "$out.load"
  echo
  echo "## deploy log"
  cat "$out.deploy"
} > "$out"
rm -f "$out.load" "$out.deploy"

cat "$out"
if (( load_rc != 0 )); then
  die "FAIL: requests failed during deploy, see $out"
fi
log "PASS: zero failed requests"
