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

if ! command -v zip >/dev/null 2>&1; then
  fail "zip command is required for submission smoke"
fi

if ! command -v unzip >/dev/null 2>&1; then
  fail "unzip command is required for submission smoke"
fi

# ---------------------------------------------------------------------------
# Load env
# ---------------------------------------------------------------------------

load_env_file "${ROOT_ENV_FILE}"
load_env_file "${LEGACY_ENV_FILE}"

GATEWAY_URL="${GATEWAY_URL:-http://localhost:${GATEWAY_PORT:-8080}}"
MINIO_PUBLIC_URL="${S3_PUBLIC_ENDPOINT:-http://localhost:9000}"
LAB_ASSETS_BUCKET="${LAB_ASSETS_BUCKET:-lab-assets}"
SUBMISSION_ASSETS_BUCKET="${SUBMISSION_ASSETS_BUCKET:-submission-assets}"
EVALUATION_REPORTS_BUCKET="${EVALUATION_REPORTS_BUCKET:-evaluation-reports}"

LAB_ASSETS_PUBLIC_PREFIX="${MINIO_PUBLIC_URL%/}/${LAB_ASSETS_BUCKET}/"
SUBMISSION_ASSETS_PUBLIC_PREFIX="${MINIO_PUBLIC_URL%/}/${SUBMISSION_ASSETS_BUCKET}/"
EVALUATION_REPORTS_PUBLIC_PREFIX="${MINIO_PUBLIC_URL%/}/${EVALUATION_REPORTS_BUCKET}/"

LECTURER_EMAIL="lecturer@ags.local"
LECTURER_PASSWORD="Password123!"
STUDENT_EMAIL="student@ags.local"
STUDENT_PASSWORD="Password123!"
ADMIN_EMAIL="admin@ags.local"
ADMIN_PASSWORD="Password123!"

# Temp files
login_body_file="$(mktemp)"
response_body_file="$(mktemp)"
# Use fixed names so they match the filenames sent in requirementFileName / collectionFileName metadata
upload_pdf="/tmp/ops-smoke-requirements.pdf"
upload_json="/tmp/ops-smoke-postman-collection.json"
submission_dir="/tmp/ops-smoke-submission"
submission_zip="/tmp/ops-smoke-submission.zip"
submission_download="/tmp/ops-smoke-submission-download.zip"

trap 'rm -f "${login_body_file}" "${response_body_file}" "${upload_pdf}" "${upload_json}" "${submission_zip}" "${submission_download}"; rm -rf "${submission_dir}"' EXIT

# Minimal valid PDF bytes for the upload test
printf '%%PDF-1.0\n1 0 obj<</Type /Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type /Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type /Page/MediaBox[0 0 3 3]>>endobj\nxref\n0 4\n0000000000 65535 f\n0000000009 00000 n\n0000000058 00000 n\n0000000115 00000 n\ntrailer<</Size 4/Root 1 0 R>>\nstartxref\n190\n%%%%EOF' > "${upload_pdf}"

# Minimal valid JSON for the postman collection upload
printf '{"info":{"name":"smoke-test","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},"item":[]}' > "${upload_json}"

# ===========================================================================
# 1. GATEWAY HEALTH
# ===========================================================================

log "=== [1/25] Gateway health ==="
retry "Gateway health" 12 5 curl -fsS "${GATEWAY_URL}/health" >/dev/null \
  || fail "Gateway health endpoint is not reachable. Is the gateway running? Check status with make app-ps."
log "Gateway health OK."

# ===========================================================================
# 2. IDENTITY HEALTH THROUGH GATEWAY
# ===========================================================================

log "=== [2/25] Identity health through gateway ==="
retry "Identity health through gateway" 12 5 curl -fsS "${GATEWAY_URL}/identity/health" >/dev/null \
  || fail "Identity health through gateway is not reachable. Is identity-service healthy? Check status with make app-ps and logs with make app-logs."
log "Identity health OK."

# ===========================================================================
# 3. LECTURER LOGIN
# ===========================================================================

log "=== [3/25] Lecturer login through gateway ==="
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

log "=== [4/25] Student login through gateway ==="
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

