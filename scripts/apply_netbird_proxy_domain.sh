#!/usr/bin/env bash
set -Eeuo pipefail

BASE="${BASE:-/opt/xcloud-infra}"
ENV_FILE="${BASE}/.env"
PROXY_ENV="${BASE}/netbird/proxy.env"
PROXY_DOMAIN="${NETBIRD_PROXY_DOMAIN:-xc0.sh}"
MANAGEMENT_URL="${NETBIRD_MANAGEMENT_URL:-https://netbird.xcloud.gg:443}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}"
  exit 1
fi

get_env() {
  local key="$1"
  grep -E "^${key}=" "${ENV_FILE}" 2>/dev/null | tail -n 1 | cut -d '=' -f2- || true
}

TOKEN="$(get_env NETBIRD_PROXY_TOKEN)"
mkdir -p "${BASE}/netbird"

cat > "${PROXY_ENV}" <<EOF
NB_PROXY_DOMAIN=${PROXY_DOMAIN}
NB_PROXY_TOKEN=${TOKEN}
NB_PROXY_MANAGEMENT_ADDRESS=${MANAGEMENT_URL}
NB_PROXY_ADDRESS=:8443
NB_PROXY_ACME_CERTIFICATES=true
NB_PROXY_ACME_CHALLENGE_TYPE=tls-alpn-01
NB_PROXY_CERTIFICATE_DIRECTORY=/certs
NB_LOG_LEVEL=info
EOF

chmod 0640 "${PROXY_ENV}"
chown xcloud:xcloud "${PROXY_ENV}" 2>/dev/null || true

echo "Wrote ${PROXY_ENV} with NB_PROXY_DOMAIN=${PROXY_DOMAIN}"
