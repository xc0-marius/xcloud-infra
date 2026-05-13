#!/usr/bin/env bash
set -Eeuo pipefail

BASE="${BASE:-/opt/xcloud-infra}"
STACK_USER="${STACK_USER:-xcloud}"
STACK_GROUP="${STACK_GROUP:-xcloud}"
TS_DATA="${BASE}/teamspeak/data"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo ${BASE}/scripts/fix_teamspeak_permissions.sh"
  exit 1
fi

if ! id "${STACK_USER}" >/dev/null 2>&1; then
  echo "User '${STACK_USER}' does not exist."
  exit 1
fi

install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0755 "${BASE}/teamspeak"
install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0777 "${TS_DATA}"

# TeamSpeak 6 beta container can run with an internal UID that is not known on the host.
# Keep the persistent data directory writable/traversable for that container user.
chmod 0755 "${BASE}/teamspeak"
chmod 0777 "${TS_DATA}"

# Existing generated files need to be accessible to the container as well.
find "${TS_DATA}" -type d -exec chmod 0777 {} +
find "${TS_DATA}" -type f -exec chmod 0666 {} +

# If tsserver.yaml exists but was left inaccessible, this repairs it. If it does not exist,
# the TeamSpeak container will create it on first successful startup.
if [[ -f "${TS_DATA}/tsserver.yaml" ]]; then
  chmod 0666 "${TS_DATA}/tsserver.yaml"
fi

echo "Repaired TeamSpeak data permissions at ${TS_DATA}."