log "=== [5/25] Class Service health through gateway ==="
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

log "=== [6/25] Lecturer creates class through gateway ==="
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

log "=== [7/25] Student joins class through gateway ==="
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

log "=== [8/25] Lecturer creates lab through gateway ==="
create_lab_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${lecturer_token}" \
    -d '{"title":"Smoke Test Lab","description":"Created by smoke-app","deadline":"2099-12-31T23:59:59Z","requirementFileName":"ops-smoke-requirements.pdf","collectionFileName":"ops-smoke-postman-collection.json"}' \
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
    .data.lab.id //
    .data.lab.labId //
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

# Capture presigned upload URLs returned inline by the create-lab response.
# The API returns data.upload.requirementUploadUrl and data.upload.collectionUploadUrl.
create_lab_requirement_upload_url="$(jq -r '
  .data.upload.requirementUploadUrl //
  .data.upload.requirementUrl //
  .upload.requirementUploadUrl //
  .upload.requirementUrl //
  empty
' "${response_body_file}")"
create_lab_collection_upload_url="$(jq -r '
  .data.upload.collectionUploadUrl //
  .data.upload.collectionUrl //
  .upload.collectionUploadUrl //
  .upload.collectionUrl //
  empty
' "${response_body_file}")"

if [[ -n "${create_lab_requirement_upload_url}" && "${create_lab_requirement_upload_url}" != "null" ]]; then
  log "Create lab returned inline presigned upload URLs."
fi

# ===========================================================================
# 9. VERIFY PRESIGNED UPLOAD URLS USE MINIO PUBLIC ENDPOINT
# ===========================================================================

log "=== [9/25] Checking lab assets upload URLs use MinIO public endpoint ==="
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

log "=== [10/25] Fetching presigned upload URLs for lab assets ==="

# Upload URLs were already returned inline by the create-lab response.
# Fall back to a separate endpoint only if they were not present.
requirement_upload_url="${create_lab_requirement_upload_url}"
collection_upload_url="${create_lab_collection_upload_url}"

if [[ -z "${requirement_upload_url}" || "${requirement_upload_url}" == "null" ]]; then
  log "No inline upload URLs from create-lab; trying /api/labs/${lab_id}/assets/upload-urls..."
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
    requirement_upload_url="$(jq -r '.requirementUrl // .requirement // .uploadUrls.requirement // .data.upload.requirementUploadUrl // empty' "${response_body_file}")"
    collection_upload_url="$(jq -r '.collectionUrl // .collection // .uploadUrls.collection // .data.upload.collectionUploadUrl // empty' "${response_body_file}")"
  else
    log "Upload URL endpoint returned HTTP ${upload_urls_status}. Skipping presigned upload step."
  fi
fi

if [[ -n "${requirement_upload_url}" && "${requirement_upload_url}" != "null" ]]; then
  # Verify URL uses the public MinIO endpoint, not internal Docker DNS
  if echo "${requirement_upload_url}" | grep -q 'http://minio:'; then
    fail "Presigned URLs expose internal Docker DNS (http://minio:...). Check S3_PUBLIC_ENDPOINT config."
  fi
  if [[ "${requirement_upload_url}" != "${LAB_ASSETS_PUBLIC_PREFIX}"* ]]; then
    log "Expected lab asset upload URL prefix: ${LAB_ASSETS_PUBLIC_PREFIX}"
    log "Actual lab requirement upload URL: ${requirement_upload_url%%\?*}"
    fail "Lab requirement upload URL does not use configured S3 public endpoint/bucket."
  fi
  log "Presigned upload URLs use public endpoint OK."

  log "Uploading requirement PDF to presigned URL..."
  upload_status="$(curl -sS -o /dev/null -w "%{http_code}" -X PUT --upload-file "${upload_pdf}" "${requirement_upload_url}")" || upload_status="000"
  if [[ "${upload_status}" -ge 200 && "${upload_status}" -lt 300 ]]; then
    log "Requirement PDF upload OK (HTTP ${upload_status})."
  else
    log "Requirement PDF upload HTTP status: ${upload_status}"
    fail "Requirement PDF upload failed. HTTP ${upload_status}."
  fi
