#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_ENV_FILE="${ROOT_DIR}/.env"
LEGACY_ENV_FILE="${ROOT_DIR}/compose/.env"

log() { printf '[smoke-evaluation] %s\n' "$1"; }
fail() { log "FAILURE: $1" >&2; exit 1; }

load_env_preserve_existing() {
  local env_file="$1" line
  [[ -f "${env_file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" == *=* ]] || continue

    local key="${line%%=*}"
    local value="${line#*=}"
    key="$(printf '%s' "${key}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    case "${key}" in
      ''|*[!A-Za-z0-9_]*|[0-9]*) continue ;;
    esac

    if [[ -n "${!key+x}" ]]; then
      continue
    fi

    value="$(printf '%s' "${value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
      value="${value:1:${#value}-2}"
    else
      value="$(printf '%s' "${value}" | sed 's/[[:space:]]#.*$//;s/[[:space:]]*$//')"
    fi

    export "${key}=${value}"
  done < "${env_file}"
}

retry() {
  local description="$1" attempts="$2" delay="$3"
  shift 3
  for attempt in $(seq 1 "${attempts}"); do
    "$@" && return 0
    [[ "${attempt}" == "${attempts}" ]] || { log "${description} not ready; retrying in ${delay}s (${attempt}/${attempts})"; sleep "${delay}"; }
  done
  return 1
}

api() {
  local method="$1" path="$2" token="$3" body="${4:-}"
  local -a args=(-sS -o "${response_body}" -w '%{http_code}' -X "${method}")
  [[ -n "${token}" ]] && args+=(-H "Authorization: Bearer ${token}")
  [[ -n "${body}" ]] && args+=(-H 'Content-Type: application/json' --data "${body}")
  http_status="$(curl "${args[@]}" "${GATEWAY_URL}${path}")" || http_status=000
}

require_ok() {
  local description="$1"
  if [[ "${http_status}" -lt 200 || "${http_status}" -ge 300 ]]; then
    sed 's/^/[smoke-evaluation]   /' "${response_body}" >&2 || true
    fail "${description} returned HTTP ${http_status}."
  fi
}

id_from_response() {
  jq -r '.id // .classId // .labId // .data.id // .data.classId // .data.labId // .data.class.id // .data.lab.id // .data.submission.id // .data.evaluationId // empty' "${response_body}"
}

for command in curl jq unzip sha256sum docker; do
  command -v "${command}" >/dev/null 2>&1 || fail "${command} is required."
done

load_env_preserve_existing "${ROOT_ENV_FILE}"
load_env_preserve_existing "${LEGACY_ENV_FILE}"

EVAL_FIXTURE_ZIP="${EVAL_FIXTURE_ZIP:-${ROOT_DIR}/../test/dist/evaluation/PRN232.LMS-Evaluation-Submission.zip}"
EVAL_COLLECTION_JSON="${EVAL_COLLECTION_JSON:-${ROOT_DIR}/../test/dist/evaluation/PRN232-LMS-LAB2.postman_collection.json}"
EVAL_RUBRIC_JSON="${EVAL_RUBRIC_JSON:-}"
EVAL_EXPECTED_REQUESTS="${EVAL_EXPECTED_REQUESTS:-33}"
EVAL_EXPECTED_ASSERTIONS="${EVAL_EXPECTED_ASSERTIONS:-34}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:${GATEWAY_PORT:-8080}}"
MINIO_PUBLIC_URL="${MINIO_PUBLIC_URL:-${S3_PUBLIC_ENDPOINT:-http://localhost:9000}}"
LAB_ASSETS_BUCKET="${LAB_ASSETS_BUCKET:-lab-assets}"
SUBMISSION_ASSETS_BUCKET="${SUBMISSION_ASSETS_BUCKET:-submission-assets}"
EVALUATION_REPORTS_BUCKET="${EVALUATION_REPORTS_BUCKET:-evaluation-reports}"

LAB_ASSETS_PUBLIC_PREFIX="${MINIO_PUBLIC_URL%/}/${LAB_ASSETS_BUCKET}/"
SUBMISSION_ASSETS_PUBLIC_PREFIX="${MINIO_PUBLIC_URL%/}/${SUBMISSION_ASSETS_BUCKET}/"
EVALUATION_REPORTS_PUBLIC_PREFIX="${MINIO_PUBLIC_URL%/}/${EVALUATION_REPORTS_BUCKET}/"

