#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/opt/xcloud-infra"
COMPOSE_FILE="${BASE}/compose.yml"
ENV_FILE="${BASE}/.env"
LOCK_FILE="/tmp/xcloud-infra-stack.lock"

cd "${BASE}"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "Another xcloud-infra stack operation is already running."
  exit 1
fi

compose() {
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

echo "Stopping public and app services first..."
compose stop \
  dockhand \
  pgadmin \
  teamspeak6 \
  netbird-proxy \
  netbird-dashboard \
  netbird-server \
  authentik-worker \
  authentik-server \
  traefik || true

echo "Stopping dependency services..."
compose stop redis postgres || true

echo "Removing stack containers and orphan containers, preserving volumes..."
compose down --remove-orphans

echo
echo "Stack is down. Named volumes and bind-mounted data were preserved."
