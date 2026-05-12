#!/usr/bin/env bash
set -Eeuo pipefail

BASE="${1:-/opt/xcloud-infra}"
STACK_USER="${STACK_USER:-xcloud}"
STACK_GROUP="${STACK_GROUP:-xcloud}"
ENV_FILE="${BASE}/.env"
AUTH_USERS_FILE="${BASE}/traefik/basic-auth.users"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo ./scripts/prepare.sh"
  exit 1
fi

if ! id "${STACK_USER}" >/dev/null 2>&1; then
  echo "User '${STACK_USER}' does not exist. Set STACK_USER/STACK_GROUP or create the user first."
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    echo "Install with: $2"
    exit 1
  fi
}

need_cmd openssl "sudo apt-get update && sudo apt-get install -y openssl"
need_cmd htpasswd "sudo apt-get update && sudo apt-get install -y apache2-utils"

cd "${BASE}"

install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 acme traefik scripts
install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 db/data redis/data
install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 authentik/media authentik/custom-templates authentik/certs
install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 netbird/config
install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 teamspeak/data pgadmin/data dockge/data

if [[ ! -f "${ENV_FILE}" ]]; then
  cp .env.example "${ENV_FILE}"
  echo "Created .env from .env.example."
fi

set_env() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { found = 0 }
    $0 ~ "^" key "=" { print key "=" value; found = 1; next }
    { print }
    END { if (found == 0) print key "=" value }
  ' "${ENV_FILE}" > "${tmp}"
  cat "${tmp}" > "${ENV_FILE}"
  rm -f "${tmp}"
}

needs_env() {
  local key="$1"
  local value
  value="$(grep -E "^${key}=" "${ENV_FILE}" 2>/dev/null | tail -n 1 | cut -d '=' -f2- || true)"
  [[ -z "${value}" || "${value}" =~ ^change_me || "${value}" =~ ^CHANGE_ME || "${value}" =~ ^todo || "${value}" =~ ^TODO ]]
}

rand_hex() { openssl rand -hex "${1:-32}"; }
rand_b64() { openssl rand -base64 "${1:-48}" | tr -d '\n'; }

ask_text() {
  local label="$1"
  local default_value="${2:-}"
  local answer=""
  if [[ -n "${default_value}" ]]; then
    read -r -p "${label} [${default_value}]: " answer
    printf '%s' "${answer:-${default_value}}"
  else
    read -r -p "${label}: " answer
    printf '%s' "${answer}"
  fi
}

ask_hidden() {
  local label="$1"
  local answer=""
  read -r -s -p "${label}: " answer
  echo >&2
  printf '%s' "${answer}"
}

ask_hidden_twice() {
  local label="$1"
  local first=""
  local second=""
  while true; do
    first="$(ask_hidden "${label}")"
    second="$(ask_hidden "Confirm ${label}")"
    if [[ "${first}" == "${second}" ]]; then
      printf '%s' "${first}"
      return 0
    fi
    echo "Values did not match. Try again."
  done
}

echo
echo "Preparing xCloud infra runtime files and local secrets."
echo "Existing non-placeholder .env values are preserved."
echo

set_env PUBLIC_IP "46.225.19.105"
set_env BASE_DOMAIN "xcloud.gg"
set_env TZ "Europe/Oslo"

if needs_env PG_PASS; then
  set_env PG_PASS "$(rand_hex 32)"
  echo "Generated PG_PASS."
else
  echo "Preserved PG_PASS."
fi

if needs_env AUTHENTIK_SECRET_KEY; then
  set_env AUTHENTIK_SECRET_KEY "$(rand_b64 48)"
  echo "Generated AUTHENTIK_SECRET_KEY."
else
  echo "Preserved AUTHENTIK_SECRET_KEY."
fi

if needs_env PGADMIN_DEFAULT_EMAIL; then
  set_env PGADMIN_DEFAULT_EMAIL "$(ask_text "pgAdmin login email" "admin@xcloud.gg")"
else
  echo "Preserved PGADMIN_DEFAULT_EMAIL."
fi

if needs_env PGADMIN_DEFAULT_PASSWORD; then
  echo "Enter pgAdmin login password. Leave blank to generate a strong random value."
  pgadmin_value="$(ask_hidden_twice "pgAdmin password")"
  if [[ -z "${pgadmin_value}" ]]; then
    pgadmin_value="$(rand_hex 24)"
    echo "Generated PGADMIN_DEFAULT_PASSWORD."
  else
    echo "Stored PGADMIN_DEFAULT_PASSWORD."
  fi
  set_env PGADMIN_DEFAULT_PASSWORD "${pgadmin_value}"
  unset pgadmin_value
else
  echo "Preserved PGADMIN_DEFAULT_PASSWORD."
fi

if needs_env DESEC_TOKEN; then
  desec_value="$(ask_hidden "deSEC API token")"
  if [[ -z "${desec_value}" ]]; then
    echo "DESEC_TOKEN cannot be empty."
    exit 1
  fi
  set_env DESEC_TOKEN "${desec_value}"
  unset desec_value
else
  echo "Preserved DESEC_TOKEN."
fi

echo
admin_user="$(ask_text "Basic Auth username for pgAdmin and Dockge" "xcloud")"
admin_secret="$(ask_hidden_twice "Basic Auth password")"
if [[ -z "${admin_secret}" ]]; then
  echo "Basic Auth password cannot be empty."
  exit 1
fi
printf '%s\n' "${admin_secret}" | htpasswd -B -C 12 -n -i "${admin_user}" > "${AUTH_USERS_FILE}"
unset admin_secret

echo "Created ${AUTH_USERS_FILE}."

if [[ ! -f acme/acme.json ]]; then
  touch acme/acme.json
fi

cat > traefik/traefik-dynamic.yaml <<'EOF'
http:
  middlewares:
    xcloud-basic-auth:
      basicAuth:
        usersFile: /etc/traefik/basic-auth.users

    secure-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        frameDeny: true
        contentTypeNosniff: true
EOF

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

chown "${STACK_USER}:${STACK_GROUP}" "${ENV_FILE}"
chown -R 5050:5050 pgadmin/data

chmod 0750 scripts/*.sh
chmod 0640 compose.yml .env.example "${ENV_FILE}"
chmod 0640 traefik/traefik-dynamic.yaml "${AUTH_USERS_FILE}"
chmod 0640 netbird/config/config.yaml netbird/dashboard.env netbird/proxy.env
chmod 0600 acme/acme.json

echo
echo "Prepared ${BASE}."
echo "Updated ${ENV_FILE}."
echo "Created Traefik Basic Auth users file at ${AUTH_USERS_FILE}."
echo "Next: fill real NetBird config/env files, then run ${BASE}/scripts/up.sh"