[[ -f "${EVAL_FIXTURE_ZIP}" ]] || fail "Fixture ZIP not found: ${EVAL_FIXTURE_ZIP}"
[[ -f "${EVAL_COLLECTION_JSON}" ]] || fail "Postman collection not found: ${EVAL_COLLECTION_JSON}"
jq -e . "${EVAL_COLLECTION_JSON}" >/dev/null || fail "Fixture collection is not valid JSON."
if [[ -n "${EVAL_RUBRIC_JSON}" ]]; then
  [[ -f "${EVAL_RUBRIC_JSON}" ]] || fail "Rubric fixture not found: ${EVAL_RUBRIC_JSON}"
  jq -e '(.criteria | length) > 0 and ([.criteria[].maxScore] | add) > 0' \
    "${EVAL_RUBRIC_JSON}" >/dev/null || fail "Rubric fixture is not valid."
fi

mapfile -t zip_entries < <(unzip -Z1 "${EVAL_FIXTURE_ZIP}")
root_compose_count=0
for entry in "${zip_entries[@]}"; do
  [[ "${entry}" == "docker-compose.yml" || "${entry}" == "compose.yaml" ]] && ((root_compose_count += 1)) || true
  [[ "${entry}" == */docker-compose.yml || "${entry}" == */compose.yaml ]] && fail "Fixture compose file must be at ZIP root, not ${entry}."
done
[[ "${root_compose_count}" == 1 ]] || fail "Fixture ZIP must contain exactly one root docker-compose.yml or compose.yaml."
log "Fixture ZIP and Postman collection validated."

tmp_dir="$(mktemp -d)"
response_body="${tmp_dir}/response.json"
requirement_pdf="${tmp_dir}/requirements.pdf"
source_download="${tmp_dir}/submission.zip"
newman_report="${tmp_dir}/newman-report.json"
trap 'rm -rf "${tmp_dir}"' EXIT
printf '%%PDF-1.0\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > "${requirement_pdf}"

retry "Gateway health" 24 5 curl -fsS "${GATEWAY_URL}/health" >/dev/null || fail "Gateway is not reachable."
retry "Evaluation health through gateway" 36 5 curl -fsS "${GATEWAY_URL}/evaluation/health" >/dev/null || fail "Evaluation API is not reachable through the gateway."
log "Gateway and Evaluation API health checks passed."

login() {
  local email="$1" password="$2"
  curl -sS -o "${response_body}" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data "{\"email\":\"${email}\",\"password\":\"${password}\"}" "${GATEWAY_URL}/api/auth/login"
}

http_status="$(login lecturer@ags.local 'Password123!')" || http_status=000
require_ok "Lecturer login"
lecturer_token="$(jq -r '.accessToken // .token // .data.accessToken // .data.token // empty' "${response_body}")"
[[ -n "${lecturer_token}" ]] || fail "Lecturer login did not return a token."
http_status="$(login student@ags.local 'Password123!')" || http_status=000
require_ok "Student login"
student_token="$(jq -r '.accessToken // .token // .data.accessToken // .data.token // empty' "${response_body}")"
[[ -n "${student_token}" ]] || fail "Student login did not return a token."

suffix="$(date +%s)-$RANDOM"
api POST /api/classes "${lecturer_token}" "{\"name\":\"Evaluation Smoke ${suffix}\",\"description\":\"Ops evaluation auto-consumer smoke\"}"
require_ok "Create class"
class_id="$(id_from_response)"
[[ -n "${class_id}" ]] || fail "Create class did not return an ID."

api POST "/api/classes/${class_id}/join" "${student_token}"
require_ok "Student joins class"

