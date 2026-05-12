#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/opt/xcloud-infra"
STAGING_ACME_FILE="${BASE}/acme/acme-staging.json"

cd "${BASE}"

if [[ -d "${STAGING_ACME_FILE}" ]]; then
  echo "${STAGING_ACME_FILE} is a directory; remove it and rerun."
  exit 1
fi

if [[ ! -f "${STAGING_ACME_FILE}" ]]; then
  touch "${STAGING_ACME_FILE}"
fi

chown xcloud:xcloud "${STAGING_ACME_FILE}"
chmod 0600 "${STAGING_ACME_FILE}"

export COMPOSE_EXTRA_FILES="${BASE}/compose.staging.yml"
exec "${BASE}/scripts/up.sh"
