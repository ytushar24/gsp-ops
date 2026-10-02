#!/usr/bin/env bash
# Self-signed cert for local runs only. Production uses a Cloudflare Origin CA
# certificate (see README, "Going to a real server").
set -euo pipefail
SCRIPT_NAME=gen-dev-cert
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require openssl

dir="$ROOT_DIR/nginx/certs"
mkdir -p "$dir"
if [[ -s "$dir/server.crt" && -s "$dir/server.key" ]]; then
  log "cert already present, leaving it"
  exit 0
fi

( umask 077
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$dir/server.key" -out "$dir/server.crt" -days 90 \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,DNS:gsp.local,IP:127.0.0.1" 2>/dev/null )
# Key stays 0600; the nginx master process reads it as root before dropping
# privileges to its workers.
chmod 644 "$dir/server.crt"
log "wrote $dir/server.{crt,key}"