else
  log "No requirement upload URL available; skipping PDF upload."
fi

if [[ -n "${collection_upload_url}" && "${collection_upload_url}" != "null" ]]; then
  if [[ "${collection_upload_url}" != "${LAB_ASSETS_PUBLIC_PREFIX}"* ]]; then
    log "Expected lab asset upload URL prefix: ${LAB_ASSETS_PUBLIC_PREFIX}"
    log "Actual lab collection upload URL: ${collection_upload_url%%\?*}"
    fail "Lab collection upload URL does not use configured S3 public endpoint/bucket."
  fi
  log "Uploading Postman collection JSON to presigned URL..."
  upload_status="$(curl -sS -o /dev/null -w "%{http_code}" -X PUT --upload-file "${upload_json}" "${collection_upload_url}")" || upload_status="000"
  if [[ "${upload_status}" -ge 200 && "${upload_status}" -lt 300 ]]; then
    log "Postman collection upload OK (HTTP ${upload_status})."
  else
    log "Postman collection upload HTTP status: ${upload_status}"
    fail "Postman collection upload failed. HTTP ${upload_status}."
  fi
else
  log "No collection upload URL available; skipping JSON upload."
fi

# ===========================================================================
# 11. COMPLETE LAB ASSETS
# ===========================================================================

log "=== [11/25] Completing lab assets through gateway ==="
complete_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${lecturer_token}" \
    -d '{"requirementUploaded":true,"collectionUploaded":true}' \
    "${GATEWAY_URL}/api/labs/${lab_id}/assets/complete"
)" || fail "Lab assets complete curl failed."

if [[ "${complete_status}" -lt 200 || "${complete_status}" -ge 300 ]]; then
  log "Lab assets complete HTTP status: ${complete_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Lab assets complete failed. HTTP ${complete_status}. Both files must be uploaded before completing."
fi

# Verify response: success=true, data.status=="active", data.assetsCompletedAt not null
complete_lab_status="$(jq -r '.data.status // .data.lab.status // empty' "${response_body_file}")"
complete_assets_at="$(jq -r '.data.assetsCompletedAt // .data.lab.assetsCompletedAt // empty' "${response_body_file}")"

if [[ "${complete_lab_status}" != "active" ]]; then
  log "Complete assets response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Lab status after complete is '${complete_lab_status}', expected 'active'."
fi

if [[ -z "${complete_assets_at}" || "${complete_assets_at}" == "null" ]]; then
  log "Complete assets response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "assetsCompletedAt is null after complete assets. Backend did not mark lab as complete."
fi

log "Lab assets complete OK (HTTP ${complete_status}, status=${complete_lab_status}, assetsCompletedAt=${complete_assets_at})."

# ===========================================================================
# 12. STUDENT LISTS CLASS LABS
# ===========================================================================

log "=== [12/25] Student lists class labs through gateway ==="
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

log "=== [13/25] Lab asset access controls ==="

# Student gets requirement URL — must be 200 after assets are complete and lab is active
req_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${student_token}" \
    "${GATEWAY_URL}/api/labs/${lab_id}/assets/requirement"
)" || req_status="000"

if [[ "${req_status}" == "200" ]]; then
  log "Student requirement URL access OK (HTTP 200)."
else
  log "Student requirement URL HTTP status: ${req_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Student requirement URL must be 200 after lab is active but got HTTP ${req_status}. Is lab status active? Did assets complete succeed?"
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

# Lecturer can get collection URL — must be 200
lecturer_col_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${lecturer_token}" \
    "${GATEWAY_URL}/api/labs/${lab_id}/assets/collection"
)" || lecturer_col_status="000"

if [[ "${lecturer_col_status}" == "200" ]]; then
  log "Lecturer collection URL access OK (HTTP 200)."
else
  log "Lecturer collection URL HTTP status: ${lecturer_col_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Lecturer collection URL must be 200 but got HTTP ${lecturer_col_status}. Authorization control or asset state is broken."
fi

# ===========================================================================
# 14. SUBMISSION SERVICE HEALTH THROUGH GATEWAY
# ===========================================================================

