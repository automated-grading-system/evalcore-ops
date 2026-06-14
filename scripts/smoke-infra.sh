#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/compose/.env"
COMPOSE_FILE="${ROOT_DIR}/compose/docker-compose.infra.yml"

log() {
  printf '[smoke-infra] %s\n' "$1"
}

fail() {
  printf '[smoke-infra] FAILURE: %s\n' "$1" >&2
  exit 1
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

if [[ ! -f "${ENV_FILE}" ]]; then
  fail "Missing ${ENV_FILE}. Run make env first."
fi

# shellcheck disable=SC1090
set -a
source "${ENV_FILE}"
set +a

export COMPOSE_IGNORE_ORPHANS=True
COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")

log "Checking PostgreSQL reachability..."
retry "PostgreSQL" 12 5 "${COMPOSE[@]}" exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null || fail "PostgreSQL is not reachable."
log "PostgreSQL is reachable."

log "Checking RabbitMQ Management UI..."
retry "RabbitMQ Management UI" 12 5 curl -fsS "http://localhost:${RABBITMQ_MANAGEMENT_PORT}/" >/dev/null || fail "RabbitMQ Management UI is not reachable."
log "RabbitMQ Management UI is reachable."

log "Checking MinIO health endpoint..."
retry "MinIO health endpoint" 12 5 curl -fsS "http://localhost:${MINIO_API_PORT}/minio/health/live" >/dev/null || fail "MinIO health endpoint is not reachable."
log "MinIO health endpoint is reachable."

log "Checking required MinIO buckets..."
retry "MinIO buckets" 12 5 "${COMPOSE[@]}" run --rm --entrypoint /bin/sh minio-init -c "
  mc alias set local http://minio:9000 '${S3_ACCESS_KEY}' '${S3_SECRET_KEY}' >/dev/null &&
  mc ls local/lab-assets >/dev/null &&
  mc ls local/submissions >/dev/null &&
  mc ls local/evaluation-artifacts >/dev/null
" || fail "One or more required MinIO buckets are missing."
log "Required MinIO buckets exist."

log "All infrastructure smoke checks passed."
