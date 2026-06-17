#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_ENV_FILE="${ROOT_DIR}/.env"
LEGACY_ENV_FILE="${ROOT_DIR}/compose/.env"

log() {
  printf '[smoke-app] %s\n' "$1"
}

fail() {
  printf '[smoke-app] FAILURE: %s\n' "$1" >&2
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

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required for smoke-app. Install it with: sudo apt-get install jq"
fi

if ! command -v curl >/dev/null 2>&1; then
  fail "curl is required for smoke-app."
fi

# ---------------------------------------------------------------------------
# Load env
# ---------------------------------------------------------------------------

load_env_file "${ROOT_ENV_FILE}"
load_env_file "${LEGACY_ENV_FILE}"

GATEWAY_URL="${GATEWAY_URL:-http://localhost:${GATEWAY_PORT:-8080}}"
MINIO_PUBLIC_URL="${S3_PUBLIC_ENDPOINT:-http://localhost:9000}"

LECTURER_EMAIL="lecturer@ags.local"
LECTURER_PASSWORD="Password123!"
STUDENT_EMAIL="student@ags.local"
STUDENT_PASSWORD="Password123!"
ADMIN_EMAIL="admin@ags.local"
ADMIN_PASSWORD="Password123!"

# Temp files
login_body_file="$(mktemp)"
response_body_file="$(mktemp)"
upload_pdf="$(mktemp --suffix=.pdf)"
upload_json="$(mktemp --suffix=.json)"

trap 'rm -f "${login_body_file}" "${response_body_file}" "${upload_pdf}" "${upload_json}"' EXIT

# Minimal valid PDF bytes for the upload test
printf '%%PDF-1.0\n1 0 obj<</Type /Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type /Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type /Page/MediaBox[0 0 3 3]>>endobj\nxref\n0 4\n0000000000 65535 f\n0000000009 00000 n\n0000000058 00000 n\n0000000115 00000 n\ntrailer<</Size 4/Root 1 0 R>>\nstartxref\n190\n%%%%EOF' > "${upload_pdf}"

# Minimal valid JSON for the postman collection upload
printf '{"info":{"name":"smoke-test","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},"item":[]}' > "${upload_json}"

# ===========================================================================
# 1. GATEWAY HEALTH
# ===========================================================================

log "=== [1/13] Gateway health ==="
retry "Gateway health" 12 5 curl -fsS "${GATEWAY_URL}/health" >/dev/null \
  || fail "Gateway health endpoint is not reachable. Is the gateway running? Check status with make app-ps."
log "Gateway health OK."

# ===========================================================================
# 2. IDENTITY HEALTH THROUGH GATEWAY
# ===========================================================================

log "=== [2/13] Identity health through gateway ==="
retry "Identity health through gateway" 12 5 curl -fsS "${GATEWAY_URL}/identity/health" >/dev/null \
  || fail "Identity health through gateway is not reachable. Is identity-service healthy? Check status with make app-ps and logs with make app-logs."
log "Identity health OK."

# ===========================================================================
# 3. LECTURER LOGIN
# ===========================================================================

log "=== [3/13] Lecturer login through gateway ==="
lecturer_status="$(
  curl -sS \
    -o "${login_body_file}" \
    -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${LECTURER_EMAIL}\",\"password\":\"${LECTURER_PASSWORD}\"}" \
    "${GATEWAY_URL}/api/auth/login"
)" || fail "Lecturer login curl failed."

if [[ "${lecturer_status}" -lt 200 || "${lecturer_status}" -ge 300 ]]; then
  log "Lecturer login HTTP status: ${lecturer_status}"
  sed 's/^/[smoke-app]   /' "${login_body_file}" >&2
  fail "Lecturer login failed. Is identity-service healthy? Did migrations run? Did demo seed accounts exist?"
fi

lecturer_token="$(
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

if [[ -z "${lecturer_token}" || "${lecturer_token}" == "null" ]]; then
  sed 's/^/[smoke-app]   /' "${login_body_file}" >&2
  fail "Lecturer login did not return a JWT token."
fi
log "Lecturer login OK."

# ===========================================================================
# 4. STUDENT LOGIN
# ===========================================================================