log "=== [14/25] Submission Service health through gateway ==="
retry "Submission Service health" 24 5 curl -fsS "${GATEWAY_URL}/submission/health" -o "${response_body_file}" \
  || fail "Submission Service health endpoint is not reachable at ${GATEWAY_URL}/submission/health. Is submission-service running? Check status with make app-ps and logs with make app-logs."

if ! jq -e '.success == true' "${response_body_file}" >/dev/null 2>&1; then
  log "Submission health response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Submission health did not return success=true."
fi
log "Submission Service health OK."

# ===========================================================================
# 15. STUDENT CREATES SUBMISSION
# ===========================================================================

log "=== [15/25] Student creates submission through gateway ==="
create_submission_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${student_token}" \
    -d '{"projectFileName":"ops-smoke-submission.zip","notes":"Created by smoke-app"}' \
    "${GATEWAY_URL}/api/labs/${lab_id}/submissions"
)" || fail "Create submission curl failed."

if [[ "${create_submission_status}" != "200" && "${create_submission_status}" != "201" ]]; then
  log "Create submission HTTP status: ${create_submission_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Student create submission failed. HTTP ${create_submission_status}."
fi

if ! jq -e '.success == true' "${response_body_file}" >/dev/null 2>&1; then
  log "Create submission response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Create submission response did not return success=true."
fi

submission_id="$(jq -r '.data.submission.id // empty' "${response_body_file}")"
submission_status="$(jq -r '.data.submission.status // empty' "${response_body_file}")"
project_upload_url="$(jq -r '.data.upload.projectUploadUrl // empty' "${response_body_file}")"

if [[ -z "${submission_id}" || "${submission_id}" == "null" ]]; then
  log "Create submission response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Create submission did not return data.submission.id."
fi

if [[ "${submission_status}" != "pending_assets" ]]; then
  log "Create submission response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Submission status after create is '${submission_status}', expected 'pending_assets'."
fi

if [[ "${project_upload_url}" != "${SUBMISSION_ASSETS_PUBLIC_PREFIX}"* ]]; then
  log "Expected submission upload URL prefix: ${SUBMISSION_ASSETS_PUBLIC_PREFIX}"
  log "Actual submission upload URL: ${project_upload_url%%\?*}"
  fail "Submission project upload URL does not use configured S3 public endpoint/bucket."
fi
log "Student created submission ID: ${submission_id}"

# ===========================================================================
# 16. CREATE AND UPLOAD SUBMISSION ZIP
# ===========================================================================

log "=== [16/25] Uploading submission ZIP to presigned URL ==="
rm -rf "${submission_dir}"
mkdir -p "${submission_dir}"
printf 'Created by smoke-app\n' > "${submission_dir}/README.md"
rm -f "${submission_zip}"
(
  cd "${submission_dir}"
  zip -qr "${submission_zip}" README.md
)

submission_upload_status="$(
  curl -sS \
    -o /dev/null \
    -w "%{http_code}" \
    -X PUT \
    --upload-file "${submission_zip}" \
    "${project_upload_url}"
)" || submission_upload_status="000"

if [[ "${submission_upload_status}" != "200" ]]; then
  fail "Submission ZIP upload failed. Expected HTTP 200, got HTTP ${submission_upload_status}."
fi
log "Submission ZIP upload OK."

# ===========================================================================
# 17. COMPLETE SUBMISSION ASSETS
# ===========================================================================

log "=== [17/25] Completing submission assets through gateway ==="
complete_submission_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${student_token}" \
    -d '{"projectUploaded":true}' \
    "${GATEWAY_URL}/api/submissions/${submission_id}/assets/complete"
)" || fail "Submission assets complete curl failed."

if [[ "${complete_submission_status}" != "200" ]]; then
  log "Submission assets complete HTTP status: ${complete_submission_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Submission assets complete failed. HTTP ${complete_submission_status}."
fi

if ! jq -e '.success == true and .data.status == "submitted" and (.data.submittedAt != null) and (.data.assetsCompletedAt != null)' "${response_body_file}" >/dev/null 2>&1; then
  log "Submission assets complete response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Submission was not marked submitted with submittedAt and assetsCompletedAt."
