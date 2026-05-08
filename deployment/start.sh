#!/usr/bin/env bash
# One-shot bring-up for the FHIR Notification Broker stack:
#   1) WebSubHub (existing compose at $WEBSUBHUB_DIR)
#   2) FHIR server, Audit, CR, Broker (this repo's docker-compose.yml)
#
# Usage:  ./start.sh
# Env:    WEBSUBHUB_DIR (default: ~/Documents/websubhub-deployment/docker/kafka)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBSUBHUB_DIR="${WEBSUBHUB_DIR:-$HOME/Documents/websubhub-deployment/docker/kafka}"

log() { printf '\033[1;34m[start.sh]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[start.sh]\033[0m %s\n' "$*" >&2; }

# --- 1. Verify broker config ------------------------------------------------
if [[ ! -f "$HERE/broker/Config.toml" ]]; then
  err "Missing $HERE/broker/Config.toml"
  err "Copy from broker/Config.toml.example and fill in Asgardeo credentials:"
  err "    cp deployment/broker/Config.toml.example deployment/broker/Config.toml"
  exit 1
fi

# --- 2. Bring up WebSubHub (existing stack, untouched) ----------------------
if [[ ! -d "$WEBSUBHUB_DIR" ]]; then
  err "WebSubHub directory not found: $WEBSUBHUB_DIR"
  err "Set WEBSUBHUB_DIR to the path containing docker-compose.yml for the Kafka WebSubHub stack."
  exit 1
fi
log "Starting WebSubHub stack in $WEBSUBHUB_DIR"
( cd "$WEBSUBHUB_DIR" && docker compose up -d )

# --- 3. Bring up the broker stack ------------------------------------------
log "Building & starting broker stack in $HERE"
( cd "$HERE" && docker compose up -d --build )

# --- 4. Status --------------------------------------------------------------
cat <<EOF

Stack started.
  FHIR server : http://localhost:9090/fhir/r4/metadata
  CR          : http://localhost:9093/fhir/r4/metadata
  Audit       : http://localhost:9098
  Broker      : http://localhost:9091/broker/registry
  WebSubHub   : https://dev.websubhub.com:8443/hub  (requires '127.0.0.1 dev.websubhub.com' in your hosts file)

Logs:    docker compose -f $HERE/docker-compose.yml logs -f <service>
Stop:    docker compose -f $HERE/docker-compose.yml down
         docker compose -f $WEBSUBHUB_DIR/docker-compose.yml down
EOF
