#!/usr/bin/env bash
set -Eeuo pipefail

BASE="${1:-/opt/xcloud-infra}"
STACK_USER="${STACK_USER:-xcloud}"
STACK_GROUP="${STACK_GROUP:-xcloud}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo ./scripts/prepare.sh"
  exit 1
fi

if ! id "${STACK_USER}" >/dev/null 2>&1; then
  echo "User '${STACK_USER}' does not exist. Set STACK_USER/STACK_GROUP or create the user first."
  exit 1
fi

cd "${BASE}"

install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 acme traefik scripts
install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 db/data redis/data
install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 authentik/media authentik/custom-templates authentik/certs
install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 netbird/config
install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 teamspeak/data pgadmin/data dockge/data

if [[ ! -f .env ]]; then
  cp .env.example .env
  chown "${STACK_USER}:${STACK_GROUP}" .env
  chmod 0640 .env
  echo "Created .env from .env.example. Edit it before running up.sh."
fi

if [[ ! -f acme/acme.json ]]; then
  touch acme/acme.json
fi
chown "${STACK_USER}:${STACK_GROUP}" acme/acme.json
chmod 0600 acme/acme.json

if [[ ! -f traefik/traefik-dynamic.yaml ]]; then
  cat > traefik/traefik-dynamic.yaml <<'EOF'
# Optional Traefik dynamic config.
# Add middlewares, TLS options, headers, or IP allowlists here.
EOF
fi

if [[ ! -f netbird/config/config.yaml ]]; then
  cat > netbird/config/config.yaml <<'EOF'
# TODO: Replace this placeholder with your real NetBird management config.
# Public management URL: https://netbird.xcloud.gg
# VPS public IP: 46.225.19.105
EOF
fi

if [[ ! -f netbird/dashboard.env ]]; then
  cat > netbird/dashboard.env <<'EOF'
# TODO: Fill with your NetBird dashboard environment.
# Public URL: https://netbird.xcloud.gg
# Authentik URL: https://auth.xcloud.gg
EOF
fi

if [[ ! -f netbird/proxy.env ]]; then
  cat > netbird/proxy.env <<'EOF'
# TODO: Fill with your NetBird reverse-proxy environment.
# Expected DNS: *.netbird.xcloud.gg -> 46.225.19.105
EOF
fi

chown -R "${STACK_USER}:${STACK_GROUP}" \
  acme traefik db redis authentik netbird teamspeak dockge scripts compose.yml .env.example

if [[ -f .env ]]; then
  chown "${STACK_USER}:${STACK_GROUP}" .env
  chmod 0640 .env
fi

chown -R 5050:5050 pgadmin/data
chmod 0750 scripts/*.sh
chmod 0640 compose.yml .env.example
chmod 0640 traefik/traefik-dynamic.yaml netbird/config/config.yaml netbird/dashboard.env netbird/proxy.env
chmod 0600 acme/acme.json

echo "Prepared ${BASE}."
echo "Next: edit ${BASE}/.env and NetBird config/env files, then run ${BASE}/scripts/up.sh"
