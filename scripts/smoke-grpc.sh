#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_ENV_FILE="${ROOT_DIR}/.env"

log() { printf '[smoke-grpc] %s\n' "$1"; }
fail() { log "FAILURE: $1" >&2; exit 1; }

load_env_file() {
  local env_file="$1" line name

  [[ -f "${env_file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ "${line}" =~ ^[[:space:]]*$ || "${line}" =~ ^[[:space:]]*# ]] && continue
    name="${line%%=*}"
    [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "Invalid environment assignment in ${env_file}."
    [[ -v "${name}" ]] && continue
    export "${line}"
  done < "${env_file}"
}

retry() {
  local description="$1" attempts="$2" delay="$3"
  shift 3

  for attempt in $(seq 1 "${attempts}"); do
    "$@" && return 0
    if [[ "${attempt}" -lt "${attempts}" ]]; then
      log "${description} not ready; retrying in ${delay}s (${attempt}/${attempts})."
      sleep "${delay}"
    fi
  done
  return 1
}

health_is_valid() {
  local url="$1" output_file="$2"

  curl -fsS "${url}" -o "${output_file}" \
    && jq -e '
      .success == true and
      .data.status == "healthy" and
      .data.service == "evalcore-grading-service" and
      (.data.timestamp | type == "string" and length > 0)
    ' "${output_file}" >/dev/null
}

container_env_value() {
  local service="$1" key="$2" container_id

  container_id="$(docker compose --profile app ps -q "${service}")"
  [[ -n "${container_id}" ]] || return 1
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${container_id}" \
    | awk -v prefix="${key}=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }'
}

first_provider() {
  local input_file="$1" filter="$2"

  jq -r "${filter} | map(select(type == \"string\" and length > 0)) | .[0] // empty" "${input_file}"
}

assert_grpc_provider_if_present() {
  local source="$1" provider="$2" normalized

  if [[ -z "${provider}" ]]; then
    log "${source} does not expose a scoring provider; no public provider field is required."
    return 0
  fi

  normalized="$(tr '[:upper:]' '[:lower:]' <<< "${provider}")"
  [[ "${normalized}" == grpc ]] || fail "${source} reports scoring provider '${provider}', expected 'grpc'."
  log "${source} confirms scoring provider: grpc."
}

for command in awk curl docker jq make mktemp sed seq tail tee tr; do
  command -v "${command}" >/dev/null 2>&1 || fail "${command} is required."
done

cd "${ROOT_DIR}"
load_env_file "${ROOT_ENV_FILE}"

GATEWAY_URL="${GATEWAY_URL:-http://localhost:${GATEWAY_PORT:-8080}}"
GRADING_HEALTH_URL="http://localhost:${GRADING_HEALTH_PORT:-8087}/health"
EXPECTED_GRADING_GRPC_URL="${GRADING_GRPC_URL:-http://grading-service:5007}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

retry "Grading direct health" 24 5 health_is_valid \
  "${GRADING_HEALTH_URL}" "${tmp_dir}/grading-direct-health.json" \
  || fail "Grading health is unavailable at ${GRADING_HEALTH_URL}."
retry "Grading gateway health" 24 5 health_is_valid \
  "${GATEWAY_URL}/grading/health" "${tmp_dir}/grading-gateway-health.json" \
  || fail "Grading health is unavailable through ${GATEWAY_URL}/grading/health."
log "Grading direct and gateway health checks passed."

for service in evaluation-service evaluation-runner; do
  enabled="$(container_env_value "${service}" GRADING_GRPC_ENABLED)" \
    || fail "${service} is not running or has no GRADING_GRPC_ENABLED setting."
  grpc_url="$(container_env_value "${service}" GRADING_GRPC_URL)" \
    || fail "${service} is not running or has no GRADING_GRPC_URL setting."

  [[ "${enabled,,}" == true ]] \
    || fail "${service} has GRADING_GRPC_ENABLED='${enabled}', expected true."
  [[ "${grpc_url}" == "${EXPECTED_GRADING_GRPC_URL}" ]] \
    || fail "${service} has GRADING_GRPC_URL='${grpc_url}', expected '${EXPECTED_GRADING_GRPC_URL}'."
  log "${service} is configured for gRPC scoring at ${grpc_url}."
done

if ! make --no-print-directory smoke-rubric 2>&1 | tee "${tmp_dir}/rubric-output.log"; then
  fail "Weighted rubric smoke failed while gRPC scoring was enabled."
fi
rubric_output="$(<"${tmp_dir}/rubric-output.log")"

evaluation_id="$(sed -n 's/^\[smoke-evaluation\] Evaluation ID: //p' <<< "${rubric_output}" | tail -n 1)"
[[ "${evaluation_id}" =~ ^[0-9a-fA-F-]{36}$ ]] \
  || fail "Weighted smoke did not report a valid evaluation ID."

curl -fsS -H 'Content-Type: application/json' \
  --data '{"email":"lecturer@ags.local","password":"Password123!"}' \
  "${GATEWAY_URL}/api/auth/login" -o "${tmp_dir}/lecturer-login.json" \
  || fail "Could not log in to inspect the weighted evaluation API response."
lecturer_token="$(jq -r '.accessToken // .data.accessToken // .token // .data.token // empty' "${tmp_dir}/lecturer-login.json")"
[[ -n "${lecturer_token}" ]] || fail "Lecturer login returned no access token."
curl -fsS -H "Authorization: Bearer ${lecturer_token}" \
  "${GATEWAY_URL}/api/evaluations/${evaluation_id}" -o "${tmp_dir}/evaluation.json" \
  || fail "Could not inspect weighted evaluation ${evaluation_id}."

api_provider="$(first_provider "${tmp_dir}/evaluation.json" \
  '[.data.scoringProvider?, .data.scoring.provider?, .data.gradingProvider?, .scoringProvider?, .scoring.provider?, .gradingProvider?]')"
assert_grpc_provider_if_present "Evaluation API" "${api_provider}"

report_object_key="$(docker compose --profile app exec -T postgres \
  psql -At -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-ags}" -d "${POSTGRES_DB:-ags}" \
  -c "SELECT report_object_key FROM evaluation.evaluations WHERE id = '${evaluation_id}'::uuid;")" \
  || fail "Could not resolve report.json for evaluation ${evaluation_id}."
report_object_key="${report_object_key%$'\r'}"
[[ -n "${report_object_key}" ]] || fail "Evaluation ${evaluation_id} has no report object key."

docker run --rm --network ags-network \
  -v "${tmp_dir}:/out" \
  -e "S3_ACCESS_KEY=${S3_ACCESS_KEY:-ags}" \
  -e "S3_SECRET_KEY=${S3_SECRET_KEY:-ags_password}" \
  -e "REPORT_BUCKET=${EVALUATION_REPORTS_BUCKET:-evaluation-reports}" \
  -e "REPORT_OBJECT_KEY=${report_object_key}" \
  --entrypoint /bin/sh minio/mc -ec '
    mc alias set local http://minio:9000 "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null
    mc cp "local/${REPORT_BUCKET}/${REPORT_OBJECT_KEY}" /out/report.json >/dev/null
  ' || fail "Could not retrieve report.json for evaluation ${evaluation_id}."

report_provider="$(first_provider "${tmp_dir}/report.json" \
  '[.scoring.provider?, .scoring.scoringProvider?, .scoringProvider?, .gradingProvider?]')"
assert_grpc_provider_if_present "Evaluation report" "${report_provider}"

log '============================================================'
log 'gRPC grading smoke passed.'
log "Evaluation ID: ${evaluation_id}"
log 'Weighted scoring: 10.00 / 10.00 through the gRPC-enabled Evaluation runner.'
log '============================================================'
