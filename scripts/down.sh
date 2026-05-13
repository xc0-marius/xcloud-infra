#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/opt/xcloud-infra"
COMPOSE_FILE="${BASE}/compose.yml"
ENV_FILE="${BASE}/.env"
LOCK_FILE="${BASE}/.xcloud-infra-stack.lock"
COMPOSE_EXTRA_FILES="${COMPOSE_EXTRA_FILES:-}"

cd "${BASE}"

touch "${LOCK_FILE}"
chmod 0640 "${LOCK_FILE}"

COMPOSE_ARGS=(--env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")
if [[ -n "${COMPOSE_EXTRA_FILES}" ]]; then
  for extra_file in ${COMPOSE_EXTRA_FILES}; do
    COMPOSE_ARGS+=(-f "${extra_file}")
  done
fi

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "Another xcloud-infra stack operation is already running."
  exit 1
fi

compose() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
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