fi
log "Submission assets complete OK."

# ===========================================================================
# 18. STUDENT LISTS OWN SUBMISSIONS
# ===========================================================================

log "=== [18/25] Student lists own submissions through gateway ==="
student_submissions_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${student_token}" \
    "${GATEWAY_URL}/api/submissions/my?page=1&pageSize=20"
)" || fail "Student list own submissions curl failed."

if [[ "${student_submissions_status}" != "200" ]]; then
  log "Student list own submissions HTTP status: ${student_submissions_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Student list own submissions failed. HTTP ${student_submissions_status}."
fi

if ! jq -e --arg id "${submission_id}" '.. | objects | select((.id? // .submissionId? // "") == $id)' "${response_body_file}" >/dev/null 2>&1; then
  log "Student list own submissions response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Student own submissions list did not include created submission ${submission_id}."
fi
log "Student own submissions list includes created submission."

# ===========================================================================
# 19. STUDENT LISTS OWN SUBMISSIONS FOR LAB
# ===========================================================================

log "=== [19/25] Student lists own lab submissions through gateway ==="
student_lab_submissions_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${student_token}" \
    "${GATEWAY_URL}/api/labs/${lab_id}/submissions/my"
)" || fail "Student list own lab submissions curl failed."

if [[ "${student_lab_submissions_status}" != "200" ]]; then
  log "Student list own lab submissions HTTP status: ${student_lab_submissions_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Student list own lab submissions failed. HTTP ${student_lab_submissions_status}."
fi

if ! jq -e --arg id "${submission_id}" '.. | objects | select((.id? // .submissionId? // "") == $id)' "${response_body_file}" >/dev/null 2>&1; then
  log "Student list own lab submissions response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Student own lab submissions list did not include created submission ${submission_id}."
fi
log "Student own lab submissions list includes created submission."

# ===========================================================================
# 20. LECTURER LISTS LAB SUBMISSIONS
# ===========================================================================

log "=== [20/25] Lecturer lists lab submissions through gateway ==="
lecturer_lab_submissions_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${lecturer_token}" \
    "${GATEWAY_URL}/api/labs/${lab_id}/submissions?page=1&pageSize=20"
)" || fail "Lecturer list lab submissions curl failed."

if [[ "${lecturer_lab_submissions_status}" != "200" ]]; then
  log "Lecturer list lab submissions HTTP status: ${lecturer_lab_submissions_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Lecturer list lab submissions failed. HTTP ${lecturer_lab_submissions_status}."
fi

if ! jq -e --arg id "${submission_id}" '.. | objects | select((.id? // .submissionId? // "") == $id)' "${response_body_file}" >/dev/null 2>&1; then
  log "Lecturer list lab submissions response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Lecturer lab submissions list did not include created submission ${submission_id}."
fi
log "Lecturer lab submissions list includes created submission."

# ===========================================================================
# 21. STUDENT GETS SUBMISSION DETAIL
# ===========================================================================

log "=== [21/25] Student gets submission detail through gateway ==="
submission_detail_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${student_token}" \
    "${GATEWAY_URL}/api/submissions/${submission_id}"
)" || fail "Student get submission detail curl failed."

if [[ "${submission_detail_status}" != "200" ]]; then
  log "Student get submission detail HTTP status: ${submission_detail_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Student get submission detail failed. HTTP ${submission_detail_status}."
fi

detail_status="$(jq -r '.data.status // .status // empty' "${response_body_file}")"
if [[ "${detail_status}" != "submitted" ]]; then
  log "Submission detail response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Submission detail status is '${detail_status}', expected 'submitted'."
fi
log "Submission detail OK."

# ===========================================================================
# 22. LECTURER GETS SOURCE ZIP PRESIGNED URL
# ===========================================================================

log "=== [22/25] Lecturer gets source ZIP URL through gateway ==="
source_url_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -H "Authorization: Bearer ${lecturer_token}" \
    "${GATEWAY_URL}/api/submissions/${submission_id}/assets/source"
)" || fail "Lecturer get source ZIP URL curl failed."

