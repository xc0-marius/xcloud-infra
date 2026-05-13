#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# xcloud-infra fresh deployment reset
# =========================================================
# Destroys local generated/runtime state and Docker state for this stack,
# while preserving the Git-tracked repository files.
#
# Removes:
#   - compose containers and orphans
#   - compose named volumes
#   - generated .env and service env/config files
#   - ACME state files
#   - Basic Auth users file
#   - bind-mounted runtime data contents, including dotfiles
#   - stale lock files
#
# Preserves:
#   - compose.yml / compose.staging.yml
#   - scripts/
#   - README and tracked examples
#   - .git repository
#
# Usage:
#   sudo /opt/xcloud-infra/scripts/reset_fresh.sh
#   sudo /opt/xcloud-infra/scripts/reset_fresh.sh --yes
#
# After:
#   sudo ./scripts/prepare.sh
#   ./scripts/up_staging.sh
# =========================================================

BASE="${BASE:-/opt/xcloud-infra}"
STACK_USER="${STACK_USER:-xcloud}"
STACK_GROUP="${STACK_GROUP:-xcloud}"
YES=0

usage() {
  cat <<'EOF'
Usage: sudo scripts/reset_fresh.sh [--yes]

Options:
  --yes       Skip confirmation prompt.
  -h, --help  Show help.

Environment:
  BASE=/opt/xcloud-infra
  STACK_USER=xcloud
  STACK_GROUP=xcloud
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)
      YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

log() {
  printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

remove_contents() {
  local dir="$1"

  [[ -d "${dir}" ]] || return 0

  find "${dir}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Run with sudo: sudo ${BASE}/scripts/reset_fresh.sh"
  [[ -d "${BASE}" ]] || fail "Base directory does not exist: ${BASE}"
  [[ -f "${BASE}/compose.yml" ]] || fail "compose.yml not found in ${BASE}; refusing to continue."
  id "${STACK_USER}" >/dev/null 2>&1 || fail "User '${STACK_USER}' does not exist."
  getent group "${STACK_GROUP}" >/dev/null 2>&1 || fail "Group '${STACK_GROUP}' does not exist."
}

confirm() {
  if [[ "${YES}" -eq 1 ]]; then
    return 0
  fi

  echo "DANGER: This will remove local generated/runtime state for ${BASE}."
  echo
  echo "It removes Docker containers, named volumes, .env, ACME files, generated NetBird files,"
  echo "Traefik Basic Auth users file, and all bind-mounted app data contents."
  echo
  echo "It preserves the Git repo, compose files, scripts, README, and example files."
  echo
  read -r -p "Type exactly 'RESET xcloud-infra' to continue: " answer

  [[ "${answer}" == "RESET xcloud-infra" ]] || fail "Aborted."
}

compose_down_and_remove_volumes() {
  cd "${BASE}"

  if command -v docker >/dev/null 2>&1; then
    log "Removing compose containers, orphans, and named volumes..."

    if [[ -f "${BASE}/.env" ]]; then
      docker compose --env-file "${BASE}/.env" -f "${BASE}/compose.yml" down --remove-orphans --volumes --timeout 60 || true
      if [[ -f "${BASE}/compose.staging.yml" ]]; then
        docker compose --env-file "${BASE}/.env" -f "${BASE}/compose.yml" -f "${BASE}/compose.staging.yml" down --remove-orphans --volumes --timeout 60 || true
      fi
    else
      docker compose -f "${BASE}/compose.yml" down --remove-orphans --volumes --timeout 60 || true
      if [[ -f "${BASE}/compose.staging.yml" ]]; then
        docker compose -f "${BASE}/compose.yml" -f "${BASE}/compose.staging.yml" down --remove-orphans --volumes --timeout 60 || true
      fi
    fi

    log "Pruning known stack volumes if any remain..."
    for volume_name in \
      xcloud-infra_netbird_data \
      xcloud-infra_netbird_proxy_certs \
      netbird_data \
      netbird_proxy_certs; do
      docker volume rm "${volume_name}" >/dev/null 2>&1 || true
    done
  else
    log "Docker not found; skipped Docker cleanup."
  fi
}

remove_generated_files() {
  log "Removing generated local files..."

  rm -f \
    "${BASE}/.env" \
    "${BASE}/.xcloud-infra-stack.lock" \
    "/tmp/xcloud-infra-stack.lock" \
    "${BASE}/acme/acme.json" \
    "${BASE}/acme/acme-staging.json" \
    "${BASE}/traefik/basic-auth.users" \
    "${BASE}/traefik/traefik-dynamic.yaml" \
    "${BASE}/netbird/config/config.yaml" \
    "${BASE}/netbird/dashboard.env" \
    "${BASE}/netbird/proxy.env"
}

remove_runtime_data() {
  log "Removing bind-mounted runtime data contents..."

  remove_contents "${BASE}/db/data"
  remove_contents "${BASE}/redis/data"
  remove_contents "${BASE}/authentik/media"
  remove_contents "${BASE}/authentik/custom-templates"
  remove_contents "${BASE}/authentik/certs"
  remove_contents "${BASE}/netbird/certs"
  remove_contents "${BASE}/teamspeak/data"
  remove_contents "${BASE}/pgadmin/data"
  remove_contents "${BASE}/dockge/data"
  remove_contents "${BASE}/logs"
  remove_contents "${BASE}/backups"
}

recreate_base_structure() {
  log "Recreating clean directory structure..."

  install -d -o "${STACK_USER}" -g "${STACK_GROUP}" -m 0750 \
    "${BASE}/acme" \
    "${BASE}/traefik" \
    "${BASE}/db/data" \
    "${BASE}/redis/data" \
    "${BASE}/authentik/media" \
    "${BASE}/authentik/custom-templates" \
    "${BASE}/authentik/certs" \
    "${BASE}/netbird/config" \
    "${BASE}/netbird/certs" \
    "${BASE}/teamspeak/data" \
    "${BASE}/pgadmin/data" \
    "${BASE}/dockge/data" \
    "${BASE}/logs" \
    "${BASE}/backups" \
    "${BASE}/scripts"

  chown -R "${STACK_USER}:${STACK_GROUP}" \
    "${BASE}/acme" \
    "${BASE}/traefik" \
    "${BASE}/db" \
    "${BASE}/redis" \
    "${BASE}/authentik" \
    "${BASE}/netbird" \
    "${BASE}/teamspeak" \
    "${BASE}/dockge" \
    "${BASE}/logs" \
    "${BASE}/backups" \
    "${BASE}/scripts"

  chown -R 5050:5050 "${BASE}/pgadmin/data" || true

  find "${BASE}" -path "${BASE}/.git" -prune -o -type d -exec chmod 0750 {} +
  find "${BASE}" -path "${BASE}/.git" -prune -o -type f -exec chmod 0640 {} +
  find "${BASE}/scripts" -type f -name '*.sh' -exec chmod 0750 {} +

  chown "${STACK_USER}:${STACK_GROUP}" "${BASE}" || true
}

main() {
  require_root
  confirm
  compose_down_and_remove_volumes
  remove_generated_files
  remove_runtime_data
  recreate_base_structure

  log "Fresh reset complete."
  log "Next commands:"
  log "  cd ${BASE}"
  log "  sudo ./scripts/prepare.sh"
  log "  ./scripts/up_staging.sh"
}

main "$@"