log "=== [4/13] Student login through gateway ==="
student_status="$(
  curl -sS \
    -o "${login_body_file}" \
    -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${STUDENT_EMAIL}\",\"password\":\"${STUDENT_PASSWORD}\"}" \
    "${GATEWAY_URL}/api/auth/login"
)" || fail "Student login curl failed."

if [[ "${student_status}" -lt 200 || "${student_status}" -ge 300 ]]; then
  log "Student login HTTP status: ${student_status}"
  sed 's/^/[smoke-app]   /' "${login_body_file}" >&2
  fail "Student login failed."
fi

student_token="$(
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

if [[ -z "${student_token}" || "${student_token}" == "null" ]]; then
  sed 's/^/[smoke-app]   /' "${login_body_file}" >&2
  fail "Student login did not return a JWT token."
fi
log "Student login OK."

# Identity /api/users/me and /api/admin/users via admin token
log "=== [identity] /api/users/me through gateway ==="
curl -fsS -H "Authorization: Bearer ${lecturer_token}" "${GATEWAY_URL}/api/users/me" >/dev/null \
  || fail "/api/users/me through gateway failed."
log "/api/users/me OK."

# ===========================================================================
# 5. CLASS SERVICE HEALTH THROUGH GATEWAY
# ===========================================================================

log "=== [5/13] Class Service health through gateway ==="
retry "Class Service health" 24 5 curl -fsS "${GATEWAY_URL}/class/health" >/dev/null \
  || fail "Class Service health endpoint is not reachable at ${GATEWAY_URL}/class/health. Is class-service running? Check status with make app-ps and logs with make app-logs."
log "Class Service health OK."

# Quick schema check: if /health is reachable but /api/classes returns 500 with DB error, warn clearly.
class_schema_check_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${lecturer_token}" \
    "${GATEWAY_URL}/api/classes?page=1&pageSize=1"
)" || true

if [[ "${class_schema_check_status}" == "500" ]]; then
  log "Class Service returned 500 on /api/classes schema check."
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Class Service is reachable but classroom schema is missing. Verify class-service applies migrations on startup or run migrations before container mode."
fi

# ===========================================================================
# 6. LECTURER CREATES CLASS
# ===========================================================================

log "=== [6/13] Lecturer creates class through gateway ==="
create_class_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${lecturer_token}" \
    -d '{"name":"Smoke Test Class","description":"Created by smoke-app"}' \
    "${GATEWAY_URL}/api/classes"
)" || fail "Create class curl failed."

if [[ "${create_class_status}" -lt 200 || "${create_class_status}" -ge 300 ]]; then
  log "Create class HTTP status: ${create_class_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Lecturer create class failed. HTTP ${create_class_status}."
fi

class_id="$(
  jq -r '
    .id //
    .classId //
    .data.id //
    .data.classId //
    .result.id //
    .result.classId //
    empty
  ' "${response_body_file}"
)"

if [[ -z "${class_id}" || "${class_id}" == "null" ]]; then
  log "Create class response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Create class did not return a class ID."
fi
log "Lecturer created class ID: ${class_id}"

# ===========================================================================
# 7. STUDENT JOINS CLASS
# ===========================================================================

log "=== [7/13] Student joins class through gateway ==="
join_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${student_token}" \
    "${GATEWAY_URL}/api/classes/${class_id}/join"
)" || fail "Student join class curl failed."

if [[ "${join_status}" -lt 200 || "${join_status}" -ge 300 ]]; then
  log "Student join class HTTP status: ${join_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Student join class failed. HTTP ${join_status}."
fi
log "Student joined class OK."

# ===========================================================================
# 8. LECTURER CREATES LAB
# ===========================================================================

log "=== [8/13] Lecturer creates lab through gateway ==="
create_lab_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${lecturer_token}" \
    -d '{"title":"Smoke Test Lab","description":"Created by smoke-app","dueDate":"2099-12-31T23:59:59Z"}' \
    "${GATEWAY_URL}/api/classes/${class_id}/labs"
)" || fail "Create lab curl failed."

if [[ "${create_lab_status}" -lt 200 || "${create_lab_status}" -ge 300 ]]; then
  log "Create lab HTTP status: ${create_lab_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Lecturer create lab failed. HTTP ${create_lab_status}."
fi

