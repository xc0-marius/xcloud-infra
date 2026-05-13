#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# xcloud-infra repair utility
# =========================================================
# Safely repairs local runtime files, permissions, and generated
# service config for the xCloud stack.
# =========================================================

BASE="${BASE:-/opt/xcloud-infra}"
STACK_USER="${STACK_USER:-xcloud}"
STACK_GROUP="${STACK_GROUP:-xcloud}"
POSTGRES_UID="${POSTGRES_UID:-70}"
POSTGRES_GID="${POSTGRES_GID:-70}"
REDIS_UID="${REDIS_UID:-999}"
REDIS_GID="${REDIS_GID:-999}"
ENV_FILE="${BASE}/.env"
AUTH_USERS_FILE="${BASE}/traefik/basic-auth.users"
ROTATE_SECRETS=0
NON_INTERACTIVE=0

usage() {
  cat <<'EOF'
Usage: sudo scripts/fix.sh [options]

Options:
  --rotate-secrets    Regenerate local secrets in .env. This can break existing sessions and integrations.
  --non-interactive   Do not prompt. Missing required prompt-only values will fail unless already set.
  -h, --help          Show this help.

Environment:
  BASE=/opt/xcloud-infra
  STACK_USER=xcloud
  STACK_GROUP=xcloud
  POSTGRES_UID=70
  POSTGRES_GID=70
  REDIS_UID=999
  REDIS_GID=999
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rotate-secrets) ROTATE_SECRETS=1; shift ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

log() { printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing command '$1'. Install with: $2"; }
random_hex() { openssl rand -hex "${1:-32}"; }
random_b64() { openssl rand -base64 "${1:-48}" | tr -d '\n'; }

ask_text() {
  local label="$1" default_value="${2:-}" value=""
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then printf '%s' "${default_value}"; return 0; fi
  if [[ -n "${default_value}" ]]; then read -r -p "${label} [${default_value}]: " value; printf '%s' "${value:-${default_value}}"; else read -r -p "${label}: " value; printf '%s' "${value}"; fi
}

ask_secret() {
  local label="$1" value=""
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then return 1; fi
  read -r -s -p "${label}: " value; echo >&2; printf '%s' "${value}"
}

ask_secret_twice() {
  local label="$1" first="" second=""
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then return 1; fi
  while true; do
    first="$(ask_secret "${label}")"
    second="$(ask_secret "Confirm ${label}")"
    if [[ "${first}" == "${second}" ]]; then printf '%s' "${first}"; return 0; fi
    echo "Values did not match. Try again."
  done
}

set_env() {
  local key="$1" value="$2" tmp=""
  tmp="$(mktemp)"
  awk -v key="${key}" -v value="${value}" 'BEGIN { found = 0 } $0 ~ "^" key "=" { print key "=" value; found = 1; next } { print } END { if (found == 0) print key "=" value }' "${ENV_FILE}" > "${tmp}"
  cat "${tmp}" > "${ENV_FILE}"
  rm -f "${tmp}"
}

get_env() {
  local key="$1"
  grep -E "^${key}=" "${ENV_FILE}" 2>/dev/null | tail -n 1 | cut -d '=' -f2- || true
}

is_placeholder() {
  local value="$1"
  [[ -z "${value}" || "${value}" =~ ^change_me || "${value}" =~ ^CHANGE_ME || "${value}" =~ ^todo || "${value}" =~ ^TODO || "${value}" == "__GENERATE_ON_UP__" ]]
}

ensure_env_value() {
  local key="$1" value="$2" existing=""
  existing="$(get_env "${key}")"
  if [[ "${ROTATE_SECRETS}" -eq 1 || $(is_placeholder "${existing}"; echo $?) -eq 0 ]]; then set_env "${key}" "${value}"; log "Set ${key}."; else log "Preserved ${key}."; fi
}

ensure_prompt_value() {
  local key="$1" label="$2" default_value="${3:-}" existing="" value=""
  existing="$(get_env "${key}")"
  if [[ "${ROTATE_SECRETS}" -ne 1 && ! $(is_placeholder "${existing}"; echo $?) -eq 0 ]]; then log "Preserved ${key}."; return 0; fi
  value="$(ask_text "${label}" "${default_value}")"
  [[ -z "${value}" ]] && fail "${key} cannot be empty."
  set_env "${key}" "${value}"
  log "Set ${key}."
}

ensure_required_secret_prompt() {
  local key="$1" label="$2" existing="" value=""
  existing="$(get_env "${key}")"
  if [[ "${ROTATE_SECRETS}" -ne 1 && ! $(is_placeholder "${existing}"; echo $?) -eq 0 ]]; then log "Preserved ${key}."; return 0; fi
  value="$(ask_secret "${label}" || true)"
  [[ -z "${value}" ]] && fail "${key} is required."
  set_env "${key}" "${value}"
  log "Set ${key}."
}

require_root_and_tools() {
  [[ "${EUID}" -eq 0 ]] || fail "Run with sudo: sudo ${BASE}/scripts/fix.sh"
  id "${STACK_USER}" >/dev/null 2>&1 || fail "User '${STACK_USER}' does not exist."
  getent group "${STACK_GROUP}" >/dev/null 2>&1 || fail "Group '${STACK_GROUP}' does not exist."
  need_cmd openssl "sudo apt-get update && sudo apt-get install -y openssl"
  need_cmd htpasswd "sudo apt-get update && sudo apt-get install -y apache2-utils"
  need_cmd awk "sudo apt-get update && sudo apt-get install -y gawk"
}

create_directories() {
  log "Creating required directory structure..."
  install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 \
    "${BASE}" "${BASE}/scripts" "${BASE}/acme" "${BASE}/traefik" \
    "${BASE}/db" "${BASE}/redis" \
    "${BASE}/authentik/media" "${BASE}/authentik/custom-templates" "${BASE}/authentik/certs" \
    "${BASE}/netbird/config" "${BASE}/netbird/certs" \
    "${BASE}/teamspeak/data" "${BASE}/pgadmin/data" "${BASE}/dockge/data" \
    "${BASE}/logs" "${BASE}/backups"
  install -d -o "${POSTGRES_UID}" -g "${POSTGRES_GID}" -m 0700 "${BASE}/db/data"
  install -d -o "${REDIS_UID}" -g "${REDIS_GID}" -m 0700 "${BASE}/redis/data"
}

ensure_env_file() {
  log "Checking .env..."
  if [[ ! -f "${ENV_FILE}" ]]; then
    if [[ -f "${BASE}/.env.example" ]]; then cp "${BASE}/.env.example" "${ENV_FILE}"; log "Created .env from .env.example."; else
      cat > "${ENV_FILE}" <<'EOF'
PUBLIC_IP=46.225.19.105
BASE_DOMAIN=xcloud.gg
TZ=Europe/Oslo
PG_PASS=change_me
AUTHENTIK_SECRET_KEY=change_me
DESEC_TOKEN=change_me
PGADMIN_DEFAULT_EMAIL=admin@xcloud.gg
PGADMIN_DEFAULT_PASSWORD=change_me
NETBIRD_OWNER_EMAIL=admin@xcloud.gg
NETBIRD_OWNER_PASSWORD=change_me
NETBIRD_AUTH_SECRET=change_me
NETBIRD_STORE_ENCRYPTION_KEY=change_me
NETBIRD_IDP_SESSION_KEY=change_me
NETBIRD_PROXY_TOKEN=__GENERATE_ON_UP__
EOF
      log "Created minimal .env."
    fi
  fi
  chown "${STACK_USER}:${STACK_GROUP}" "${ENV_FILE}"
  chmod 0640 "${ENV_FILE}"
}

repair_env_values() {
  log "Repairing .env values..."
  set_env PUBLIC_IP "46.225.19.105"
  set_env BASE_DOMAIN "xcloud.gg"
  set_env TZ "Europe/Oslo"
  ensure_env_value PG_PASS "$(random_hex 32)"
  ensure_env_value AUTHENTIK_SECRET_KEY "$(random_b64 48)"
  ensure_prompt_value PGADMIN_DEFAULT_EMAIL "pgAdmin login email" "admin@xcloud.gg"

  if [[ "${ROTATE_SECRETS}" -eq 1 || $(is_placeholder "$(get_env PGADMIN_DEFAULT_PASSWORD)"; echo $?) -eq 0 ]]; then
    log "Enter pgAdmin password, or leave blank to generate a strong random password."
    pgadmin_pw="$(ask_secret_twice "pgAdmin password" || true)"
    [[ -z "${pgadmin_pw}" ]] && pgadmin_pw="$(random_hex 24)" && log "Generated PGADMIN_DEFAULT_PASSWORD."
    set_env PGADMIN_DEFAULT_PASSWORD "${pgadmin_pw}"
    unset pgadmin_pw
  else log "Preserved PGADMIN_DEFAULT_PASSWORD."; fi

  ensure_required_secret_prompt DESEC_TOKEN "deSEC API token"
  ensure_prompt_value NETBIRD_OWNER_EMAIL "NetBird setup email" "admin@xcloud.gg"

  if [[ "${ROTATE_SECRETS}" -eq 1 || $(is_placeholder "$(get_env NETBIRD_OWNER_PASSWORD)"; echo $?) -eq 0 ]]; then
    log "Enter NetBird setup password, or leave blank to generate a strong random password."
    nb_pw="$(ask_secret_twice "NetBird setup password" || true)"
    [[ -z "${nb_pw}" ]] && nb_pw="$(random_hex 24)" && log "Generated NETBIRD_OWNER_PASSWORD."
    set_env NETBIRD_OWNER_PASSWORD "${nb_pw}"
    unset nb_pw
  else log "Preserved NETBIRD_OWNER_PASSWORD."; fi

  ensure_env_value NETBIRD_AUTH_SECRET "$(random_hex 32)"
  ensure_env_value NETBIRD_STORE_ENCRYPTION_KEY "$(openssl rand -base64 32 | tr -d '\n')"
  ensure_env_value NETBIRD_IDP_SESSION_KEY "$(random_hex 16)"

  if [[ "${ROTATE_SECRETS}" -eq 1 || $(is_placeholder "$(get_env NETBIRD_PROXY_TOKEN)"; echo $?) -eq 0 ]]; then set_env NETBIRD_PROXY_TOKEN "__GENERATE_ON_UP__"; log "Marked NETBIRD_PROXY_TOKEN for generation by up.sh."; else log "Preserved NETBIRD_PROXY_TOKEN."; fi
  chmod 0640 "${ENV_FILE}"
}

repair_acme_files() {
  log "Repairing ACME state files..."
  for acme_file in "${BASE}/acme/acme.json" "${BASE}/acme/acme-staging.json"; do
    [[ -d "${acme_file}" ]] && fail "${acme_file} is a directory. Remove it manually and rerun fix.sh."
    [[ ! -f "${acme_file}" ]] && install -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0600 /dev/null "${acme_file}"
    chown "${STACK_USER}:${STACK_GROUP}" "${acme_file}"
    chmod 0600 "${acme_file}"
  done
}

repair_traefik_files() {
  log "Repairing Traefik dynamic config and Basic Auth users file..."
  if [[ ! -f "${AUTH_USERS_FILE}" || "${ROTATE_SECRETS}" -eq 1 ]]; then
    basic_user="$(ask_text "Basic Auth username for pgAdmin and Dockge" "xcloud")"
    basic_pw="$(ask_secret_twice "Basic Auth password" || true)"
    [[ -z "${basic_pw}" ]] && fail "Basic Auth password cannot be empty."
    printf '%s\n' "${basic_pw}" | htpasswd -B -C 12 -n -i "${basic_user}" > "${AUTH_USERS_FILE}"
    unset basic_pw
    log "Generated Traefik Basic Auth users file."
  else log "Preserved existing Traefik Basic Auth users file."; fi

  cat > "${BASE}/traefik/traefik-dynamic.yaml" <<'EOF'
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
  chown "${STACK_USER}:${STACK_GROUP}" "${AUTH_USERS_FILE}" "${BASE}/traefik/traefik-dynamic.yaml"
  chmod 0640 "${AUTH_USERS_FILE}" "${BASE}/traefik/traefik-dynamic.yaml"
}

repair_postgres_runtime_dir() {
  log "Repairing PostgreSQL runtime directory..."
  find "${BASE}/db/data" -mindepth 1 -maxdepth 1 -name '.gitkeep' -delete || true
  chown "${STACK_USER}:${STACK_GROUP}" "${BASE}/db"
  chmod 0750 "${BASE}/db"
  chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "${BASE}/db/data"
  chmod 0700 "${BASE}/db/data"
}

repair_redis_runtime_dir() {
  log "Repairing Redis runtime directory..."
  find "${BASE}/redis/data" -mindepth 1 -maxdepth 1 -name '.gitkeep' -delete || true
  chown "${STACK_USER}:${STACK_GROUP}" "${BASE}/redis"
  chmod 0750 "${BASE}/redis"
  chown -R "${REDIS_UID}:${REDIS_GID}" "${BASE}/redis/data"
  chmod 0700 "${BASE}/redis/data"
}

write_netbird_config() {
  log "Repairing NetBird config and env files..."
  nb_auth_secret="$(get_env NETBIRD_AUTH_SECRET)"
  nb_store_key="$(get_env NETBIRD_STORE_ENCRYPTION_KEY)"
  nb_session_key="$(get_env NETBIRD_IDP_SESSION_KEY)"
  nb_proxy_token="$(get_env NETBIRD_PROXY_TOKEN)"

  cat > "${BASE}/netbird/config/config.yaml" <<EOF
server:
  listenAddress: ":80"
  exposedAddress: "https://netbird.xcloud.gg:443"
  stunPorts:
    - 3478
  metricsPort: 9090
  healthcheckAddress: ":9000"
  logLevel: "info"
  logFile: "console"
  authSecret: "${nb_auth_secret}"
  dataDir: "/var/lib/netbird/"
  disableAnonymousMetrics: true
  disableGeoliteUpdate: false

  auth:
    issuer: "https://netbird.xcloud.gg/oauth2"
    localAuthDisabled: false
    signKeyRefreshEnabled: true
    sessionCookieEncryptionKey: "${nb_session_key}"
    dashboardRedirectURIs:
      - "https://netbird.xcloud.gg/nb-auth"
      - "https://netbird.xcloud.gg/nb-silent-auth"
    cliRedirectURIs:
      - "http://localhost:53000/"

  store:
    engine: "sqlite"
    dsn: ""
    encryptionKey: "${nb_store_key}"
EOF

  cat > "${BASE}/netbird/dashboard.env" <<'EOF'
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

  cat > "${BASE}/netbird/proxy.env" <<EOF
NB_PROXY_DOMAIN=netbird.xcloud.gg
NB_PROXY_TOKEN=${nb_proxy_token}
NB_PROXY_MANAGEMENT_ADDRESS=https://netbird.xcloud.gg:443
NB_PROXY_ADDRESS=:8443
NB_PROXY_ACME_CERTIFICATES=true
NB_PROXY_ACME_CHALLENGE_TYPE=tls-alpn-01
NB_PROXY_CERTIFICATE_DIRECTORY=/certs
NB_LOG_LEVEL=info
EOF
  unset nb_auth_secret nb_store_key nb_session_key nb_proxy_token
  chown -R "${STACK_USER}:${STACK_GROUP}" "${BASE}/netbird"
  chmod 0750 "${BASE}/netbird" "${BASE}/netbird/config" "${BASE}/netbird/certs"
  chmod 0640 "${BASE}/netbird/config/config.yaml" "${BASE}/netbird/dashboard.env" "${BASE}/netbird/proxy.env"
}

repair_permissions() {
  log "Repairing ownership and permissions..."
  chown -R "${STACK_USER}:${STACK_GROUP}" \
    "${BASE}/acme" "${BASE}/traefik" "${BASE}/authentik" \
    "${BASE}/netbird" "${BASE}/teamspeak" "${BASE}/dockge" \
    "${BASE}/logs" "${BASE}/backups" "${BASE}/scripts" || true

  [[ -f "${BASE}/compose.yml" ]] && chown "${STACK_USER}:${STACK_GROUP}" "${BASE}/compose.yml"
  [[ -f "${BASE}/compose.staging.yml" ]] && chown "${STACK_USER}:${STACK_GROUP}" "${BASE}/compose.staging.yml"
  [[ -f "${BASE}/.env.example" ]] && chown "${STACK_USER}:${STACK_GROUP}" "${BASE}/.env.example"

  repair_postgres_runtime_dir
  repair_redis_runtime_dir

  chown -R 5050:5050 "${BASE}/pgadmin/data" || true

  find "${BASE}" -path "${BASE}/.git" -prune -o -path "${BASE}/db/data" -prune -o -path "${BASE}/redis/data" -prune -o -type d -exec chmod 0750 {} +
  find "${BASE}" -path "${BASE}/.git" -prune -o -path "${BASE}/db/data" -prune -o -path "${BASE}/redis/data" -prune -o -type f -exec chmod 0640 {} +
  find "${BASE}/scripts" -type f -name '*.sh' -exec chmod 0750 {} +
  chmod 0640 "${ENV_FILE}"
  chmod 0600 "${BASE}/acme/acme.json" "${BASE}/acme/acme-staging.json"
  chmod 0640 "${AUTH_USERS_FILE}" "${BASE}/traefik/traefik-dynamic.yaml"
}

validate_compose() {
  if command -v docker >/dev/null 2>&1; then
    log "Validating production compose config..."
    docker compose --env-file "${ENV_FILE}" -f "${BASE}/compose.yml" config >/dev/null
    if [[ -f "${BASE}/compose.staging.yml" ]]; then
      log "Validating staging compose config..."
      docker compose --env-file "${ENV_FILE}" -f "${BASE}/compose.yml" -f "${BASE}/compose.staging.yml" config >/dev/null
    fi
    log "Docker Compose validation successful."
  else log "Docker is not installed or not in PATH; skipped Compose validation."; fi
}

main() {
  require_root_and_tools
  [[ -d "${BASE}" ]] || fail "Base directory does not exist: ${BASE}"
  [[ "${ROTATE_SECRETS}" -eq 1 ]] && log "WARNING: --rotate-secrets is enabled. Existing credentials may stop working."
  create_directories
  ensure_env_file
  repair_env_values
  repair_acme_files
  repair_traefik_files
  repair_postgres_runtime_dir
  repair_redis_runtime_dir
  write_netbird_config
  repair_permissions
  validate_compose
  log "xcloud-infra repair complete."
  log "Next safe command: ${BASE}/scripts/up.sh or ${BASE}/scripts/up_staging.sh"
}

main "$@"