lab_body="$(jq -nc --arg title "Evaluation Smoke Lab ${suffix}" --arg requirement "requirements.pdf" --arg collection "$(basename "${EVAL_COLLECTION_JSON}")" '{title:$title,description:"Ops evaluation auto-consumer smoke",deadline:"2099-12-31T23:59:59Z",requirementFileName:$requirement,collectionFileName:$collection}')"
api POST "/api/classes/${class_id}/labs" "${lecturer_token}" "${lab_body}"
require_ok "Create lab"
lab_id="$(id_from_response)"
[[ -n "${lab_id}" ]] || fail "Create lab did not return an ID."
requirement_upload_url="$(jq -r '.data.upload.requirementUploadUrl // .upload.requirementUploadUrl // empty' "${response_body}")"
collection_upload_url="$(jq -r '.data.upload.collectionUploadUrl // .upload.collectionUploadUrl // empty' "${response_body}")"
if [[ "${requirement_upload_url}" != "${LAB_ASSETS_PUBLIC_PREFIX}"* ]]; then
  log "Expected lab asset upload URL prefix: ${LAB_ASSETS_PUBLIC_PREFIX}"
  log "Actual lab requirement upload URL: ${requirement_upload_url%%\?*}"
  fail "Lab requirement upload URL does not use configured S3 public endpoint/bucket."
fi
if [[ "${collection_upload_url}" != "${LAB_ASSETS_PUBLIC_PREFIX}"* ]]; then
  log "Expected lab asset upload URL prefix: ${LAB_ASSETS_PUBLIC_PREFIX}"
  log "Actual lab collection upload URL: ${collection_upload_url%%\?*}"
  fail "Lab collection upload URL does not use configured S3 public endpoint/bucket."
fi

if [[ -n "${EVAL_RUBRIC_JSON}" ]]; then
  api PUT "/api/labs/${lab_id}/rubric" "${lecturer_token}" "$(jq -c . "${EVAL_RUBRIC_JSON}")"
  require_ok "Configure lab rubric"
  jq -e '.success == true and (.data.criteria | length) > 0' "${response_body}" >/dev/null \
    || fail "Lab rubric was not configured."
fi

[[ "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT --upload-file "${requirement_pdf}" "${requirement_upload_url}")" == 200 ]] || fail "Requirement PDF upload failed."
[[ "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT --upload-file "${EVAL_COLLECTION_JSON}" "${collection_upload_url}")" == 200 ]] || fail "Postman collection upload failed."
api POST "/api/labs/${lab_id}/assets/complete" "${lecturer_token}" '{"requirementUploaded":true,"collectionUploaded":true}'
require_ok "Complete lab assets"
jq -e '.success == true and (.data.status // .data.lab.status) == "active"' "${response_body}" >/dev/null || fail "Lab was not activated after its assets were completed."

submission_body="$(jq -nc --arg filename "$(basename "${EVAL_FIXTURE_ZIP}")" '{projectFileName:$filename,notes:"Ops evaluation auto-consumer smoke"}')"
api POST "/api/labs/${lab_id}/submissions" "${student_token}" "${submission_body}"
require_ok "Create submission"
submission_id="$(jq -r '.data.submission.id // empty' "${response_body}")"
project_upload_url="$(jq -r '.data.upload.projectUploadUrl // empty' "${response_body}")"
if [[ -z "${submission_id}" ]]; then
  fail "Submission creation did not return an ID."
