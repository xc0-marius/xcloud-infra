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
install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 netbird/config netbird/certs
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

get_env() {
  local key="$1"
  grep -E "^${key}=" "${ENV_FILE}" 2>/dev/null | tail -n 1 | cut -d '=' -f2- || true
}

needs_env() {
  local key="$1"
  local value
  value="$(get_env "${key}")"
  [[ -z "${value}" || "${value}" =~ ^change_me || "${value}" =~ ^CHANGE_ME || "${value}" =~ ^todo || "${value}" =~ ^TODO || "${value}" == "__GENERATE_ON_UP__" ]]
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

if needs_env NETBIRD_OWNER_EMAIL; then
  set_env NETBIRD_OWNER_EMAIL "$(ask_text "NetBird initial admin email" "admin@xcloud.gg")"
else
  echo "Preserved NETBIRD_OWNER_EMAIL."
fi

if needs_env NETBIRD_OWNER_PASSWORD; then
  echo "Enter NetBird initial admin password. Leave blank to generate a strong random value."
  netbird_owner_value="$(ask_hidden_twice "NetBird admin password")"
  if [[ -z "${netbird_owner_value}" ]]; then
    netbird_owner_value="$(rand_hex 24)"
    echo "Generated NETBIRD_OWNER_PASSWORD."
  else
    echo "Stored NETBIRD_OWNER_PASSWORD."
  fi
  set_env NETBIRD_OWNER_PASSWORD "${netbird_owner_value}"
  unset netbird_owner_value
else
  echo "Preserved NETBIRD_OWNER_PASSWORD."
fi

if needs_env NETBIRD_AUTH_SECRET; then
  set_env NETBIRD_AUTH_SECRET "$(rand_hex 32)"
  echo "Generated NETBIRD_AUTH_SECRET."
fi

if needs_env NETBIRD_STORE_ENCRYPTION_KEY; then
  set_env NETBIRD_STORE_ENCRYPTION_KEY "$(openssl rand -base64 32 | tr -d '\n')"
  echo "Generated NETBIRD_STORE_ENCRYPTION_KEY."
fi

if needs_env NETBIRD_IDP_SESSION_KEY; then
  set_env NETBIRD_IDP_SESSION_KEY "$(rand_hex 16)"
  echo "Generated NETBIRD_IDP_SESSION_KEY."
fi

if needs_env NETBIRD_PROXY_TOKEN; then
  set_env NETBIRD_PROXY_TOKEN "__GENERATE_ON_UP__"
  echo "Marked NETBIRD_PROXY_TOKEN for automatic generation by up.sh."
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

if [[ -d acme/acme.json ]]; then
  echo "acme/acme.json is a directory; remove it and rerun prepare.sh."
  exit 1
fi
if [[ ! -f acme/acme.json ]]; then
  install -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0600 /dev/null acme/acme.json
fi
chmod 0600 acme/acme.json
chown "${STACK_USER}:${STACK_GROUP}" acme/acme.json

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

netbird_owner_email="$(get_env NETBIRD_OWNER_EMAIL)"
netbird_owner_password="$(get_env NETBIRD_OWNER_PASSWORD)"
netbird_auth_secret="$(get_env NETBIRD_AUTH_SECRET)"
netbird_store_key="$(get_env NETBIRD_STORE_ENCRYPTION_KEY)"
netbird_session_key="$(get_env NETBIRD_IDP_SESSION_KEY)"

cat > netbird/config/config.yaml <<EOF
server:
  listenAddress: ":80"
  exposedAddress: "https://netbird.xcloud.gg:443"
  stunPorts:
    - 3478
  metricsPort: 9090
  healthcheckAddress: ":9000"
  logLevel: "info"
  logFile: "console"
  authSecret: "${netbird_auth_secret}"
  dataDir: "/var/lib/netbird/"
  disableAnonymousMetrics: true
  disableGeoliteUpdate: false

  auth:
    issuer: "https://netbird.xcloud.gg/oauth2"
    localAuthDisabled: false
    signKeyRefreshEnabled: true
    sessionCookieEncryptionKey: "${netbird_session_key}"
    dashboardRedirectURIs:
      - "https://netbird.xcloud.gg/nb-auth"
      - "https://netbird.xcloud.gg/nb-silent-auth"
    cliRedirectURIs:
      - "http://localhost:53000/"
    owner:
      email: "${netbird_owner_email}"
      password: "${netbird_owner_password}"

  store:
    engine: "sqlite"
    dsn: ""
    encryptionKey: "${netbird_store_key}"
EOF

cat > netbird/dashboard.env <<'EOF'
NETBIRD_MGMT_API_ENDPOINT=https://netbird.xcloud.gg
NETBIRD_MGMT_GRPC_API_ENDPOINT=https://netbird.xcloud.gg
AUTH_AUDIENCE=netbird-dashboard
AUTH_CLIENT_ID=netbird-dashboard
AUTH_CLIENT_SECRET=
AUTH_AUTHORITY=https://netbird.xcloud.gg/oauth2
USE_AUTH0=false
AUTH_SUPPORTED_SCOPES=openid profile email groups
AUTH_REDIRECT_URI=/nb-auth
AUTH_SILENT_REDIRECT_URI=/nb-silent-auth
NGINX_SSL_PORT=443
LETSENCRYPT_DOMAIN=none
LETSENCRYPT_EMAIL=admin@xcloud.gg
EOF

proxy_token="$(get_env NETBIRD_PROXY_TOKEN)"
cat > netbird/proxy.env <<EOF
NB_PROXY_DOMAIN=netbird.xcloud.gg
NB_PROXY_TOKEN=${proxy_token}
NB_PROXY_MANAGEMENT_ADDRESS=http://netbird-server:80
NB_PROXY_ALLOW_INSECURE=true
NB_PROXY_ADDRESS=:8443
NB_PROXY_ACME_CERTIFICATES=true
NB_PROXY_ACME_CHALLENGE_TYPE=tls-alpn-01
NB_PROXY_CERTIFICATE_DIRECTORY=/certs
NB_PROXY_FORWARDED_PROTO=https
NB_LOG_LEVEL=info
EOF

unset netbird_owner_password netbird_auth_secret netbird_store_key netbird_session_key proxy_token

chown -R "${STACK_USER}:${STACK_GROUP}" \
  acme traefik db redis authentik netbird teamspeak dockge scripts compose.yml .env.example

chown "${STACK_USER}:${STACK_GROUP}" "${ENV_FILE}"
chown -R 5050:5050 pgadmin/data

find . -type d -not -path './.git*' -exec chmod 0750 {} +
find . -type f -not -path './.git*' -exec chmod 0640 {} +
find scripts -type f -name '*.sh' -exec chmod 0750 {} +
chmod 0600 acme/acme.json
chmod 0640 "${AUTH_USERS_FILE}" "${ENV_FILE}"

if command -v docker >/dev/null 2>&1; then
  docker compose --env-file "${ENV_FILE}" -f compose.yml config >/dev/null
fi

echo
echo "Prepared ${BASE}."
echo "Generated .env values, NetBird config/env files, Traefik dynamic config, and ACME state file."
echo "Next command can be: ${BASE}/scripts/up.sh"
