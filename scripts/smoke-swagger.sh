#!/usr/bin/env bash

set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:${GATEWAY_PORT:-8080}}"
GATEWAY_URL="${GATEWAY_URL%/}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

log() {
  printf '[smoke-swagger] %s\n' "$1"
}

log "Checking the Swagger portal."
portal_status="$(curl --fail --silent --show-error --location \
  --output "${TMP_DIR}/portal.html" \
  --write-out '%{http_code}' \
  "${GATEWAY_URL}/docs/swagger")"
[[ "${portal_status}" == 200 ]]
grep -qi 'swagger' "${TMP_DIR}/portal.html"
log "Portal returned HTTP 200 and Swagger UI content."

services=(identity class submission evaluation notification)
for service in "${services[@]}"; do
  document="${TMP_DIR}/${service}.json"
  document_status="$(curl --fail --silent --show-error \
    --output "${document}" \
    --write-out '%{http_code}' \
    "${GATEWAY_URL}/docs/openapi/${service}.json")"
  [[ "${document_status}" == 200 ]]
  grep -Eq '"(openapi|swagger)"[[:space:]]*:' "${document}"
  log "${service} OpenAPI document returned HTTP 200 and contains a specification marker."
done

log "All Swagger portal checks passed."
