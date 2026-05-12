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

fail_if_placeholder_env() {
  local bad=0

  for key in PG_PASS AUTHENTIK_SECRET_KEY DESEC_TOKEN PGADMIN_DEFAULT_EMAIL PGADMIN_DEFAULT_PASSWORD; do
    if ! grep -qE "^${key}=" "${ENV_FILE}"; then
      echo "Missing required .env key: ${key}"
      bad=1
    fi
  done

  if grep -qE '=(change_me|change_me_|CHANGE_ME|todo|TODO)' "${ENV_FILE}"; then
    echo "Refusing to start: .env still contains placeholder values."
    bad=1
  fi

  if [[ "${bad}" -ne 0 ]]; then
    echo "Edit ${ENV_FILE} first."
    exit 1
  fi
}

wait_running() {
  local service="$1"
  local timeout="${2:-120}"
  local elapsed=0
  local id=""
  local state=""

  echo "Waiting for ${service} to be running..."

  while (( elapsed < timeout )); do
    id="$(compose ps -q "${service}" || true)"

    if [[ -n "${id}" ]]; then
      state="$(docker inspect -f '{{.State.Status}}' "${id}" 2>/dev/null || true)"
      if [[ "${state}" == "running" ]]; then
        echo "${service} is running."
        return 0
      fi
    fi

    sleep 3
    elapsed=$((elapsed + 3))
  done

  echo "Timed out waiting for ${service} to run."
  compose logs --tail=80 "${service}" || true
  exit 1
}

wait_healthy() {
  local service="$1"
  local timeout="${2:-180}"
  local elapsed=0
  local id=""
  local health=""

  echo "Waiting for ${service} to become healthy..."

  while (( elapsed < timeout )); do
    id="$(compose ps -q "${service}" || true)"

    if [[ -n "${id}" ]]; then
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${id}" 2>/dev/null || true)"

      if [[ "${health}" == "healthy" || "${health}" == "running" ]]; then
        echo "${service} is ${health}."
        return 0
      fi

      if [[ "${health}" == "unhealthy" ]]; then
        echo "${service} is unhealthy."
        compose logs --tail=100 "${service}" || true
        exit 1
      fi
    fi

    sleep 3
    elapsed=$((elapsed + 3))
  done

  echo "Timed out waiting for ${service}."
  compose logs --tail=100 "${service}" || true
  exit 1
}

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Run: sudo ${BASE}/scripts/prepare.sh"
  exit 1
fi

fail_if_placeholder_env

echo "Validating compose config..."
compose config >/dev/null

echo "Pulling images..."
compose pull

echo "Starting database dependencies..."
compose up -d postgres redis
wait_healthy postgres 240
wait_healthy redis 120

echo "Starting ingress..."
compose up -d traefik
wait_running traefik 120

echo "Starting Authentik..."
compose up -d authentik-server authentik-worker
wait_running authentik-server 180
wait_running authentik-worker 180

echo "Starting NetBird..."
compose up -d netbird-server
wait_running netbird-server 180
compose up -d netbird-dashboard netbird-proxy
wait_running netbird-dashboard 120
wait_running netbird-proxy 120

echo "Starting remaining services..."
compose up -d teamspeak6 pgadmin dockhand
wait_running teamspeak6 120
wait_running pgadmin 120
wait_running dockhand 120

echo
echo "Stack is up."
compose ps