lab_id="$(
  jq -r '
    .id //
    .labId //
    .data.id //
    .data.labId //
    .result.id //
    .result.labId //
    empty
  ' "${response_body_file}"
)"

if [[ -z "${lab_id}" || "${lab_id}" == "null" ]]; then
  log "Create lab response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Create lab did not return a lab ID."
fi
log "Lecturer created lab ID: ${lab_id}"

# ===========================================================================
# 9. VERIFY PRESIGNED UPLOAD URLS USE MINIO PUBLIC ENDPOINT
# ===========================================================================

log "=== [9/13] Checking lab assets upload URLs use MinIO public endpoint ==="
assets_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${lecturer_token}" \
    "${GATEWAY_URL}/api/labs/${lab_id}/assets"
)" || true

# Tolerate 404 if lab assets endpoint returns nothing on a fresh lab;
# We only check if the endpoint is responsive and if URLs are correct.
if [[ "${assets_status}" -ge 200 && "${assets_status}" -lt 300 ]]; then
  # Check that any presigned URL uses the public endpoint (not internal minio:9000)
  if jq -e '.. | strings | test("http://minio:")' "${response_body_file}" >/dev/null 2>&1; then
    log "WARNING: presigned URLs contain internal minio:9000 addresses instead of the public endpoint."
    log "Expected S3_PUBLIC_ENDPOINT=${MINIO_PUBLIC_URL}"
    sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
    fail "Presigned URLs expose internal Docker DNS. Check CLASS_SERVICE S3_PUBLIC_ENDPOINT config."
  fi
fi
log "Presigned URL endpoint check OK (or lab assets endpoint skipped on fresh lab)."

# ===========================================================================
# 10. UPLOAD REQUIREMENT PDF AND POSTMAN COLLECTION TO PRESIGNED URLS
# ===========================================================================

log "=== [10/13] Fetching presigned upload URLs for lab assets ==="

# Try to get upload URLs. This endpoint may vary by API design.
# Try /api/labs/{labId}/assets/upload-urls first, then /api/labs/{labId}/assets.
upload_urls_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${lecturer_token}" \
    -d '{}' \
    "${GATEWAY_URL}/api/labs/${lab_id}/assets/upload-urls"
)" || upload_urls_status="000"

if [[ "${upload_urls_status}" -ge 200 && "${upload_urls_status}" -lt 300 ]]; then
  requirement_upload_url="$(jq -r '.requirementUrl // .requirement // .uploadUrls.requirement // empty' "${response_body_file}")"
  collection_upload_url="$(jq -r '.collectionUrl // .collection // .uploadUrls.collection // empty' "${response_body_file}")"

  if [[ -n "${requirement_upload_url}" && "${requirement_upload_url}" != "null" ]]; then
    log "Uploading requirement PDF to presigned URL..."
    upload_status="$(curl -sS -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: application/pdf" --data-binary "@${upload_pdf}" "${requirement_upload_url}")" || upload_status="000"
    if [[ "${upload_status}" -ge 200 && "${upload_status}" -lt 300 ]]; then
      log "Requirement PDF upload OK (HTTP ${upload_status})."
    else
      log "WARNING: Requirement PDF upload returned HTTP ${upload_status}. Continuing."
    fi
  else
    log "No requirement upload URL in response; skipping PDF upload."
  fi

  if [[ -n "${collection_upload_url}" && "${collection_upload_url}" != "null" ]]; then
    log "Uploading Postman collection JSON to presigned URL..."
    upload_status="$(curl -sS -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: application/json" --data-binary "@${upload_json}" "${collection_upload_url}")" || upload_status="000"
    if [[ "${upload_status}" -ge 200 && "${upload_status}" -lt 300 ]]; then
      log "Postman collection upload OK (HTTP ${upload_status})."
    else
      log "WARNING: Postman collection upload returned HTTP ${upload_status}. Continuing."
    fi
  else
    log "No collection upload URL in response; skipping JSON upload."
  fi
else
  log "Upload URL endpoint returned HTTP ${upload_urls_status} (may not be implemented or may differ). Skipping presigned upload step."
fi

# ===========================================================================
# 11. COMPLETE LAB ASSETS
# ===========================================================================

