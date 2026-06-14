#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_ENV_FILE="${ROOT_DIR}/.env"
LEGACY_ENV_FILE="${ROOT_DIR}/compose/.env"

log() {
  printf '[smoke-auth] %s\n' "$1"
}

fail() {
  printf '[smoke-auth] FAILURE: %s\n' "$1" >&2
  exit 1
}

load_env_file() {
  local env_file="$1"

  [[ -f "${env_file}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    export "${line}"
  done < "${env_file}"
}

retry() {
  local description="$1"
  local attempts="$2"
  local delay="$3"
  shift 3

  for attempt in $(seq 1 "${attempts}"); do
    if "$@"; then
      return 0
    fi

    if [[ "${attempt}" -lt "${attempts}" ]]; then
      log "${description} not ready yet; retrying in ${delay}s (${attempt}/${attempts})..."
      sleep "${delay}"
    fi
  done

  return 1
}

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required for smoke-auth."
fi

load_env_file "${ROOT_ENV_FILE}"
load_env_file "${LEGACY_ENV_FILE}"

GATEWAY_URL="${GATEWAY_URL:-http://localhost:${GATEWAY_PORT:-8080}}"
ADMIN_EMAIL="admin@ags.local"
ADMIN_PASSWORD="Password123!"

login_body_file="$(mktemp)"
trap 'rm -f "${login_body_file}"' EXIT

log "Checking gateway health at ${GATEWAY_URL}/health..."
retry "Gateway health" 12 5 curl -fsS "${GATEWAY_URL}/health" >/dev/null || fail "Gateway health endpoint is not reachable. Is the gateway running? Check status with make app-ps."
log "Gateway health is reachable."

log "Checking Identity health through gateway..."
retry "Identity health through gateway" 12 5 curl -fsS "${GATEWAY_URL}/identity/health" >/dev/null || fail "Identity health through gateway is not reachable. Is identity-service healthy? Check status with make app-ps and logs with make app-logs."
log "Identity health through gateway is reachable."

log "Logging in through gateway as ${ADMIN_EMAIL}..."
login_status="$(
  curl -sS \
    -o "${login_body_file}" \
    -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\"}" \
    "${GATEWAY_URL}/api/auth/login"
)" || fail "Login through gateway failed. Is identity-service healthy? Did migrations run? Did demo seed accounts exist? Check logs with make app-logs."

if [[ "${login_status}" -lt 200 || "${login_status}" -ge 300 ]]; then
  log "Login HTTP status: ${login_status}"
  log "Login response body:"
  sed 's/^/[smoke-auth]   /' "${login_body_file}" >&2
  fail "Login through gateway failed. Is identity-service healthy? Did migrations run? Did demo seed accounts exist? Check logs with make app-logs."
fi

token="$(
  jq -r '
    .accessToken //
    .token //
    .jwt //
    .data.accessToken //
    .data.token //
    .result.accessToken //
    .result.token //
    empty
  ' "${login_body_file}"
)"

if [[ -z "${token}" || "${token}" == "null" ]]; then
  log "Login response body:"
  sed 's/^/[smoke-auth]   /' "${login_body_file}" >&2
  fail "Login response did not contain a JWT token."
fi
log "Login returned a JWT token."

log "Checking /api/users/me through gateway..."
curl -fsS -H "Authorization: Bearer ${token}" "${GATEWAY_URL}/api/users/me" >/dev/null || fail "/api/users/me through gateway failed."
log "/api/users/me through gateway is reachable."

log "Checking /api/admin/users through gateway..."
curl -fsS -H "Authorization: Bearer ${token}" "${GATEWAY_URL}/api/admin/users?page=1&pageSize=20" >/dev/null || fail "/api/admin/users through gateway failed."
log "/api/admin/users through gateway is reachable."

log "All auth gateway smoke checks passed."