fi
if [[ "${project_upload_url}" == http://minio:* ]]; then
  fail "Submission upload URL exposes internal Docker DNS. Check S3_PUBLIC_ENDPOINT config."
fi
if [[ "${project_upload_url}" != "${SUBMISSION_ASSETS_PUBLIC_PREFIX}"* ]]; then
  log "Expected submission upload URL prefix: ${SUBMISSION_ASSETS_PUBLIC_PREFIX}"
  log "Actual submission upload URL: ${project_upload_url%%\?*}"
  fail "Submission creation did not return the configured public upload URL."
fi
[[ "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT --upload-file "${EVAL_FIXTURE_ZIP}" "${project_upload_url}")" == 200 ]] || fail "Fixture ZIP upload failed."

api POST "/api/submissions/${submission_id}/assets/complete" "${student_token}" '{"projectUploaded":true}'
require_ok "Complete submission assets"
jq -e '.success == true and .data.status == "submitted"' "${response_body}" >/dev/null || fail "Submission did not become submitted."

api GET "/api/submissions/${submission_id}/assets/source" "${lecturer_token}"
require_ok "Get submission source URL"
source_url="$(jq -r '.data.url // empty' "${response_body}")"
[[ -n "${source_url}" ]] || fail "Submission source URL was not returned."
if [[ "${source_url}" == http://minio:* ]]; then
  fail "Source ZIP URL exposes internal Docker DNS. Check S3_PUBLIC_ENDPOINT config."
fi
if [[ "${source_url}" != "${SUBMISSION_ASSETS_PUBLIC_PREFIX}"* ]]; then
  log "Expected source ZIP URL prefix: ${SUBMISSION_ASSETS_PUBLIC_PREFIX}"
  log "Actual source ZIP URL: ${source_url%%\?*}"
  fail "Source ZIP URL does not use configured S3 public endpoint/bucket."
fi
curl -fsS -o "${source_download}" "${source_url}" || fail "Could not download submitted ZIP from MinIO."
[[ "$(sha256sum "${EVAL_FIXTURE_ZIP}" | awk '{print $1}')" == "$(sha256sum "${source_download}" | awk '{print $1}')" ]] || fail "MinIO submission object SHA-256 differs from the fixture ZIP."
log "Submission ${submission_id} is submitted and its MinIO object SHA-256 matches the fixture."

evaluation_id=""
evaluation_status=""
evaluation_score=""
evaluation_max_score=""
evaluation_scoring_mode=""
for attempt in $(seq 1 108); do
  # The submission-specific gateway route is the preferred lookup. A DB ID
  # lookup is retained strictly as diagnostics for images that do not expose
  # latest evaluation to students; it never creates or manually queues work.
  api GET "/api/submissions/${submission_id}/evaluations/latest" "${student_token}"
  if [[ "${http_status}" -ge 200 && "${http_status}" -lt 300 ]]; then
    evaluation_id="$(jq -r '.data.id // .id // empty' "${response_body}")"
  fi
  if [[ -z "${evaluation_id}" ]]; then
    evaluation_id="$(docker compose --profile app exec -T postgres psql -At -U "${POSTGRES_USER:-ags}" -d "${POSTGRES_DB:-ags}" -c "SELECT id FROM evaluation.evaluations WHERE submission_id = '${submission_id}'::uuid ORDER BY created_at DESC LIMIT 1;" 2>/dev/null || true)"
  fi
  if [[ -n "${evaluation_id}" ]]; then
    api GET "/api/evaluations/${evaluation_id}" "${student_token}"
    if [[ "${http_status}" -lt 200 || "${http_status}" -ge 300 ]]; then
      sed 's/^/[smoke-evaluation]   /' "${response_body}" >&2 || true
      fail "Evaluation ${evaluation_id} could not be read through the gateway (HTTP ${http_status})."
    fi
    evaluation_status="$(jq -r '.data.status // .status // empty' "${response_body}")"
    evaluation_score="$(jq -r '.data.score // .score // empty' "${response_body}")"
    evaluation_max_score="$(jq -r '.data.maxScore // .maxScore // empty' "${response_body}")"
    evaluation_scoring_mode="$(jq -r '.data.scoringMode // .scoringMode // empty' "${response_body}")"
    if [[ "${evaluation_status}" == passed ]]; then
      break
    fi
    if [[ "${evaluation_status}" == failed || "${evaluation_status}" == error ]]; then
      sed 's/^/[smoke-evaluation]   /' "${response_body}" >&2
      fail "Auto-consumed evaluation reached terminal status ${evaluation_status}."
    fi
  fi
  [[ "${attempt}" == 108 ]] || sleep 5
done
[[ -n "${evaluation_id}" && "${evaluation_status}" == passed ]] || fail "Timed out waiting for auto-consumed evaluation to pass; no manual endpoint was called."

api GET "/api/evaluations/${evaluation_id}" "${student_token}"
require_ok "Read final evaluation"
jq -e '.success == true and .data.status == "passed" and .data.passed == true and ((.data.score | tonumber) == (.data.maxScore | tonumber))' "${response_body}" >/dev/null \
  || fail "Final evaluation is not passed with full score."
if [[ -n "${EVAL_RUBRIC_JSON}" ]]; then
  jq -e '
    .data.scoringMode == "weighted_rubric" and
    ((.data.maxScore | tonumber) == ([inputs.criteria[].maxScore] | add))
  ' "${response_body}" "${EVAL_RUBRIC_JSON}" >/dev/null \
    || fail "Final evaluation does not expose the expected weighted rubric scoring mode and maximum."
else
  jq -e '.data.scoringMode == "equal_assertions" and ((.data.maxScore | tonumber) == 100)' \
    "${response_body}" >/dev/null || fail "Equal-assertion fallback scoring metadata is incorrect."
fi

db_result=""
for attempt in $(seq 1 15); do
  db_result="$(docker compose --profile app exec -T postgres psql -At -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-ags}" -d "${POSTGRES_DB:-ags}" -c "SELECT (report_object_key IS NOT NULL AND newman_report_object_key IS NOT NULL AND logs_object_key IS NOT NULL)::text, (SELECT (routing_key = 'evaluation.completed.v1' AND published_at IS NOT NULL)::text FROM evaluation.outbox_events WHERE event_type = 'EvaluationCompleted' AND payload->>'evaluationId' = '${evaluation_id}' ORDER BY occurred_at DESC LIMIT 1) FROM evaluation.evaluations WHERE id = '${evaluation_id}'::uuid;")"
  [[ "${db_result}" == 'true|true' ]] && break
  [[ "${attempt}" == 15 ]] || sleep 2
done
[[ "${db_result}" == 'true|true' ]] || fail "Evaluation artifacts or published EvaluationCompleted outbox record were not verified (DB: ${db_result:-no row})."

api GET "/api/evaluations/${evaluation_id}/report" "${student_token}"
require_ok "Get evaluation report URL"
report_url="$(jq -r '.data.reportUrl // empty' "${response_body}")"
[[ -n "${report_url}" ]] || fail "Evaluation report URL was not returned."
curl -fsS -o "${tmp_dir}/report.json" "${report_url}" || fail "Could not download evaluation report."
jq -e '.reportObjectKey != null and .newmanReportObjectKey != null and .logsObjectKey != null' "${tmp_dir}/report.json" >/dev/null || fail "Evaluation report is missing artifact keys."
if [[ -n "${EVAL_RUBRIC_JSON}" ]]; then
  jq -e '
    .scoring.mode == "weighted_rubric" and
    (.scoring.criteria | length) == (inputs.criteria | length) and
    ([.scoring.criteria[].earnedScore] | add) == .scoring.maxScore
  ' "${tmp_dir}/report.json" "${EVAL_RUBRIC_JSON}" >/dev/null \
    || fail "Evaluation report is missing the weighted criteria breakdown."
fi

docker run --rm --network ags-network -v "${tmp_dir}:/out" --entrypoint /bin/sh minio/mc -ec "mc alias set local http://minio:9000 '${S3_ACCESS_KEY:-ags}' '${S3_SECRET_KEY:-ags_password}' >/dev/null && mc cp 'local/evaluation-reports/evaluations/${evaluation_id}/newman-report.json' /out/newman-report.json >/dev/null" \
  || fail "Could not retrieve newman-report.json from evaluation-reports."
newman_requests="$(jq -r '.run.stats.requests.total // empty' "${newman_report}")"
newman_assertions="$(jq -r '.run.stats.assertions.total // empty' "${newman_report}")"
newman_failures="$(jq -r '.run.stats.assertions.failed // empty' "${newman_report}")"
[[ "${newman_requests}" == "${EVAL_EXPECTED_REQUESTS}" && "${newman_assertions}" == "${EVAL_EXPECTED_ASSERTIONS}" && "${newman_failures}" == 0 ]] || fail "Unexpected Newman results: ${newman_requests} requests / ${newman_assertions} assertions / ${newman_failures} failures."

if docker ps -a --format '{{.Names}}' | grep -Eq '^evalcore-' || docker network ls --format '{{.Name}}' | grep -Eq '^evalcore-' || docker volume ls --format '{{.Name}}' | grep -Eq '^evalcore-'; then
  fail "Evaluation sandbox cleanup left evalcore containers, networks, or volumes."
fi

log '============================================================'
log 'Evaluation smoke passed.'
log "Class ID: ${class_id}"
log "Lab ID: ${lab_id}"
log "Submission ID: ${submission_id}"
log "Evaluation ID: ${evaluation_id}"
log "Scoring mode: ${evaluation_scoring_mode}"
log "Score: ${evaluation_score} / ${evaluation_max_score}"
log "Newman: ${newman_requests} requests / ${newman_assertions} assertions / ${newman_failures} failures"
log '============================================================'