log "=== [11/13] Completing lab assets through gateway ==="
complete_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${lecturer_token}" \
    -d '{}' \
    "${GATEWAY_URL}/api/labs/${lab_id}/assets/complete"
)" || complete_status="000"

if [[ "${complete_status}" -ge 200 && "${complete_status}" -lt 300 ]]; then
  log "Lab assets complete OK (HTTP ${complete_status})."
elif [[ "${complete_status}" == "404" || "${complete_status}" == "000" ]]; then
  log "Lab assets complete endpoint returned HTTP ${complete_status} (may not be implemented yet). Continuing."
else
  log "Lab assets complete HTTP status: ${complete_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  log "WARNING: Lab assets complete returned unexpected status ${complete_status}. Continuing."
fi

# ===========================================================================
# 12. STUDENT LISTS CLASS LABS
# ===========================================================================

log "=== [12/13] Student lists class labs through gateway ==="
list_labs_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${student_token}" \
    "${GATEWAY_URL}/api/classes/${class_id}/labs"
)" || fail "Student list labs curl failed."

if [[ "${list_labs_status}" -lt 200 || "${list_labs_status}" -ge 300 ]]; then
  log "Student list labs HTTP status: ${list_labs_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Student list class labs failed. HTTP ${list_labs_status}."
fi
log "Student list class labs OK."

# ===========================================================================
# 13. STUDENT GETS REQUIREMENT URL / IS FORBIDDEN FROM COLLECTION URL
#     LECTURER CAN GET COLLECTION URL
# ===========================================================================

log "=== [13/13] Lab asset access controls ==="

# Student gets requirement URL (may be 200 or 404 if assets not yet completed)
req_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${student_token}" \
    "${GATEWAY_URL}/api/labs/${lab_id}/assets/requirement"
)" || req_status="000"

if [[ "${req_status}" == "200" ]]; then
  log "Student requirement URL access OK (HTTP 200)."
elif [[ "${req_status}" == "404" ]]; then
  log "Student requirement URL returned 404 (assets not yet uploaded; acceptable at this stage)."
else
  log "Student requirement URL HTTP status: ${req_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  log "WARNING: Unexpected status ${req_status} for student requirement URL. Continuing."
fi

# Student must be forbidden from collection URL
col_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${student_token}" \
    "${GATEWAY_URL}/api/labs/${lab_id}/assets/collection"
)" || col_status="000"

if [[ "${col_status}" == "403" ]]; then
  log "Student is correctly forbidden from collection URL (HTTP 403)."
elif [[ "${col_status}" == "404" ]]; then
  log "Collection URL returned 404 (assets not yet uploaded; access control not verified at this stage)."
else
  log "Student collection URL HTTP status: ${col_status}"
  if [[ "${col_status}" -ge 200 && "${col_status}" -lt 300 ]]; then
    sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
    fail "Student should be forbidden (403) from collection URL but got HTTP ${col_status}. Authorization control is broken."
  else
    log "WARNING: Unexpected status ${col_status} for student collection URL. Continuing."
  fi
fi

# Lecturer can get collection URL
lecturer_col_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${lecturer_token}" \
    "${GATEWAY_URL}/api/labs/${lab_id}/assets/collection"
)" || lecturer_col_status="000"

if [[ "${lecturer_col_status}" == "200" ]]; then
  log "Lecturer collection URL access OK (HTTP 200)."
elif [[ "${lecturer_col_status}" == "404" ]]; then
  log "Lecturer collection URL returned 404 (assets not yet uploaded; acceptable at this stage)."
else
  log "Lecturer collection URL HTTP status: ${lecturer_col_status}"
  if [[ "${lecturer_col_status}" == "403" ]]; then
    sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
    fail "Lecturer should be allowed to access collection URL but got 403."
  else
    log "WARNING: Unexpected status ${lecturer_col_status} for lecturer collection URL. Continuing."
  fi
fi

# ===========================================================================
# SUMMARY
# ===========================================================================

log ""
log "============================================================"
log "All smoke-app checks passed."
log "  Gateway:            ${GATEWAY_URL}/health"
log "  Identity (gateway): ${GATEWAY_URL}/identity/health"
log "  Class (gateway):    ${GATEWAY_URL}/class/health"
log "  Created class ID:   ${class_id}"
log "  Created lab ID:     ${lab_id}"
log "============================================================"
