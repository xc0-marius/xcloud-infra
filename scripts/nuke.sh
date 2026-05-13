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

echo "DANGER: This will force down the xcloud-infra stack."
echo "It will remove stack containers, named Docker volumes, orphan containers, and images referenced by this compose file."
echo
echo "Bind-mounted data directories under ${BASE} are preserved by default."
echo "To also purge bind-mounted app data, run:"
echo
echo "  PURGE_BIND_DATA=1 ${BASE}/scripts/nuke.sh"
echo
read -r -p "Type exactly 'NUKE xcloud-infra' to continue: " confirm

if [[ "${confirm}" != "NUKE xcloud-infra" ]]; then
  echo "Aborted."
  exit 1
fi

echo "Force removing stack containers, volumes, orphans, and compose images..."
compose down \
  --remove-orphans \
  --volumes \
  --rmi all \
  --timeout 60 || true

if [[ "${PURGE_BIND_DATA:-0}" == "1" ]]; then
  echo "PURGE_BIND_DATA=1 set. Removing bind-mounted app data..."
  rm -rf \
    "${BASE}/db/data"/* \
    "${BASE}/db/data"/.[!.]* \
    "${BASE}/db/data"/..?* \
    "${BASE}/redis/data"/* \
    "${BASE}/redis/data"/.[!.]* \
    "${BASE}/redis/data"/..?* \
    "${BASE}/authentik/media"/* \
    "${BASE}/authentik/media"/.[!.]* \
    "${BASE}/authentik/media"/..?* \
    "${BASE}/authentik/custom-templates"/* \
    "${BASE}/authentik/custom-templates"/.[!.]* \
    "${BASE}/authentik/custom-templates"/..?* \
    "${BASE}/authentik/certs"/* \
    "${BASE}/authentik/certs"/.[!.]* \
    "${BASE}/authentik/certs"/..?* \
    "${BASE}/teamspeak/data"/* \
    "${BASE}/teamspeak/data"/.[!.]* \
    "${BASE}/teamspeak/data"/..?* \
    "${BASE}/pgadmin/data"/* \
    "${BASE}/pgadmin/data"/.[!.]* \
    "${BASE}/pgadmin/data"/..?* \
    "${BASE}/dockge/data"/* \
    "${BASE}/dockge/data"/.[!.]* \
    "${BASE}/dockge/data"/..?* \
    2>/dev/null || true

  chown -R xcloud:xcloud \
    "${BASE}/db" \
    "${BASE}/redis" \
    "${BASE}/authentik" \
    "${BASE}/teamspeak" \
    "${BASE}/dockge"

  chown 5050:5050 "${BASE}/pgadmin/data"
fi

echo "Revalidating compose config..."
compose config >/dev/null

echo "Pulling fresh images..."
compose pull

echo "Recreating stack from scratch..."
"${BASE}/scripts/up.sh"