if [[ "${source_url_status}" != "200" ]]; then
  log "Lecturer get source ZIP URL HTTP status: ${source_url_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Lecturer get source ZIP URL failed. HTTP ${source_url_status}."
fi

if ! jq -e '.success == true' "${response_body_file}" >/dev/null 2>&1; then
  log "Source ZIP URL response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Source ZIP URL response did not return success=true."
fi

source_download_url="$(jq -r '.data.url // empty' "${response_body_file}")"
if [[ "${source_download_url}" != "${SUBMISSION_ASSETS_PUBLIC_PREFIX}"* ]]; then
  log "Expected source ZIP URL prefix: ${SUBMISSION_ASSETS_PUBLIC_PREFIX}"
  log "Actual source ZIP URL: ${source_download_url%%\?*}"
  fail "Source ZIP URL does not use configured S3 public endpoint/bucket."
fi
log "Lecturer source ZIP URL OK."

# ===========================================================================
# 23. DOWNLOAD SOURCE ZIP
# ===========================================================================

log "=== [23/25] Downloading submitted source ZIP ==="
download_status="$(
  curl -sS \
    -o "${submission_download}" \
    -w "%{http_code}" \
    "${source_download_url}"
)" || download_status="000"

if [[ "${download_status}" != "200" ]]; then
  fail "Source ZIP download failed. Expected HTTP 200, got HTTP ${download_status}."
fi

download_size="$(wc -c < "${submission_download}" | tr -d '[:space:]')"
if [[ "${download_size}" -le 0 ]]; then
  fail "Source ZIP download was empty."
fi

unzip -l "${submission_download}" >/dev/null \
  || fail "Downloaded source ZIP is not a valid zip archive."
log "Source ZIP download OK (${download_size} bytes)."

# ===========================================================================
# 24. NEGATIVE SUBMISSION FILE TYPE VALIDATION
# ===========================================================================

log "=== [24/25] Invalid submission file type is rejected ==="
invalid_submission_status="$(
  curl -sS \
    -o "${response_body_file}" \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${student_token}" \
    -d '{"projectFileName":"bad-file.txt","notes":"Should fail"}' \
    "${GATEWAY_URL}/api/labs/${lab_id}/submissions"
)" || fail "Invalid submission create curl failed."

if [[ "${invalid_submission_status}" != "400" ]]; then
  log "Invalid submission create HTTP status: ${invalid_submission_status}"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Invalid submission file type should return HTTP 400."
fi

if ! jq -e '.. | objects | select((.code? // "") == "SUBMISSION_INVALID_FILE_TYPE" or (.code? // "") == "VALIDATION_ERROR")' "${response_body_file}" >/dev/null 2>&1; then
  log "Invalid submission create response body:"
  sed 's/^/[smoke-app]   /' "${response_body_file}" >&2
  fail "Invalid submission file type did not return SUBMISSION_INVALID_FILE_TYPE or VALIDATION_ERROR."
fi
log "Invalid submission file type rejected OK."

# ===========================================================================
# 25. SUBMISSION FLOW COMPLETE
# ===========================================================================

log "=== [25/25] Submission flow complete ==="
log "Submission flow OK."

# ===========================================================================
# SUMMARY
# ===========================================================================

log ""
log "============================================================"
log "All smoke-app checks passed."
log "  Gateway:            ${GATEWAY_URL}/health"
log "  Identity (gateway): ${GATEWAY_URL}/identity/health"
log "  Class (gateway):    ${GATEWAY_URL}/class/health"
log "  Submission (gateway): ${GATEWAY_URL}/submission/health"
log "  Created class ID:   ${class_id}"
log "  Created lab ID:     ${lab_id}"
log "  Submission ID:      ${submission_id}"
if curl -fsS "http://localhost:${DOZZLE_PUBLIC_PORT:-9999}" >/dev/null 2>&1; then
  log "  Dozzle is reachable."
else
  log "  Dozzle was not reachable at http://localhost:${DOZZLE_PUBLIC_PORT:-9999}; check manually if needed."
fi
log "============================================================"
