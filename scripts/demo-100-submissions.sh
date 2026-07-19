#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_ENV_FILE="${ROOT_DIR}/.env"

log() { printf '[demo-100] %s\n' "$1"; }
fail() { log "FAILURE: $1" >&2; exit 1; }

VARIANT_NAMES=(
  pass
  fail-swagger
  fail-pagination
  fail-response-format
  fail-multiple-criteria
  readiness-error
  build-error
  invalid-compose
)
VARIANT_PERCENTAGES=(60 8 10 8 6 4 2 2)
declare -a VARIANT_COUNTS=()
declare -a DEMO_ASSIGNMENT_VARIANTS=()
declare -a DEMO_ASSIGNMENT_ZIPS=()
EXPECTED_PASSED=0
EXPECTED_FAILED=0
EXPECTED_ERROR=0

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

require_positive_integer() {
  local name="$1" value="$2"
  [[ "${value}" =~ ^[0-9]+$ && "${value}" -gt 0 ]] || fail "${name} must be a positive integer (received '${value}')."
}

is_2xx() {
  [[ "${HTTP_STATUS:-}" =~ ^2[0-9][0-9]$ ]]
}

response_error() {
  local response_file="$1"
  jq -r '
    [(.error.code // .code // "unknown_error"), (.error.message // .message // "request failed")]
    | join(": ")
  ' "${response_file}" 2>/dev/null || printf 'unreadable error response'
}

request() {
  local method="$1" path="$2" token="$3" body_file="$4" output_file="$5"
  local -a args=(
    -sS
    --connect-timeout "${DEMO_CURL_CONNECT_TIMEOUT_SECONDS}"
    --max-time "${DEMO_CURL_API_TIMEOUT_SECONDS}"
    -o "${output_file}"
    -w '%{http_code}'
    -X "${method}"
  )

  [[ -n "${token}" ]] && args+=(-H "Authorization: Bearer ${token}")
  if [[ -n "${body_file}" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@${body_file}")
  fi

  HTTP_STATUS="$(curl "${args[@]}" "${GATEWAY_URL}${path}")" || HTTP_STATUS=000
}

require_request_ok() {
  local description="$1" response_file="$2"
  if ! is_2xx; then
    log "${description} failed with HTTP ${HTTP_STATUS:-000} ($(response_error "${response_file}"))" >&2
    return 1
  fi
}

put_file() {
  local source_file="$1" upload_url="$2" output_file="$3"
  HTTP_STATUS="$(curl -sS \
    --connect-timeout "${DEMO_CURL_CONNECT_TIMEOUT_SECONDS}" \
    --max-time "${DEMO_CURL_UPLOAD_TIMEOUT_SECONDS}" \
    -o "${output_file}" \
    -w '%{http_code}' \
    -X PUT \
    --upload-file "${source_file}" \
    "${upload_url}")" || HTTP_STATUS=000
}

retry_health() {
  local url="$1" description="$2"
  local attempt

  for attempt in $(seq 1 36); do
    if curl -fsS \
      --connect-timeout "${DEMO_CURL_CONNECT_TIMEOUT_SECONDS}" \
      --max-time "${DEMO_CURL_HEALTH_TIMEOUT_SECONDS}" \
      "${url}" >/dev/null; then
      return 0
    fi
    [[ "${attempt}" == 36 ]] || sleep 5
  done

  fail "${description} is not reachable at ${url}."
}

is_local_gateway_url() {
  local url="$1" authority port

  [[ "${url}" == http://* || "${url}" == https://* ]] || return 1
  authority="${url#*://}"
  authority="${authority%%/*}"
  [[ "${authority}" != *@* ]] || return 1
  case "${authority}" in
    localhost | 127.0.0.1 | "[::1]") return 0 ;;
    localhost:* | 127.0.0.1:*) port="${authority##*:}" ;;
    "[::1]":*) port="${authority#"[::1]:"}" ;;
    *) return 1 ;;
  esac
  [[ "${port}" =~ ^[0-9]+$ ]]
}

preflight_frontend_monitor() {
  local monitor_route="${DEMO_FRONTEND_URL%/}/lecturer/live-grading" status

  status="$(curl -sS \
    --connect-timeout "${DEMO_CURL_CONNECT_TIMEOUT_SECONDS}" \
    --max-time "${DEMO_CURL_API_TIMEOUT_SECONDS}" \
    -o /dev/null \
    -w '%{http_code}' \
    "${monitor_route}")" || status=000
  [[ "${status}" =~ ^[23][0-9][0-9]$ ]] \
    || fail "Frontend live monitor is not reachable at ${monitor_route} (HTTP ${status}). Start the lecturer frontend before running the demo."
  log "Frontend live monitor preflight passed: ${monitor_route} (HTTP ${status})."
}

check_required_services() {
  retry_health "${GATEWAY_URL}/health" "Gateway"
  retry_health "${GATEWAY_URL}/identity/health" "Identity Service"
  retry_health "${GATEWAY_URL}/class/health" "Class Service"
  retry_health "${GATEWAY_URL}/submission/health" "Submission Service"
  retry_health "${GATEWAY_URL}/evaluation/health" "Evaluation Service"
  retry_health "${GATEWAY_URL}/grading/health" "Grading Service"
  retry_health "${GATEWAY_URL}/notification/health" "Notification Service"
}

validate_submission_zip() {
  local zip_file="$1" require_root_compose="$2" entry compose_entry="" root_compose_count=0
  local -a zip_entries

  [[ -f "${zip_file}" ]] || fail "Submission variant not found: ${zip_file}"
  unzip -tqq "${zip_file}" >/dev/null || fail "Submission variant is not a valid ZIP: ${zip_file}"
  mapfile -t zip_entries < <(unzip -Z1 "${zip_file}")
  (( ${#zip_entries[@]} > 0 )) || fail "Submission variant is empty: ${zip_file}"

  for entry in "${zip_entries[@]}"; do
    case "${entry}" in
      /* | .. | ../* | */../* | */.. | *\\*)
        fail "Submission variant contains an unsafe path '${entry}': ${zip_file}"
        ;;
    esac
    if [[ "${entry}" == docker-compose.yml || "${entry}" == compose.yaml ]]; then
      root_compose_count=$((root_compose_count + 1))
      compose_entry="${entry}"
    fi
    if [[ "${require_root_compose}" == true \
      && ( "${entry}" == */docker-compose.yml || "${entry}" == */compose.yaml ) ]]; then
      fail "Submission variant compose file must be at ZIP root, not ${entry}."
    fi
  done

  if [[ "${require_root_compose}" == true && "${root_compose_count}" -ne 1 ]]; then
    fail "Submission variant must contain exactly one root docker-compose.yml or compose.yaml: ${zip_file}"
  fi

  if [[ "${root_compose_count}" -eq 1 ]] && unzip -p "${zip_file}" "${compose_entry}" \
    | grep -Eqi 'privileged[[:space:]]*:|network_mode[[:space:]]*:[[:space:]]*host|/var/run/docker\.sock|pid[[:space:]]*:[[:space:]]*host|ipc[[:space:]]*:[[:space:]]*host|cap_add[[:space:]]*:|devices[[:space:]]*:|type[[:space:]]*:[[:space:]]*bind|-[[:space:]]*(/|\.\.?/)'; then
    fail "Submission variant compose file contains a forbidden host or privilege capability: ${zip_file}"
  fi
}

build_demo_assignment_plan() {
  local index raw allocated=0 remaining best best_remainder normal_failures error_results
  local student best_deficit deficit
  local -a remainders=() assigned=()

  for index in "${!VARIANT_NAMES[@]}"; do
    VARIANT_COUNTS[index]=0
    assigned[index]=0
  done

  if [[ "${DEMO_VARIANT_MODE}" == uniform ]]; then
    VARIANT_COUNTS[0]="${DEMO_SUBMISSION_COUNT}"
    for student in $(seq 1 "${DEMO_SUBMISSION_COUNT}"); do
      DEMO_ASSIGNMENT_VARIANTS[student]=pass
      DEMO_ASSIGNMENT_ZIPS[student]="${EVAL_FIXTURE_ZIP}"
    done
  else
    for index in "${!VARIANT_NAMES[@]}"; do
      raw=$((DEMO_SUBMISSION_COUNT * VARIANT_PERCENTAGES[index]))
      VARIANT_COUNTS[index]=$((raw / 100))
      remainders[index]=$((raw % 100))
      allocated=$((allocated + VARIANT_COUNTS[index]))
    done

    remaining=$((DEMO_SUBMISSION_COUNT - allocated))
    while (( remaining > 0 )); do
      best=-1
      best_remainder=-1
      for index in "${!VARIANT_NAMES[@]}"; do
        if (( remainders[index] > best_remainder )); then
          best="${index}"
          best_remainder="${remainders[index]}"
        fi
      done
      (( best >= 0 )) || fail "Could not apportion the mixed variant distribution."
      VARIANT_COUNTS[best]=$((VARIANT_COUNTS[best] + 1))
      remainders[best]=-1
      remaining=$((remaining - 1))
    done

    if (( DEMO_SUBMISSION_COUNT >= ${#VARIANT_NAMES[@]} )); then
      for index in "${!VARIANT_NAMES[@]}"; do
        (( VARIANT_COUNTS[index] == 0 )) || continue
        best=-1
        best_remainder=1
        for allocated in "${!VARIANT_NAMES[@]}"; do
          if (( VARIANT_COUNTS[allocated] > best_remainder )); then
            best="${allocated}"
            best_remainder="${VARIANT_COUNTS[allocated]}"
          fi
        done
        (( best >= 0 )) \
          || fail "Could not include every variant in a ${DEMO_SUBMISSION_COUNT}-submission mixed demo."
        VARIANT_COUNTS[best]=$((VARIANT_COUNTS[best] - 1))
        VARIANT_COUNTS[index]=1
      done
    fi

    normal_failures=$((
      VARIANT_COUNTS[1] + VARIANT_COUNTS[2] + VARIANT_COUNTS[3] + VARIANT_COUNTS[4]
    ))
    if (( DEMO_SUBMISSION_COUNT >= 2 && normal_failures == 0 )); then
      (( VARIANT_COUNTS[0] > 1 )) \
        || fail "Could not reserve a normal assertion failure in the mixed distribution."
      VARIANT_COUNTS[0]=$((VARIANT_COUNTS[0] - 1))
      VARIANT_COUNTS[2]=$((VARIANT_COUNTS[2] + 1))
    fi

    error_results=$((VARIANT_COUNTS[5] + VARIANT_COUNTS[6] + VARIANT_COUNTS[7]))
    if (( DEMO_SUBMISSION_COUNT >= 3 && error_results == 0 )); then
      if (( VARIANT_COUNTS[0] > 1 )); then
        VARIANT_COUNTS[0]=$((VARIANT_COUNTS[0] - 1))
      elif (( VARIANT_COUNTS[2] > 1 )); then
        VARIANT_COUNTS[2]=$((VARIANT_COUNTS[2] - 1))
      else
        fail "Could not reserve an infrastructure error in the mixed distribution."
      fi
      VARIANT_COUNTS[5]=$((VARIANT_COUNTS[5] + 1))
    fi

    allocated=0
    for index in "${!VARIANT_NAMES[@]}"; do
      allocated=$((allocated + VARIANT_COUNTS[index]))
    done
    (( allocated == DEMO_SUBMISSION_COUNT )) \
      || fail "Mixed variant distribution totals ${allocated}, expected ${DEMO_SUBMISSION_COUNT}."

    # Largest cumulative deficit keeps the deterministic exact allocation
    # interleaved instead of front-loading all failures and errors.
    for student in $(seq 1 "${DEMO_SUBMISSION_COUNT}"); do
      best=-1
      best_deficit=-9223372036854775807
      for index in "${!VARIANT_NAMES[@]}"; do
        (( assigned[index] < VARIANT_COUNTS[index] )) || continue
        deficit=$((student * VARIANT_COUNTS[index] - assigned[index] * DEMO_SUBMISSION_COUNT))
        if (( deficit > best_deficit )); then
          best="${index}"
          best_deficit="${deficit}"
        fi
      done
      (( best >= 0 )) || fail "Could not assign submission variant ${student}."
      DEMO_ASSIGNMENT_VARIANTS[student]="${VARIANT_NAMES[best]}"
      DEMO_ASSIGNMENT_ZIPS[student]="${DEMO_VARIANTS_DIR}/${VARIANT_NAMES[best]}.zip"
      assigned[best]=$((assigned[best] + 1))
    done
  fi

  EXPECTED_PASSED="${VARIANT_COUNTS[0]}"
  EXPECTED_FAILED=$((
    VARIANT_COUNTS[1] + VARIANT_COUNTS[2] + VARIANT_COUNTS[3] + VARIANT_COUNTS[4]
  ))
  EXPECTED_ERROR=$((VARIANT_COUNTS[5] + VARIANT_COUNTS[6] + VARIANT_COUNTS[7]))
}

print_demo_assignment_plan() {
  local index

  log "Variant mode: ${DEMO_VARIANT_MODE}"
  log "${DEMO_SUBMISSION_COUNT} students will each submit one ZIP."
  log "Distribution:"
  for index in "${!VARIANT_NAMES[@]}"; do
    log "${VARIANT_NAMES[index]}: ${VARIANT_COUNTS[index]}"
  done
  log "Expected terminal results: passed=${EXPECTED_PASSED}, failed=${EXPECTED_FAILED}, error=${EXPECTED_ERROR}."
}

run_bounded() {
  local worker="$1" count="$2" concurrency="$3"
  local index active=0 failures=0

  for index in $(seq 1 "${count}"); do
    "${worker}" "${index}" &
    ((active += 1))

    if (( active >= concurrency )); then
      if ! wait -n; then
        failures=1
      fi
      active=$((active - 1))
    fi
  done

  while (( active > 0 )); do
    if ! wait -n; then
      failures=1
    fi
    active=$((active - 1))
  done

  return "${failures}"
}

prepare_student() {
  local index="$1" padded student_dir email full_name token student_id submission_id upload_url
  local variant_name submission_zip
  local request_file response_file

  printf -v padded '%03d' "${index}"
  student_dir="${STUDENTS_DIR}/${padded}"
  mkdir -p "${student_dir}"
  variant_name="${DEMO_ASSIGNMENT_VARIANTS[index]}"
  submission_zip="${DEMO_ASSIGNMENT_ZIPS[index]}"
  email="evalcore-demo-${RUN_ID}-${padded}@ags.local"
  full_name="EvalCore Burst Student ${padded}"
  request_file="${student_dir}/request.json"
  response_file="${student_dir}/response.json"

  jq -n \
    --arg fullName "${full_name}" \
    --arg email "${email}" \
    --arg password "${DEMO_STUDENT_PASSWORD}" \
    '{fullName:$fullName,email:$email,password:$password,role:"student"}' > "${request_file}"
  request POST /api/auth/register "" "${request_file}" "${response_file}"
  require_request_ok "Register student ${padded}" "${response_file}" || return 1

  jq -n --arg email "${email}" --arg password "${DEMO_STUDENT_PASSWORD}" \
    '{email:$email,password:$password}' > "${request_file}"
  request POST /api/auth/login "" "${request_file}" "${response_file}"
  require_request_ok "Login student ${padded}" "${response_file}" || return 1
  if ! token="$(jq -er '.data.accessToken // .accessToken // .data.token // .token' "${response_file}")"; then
    log "Login student ${padded} returned no access token." >&2
    return 1
  fi
  if ! student_id="$(jq -er '.data.user.id // .user.id' "${response_file}")"; then
    log "Login student ${padded} returned no student ID." >&2
    return 1
  fi
  printf '%s' "${token}" > "${student_dir}/token"
  printf '%s' "${student_id}" > "${student_dir}/student-id"
  printf '%s' "${email}" > "${student_dir}/email"
  printf '%s' "${variant_name}" > "${student_dir}/variant"

  request POST "/api/classes/${CLASS_ID}/join" "${token}" "" "${response_file}"
  require_request_ok "Join class for student ${padded}" "${response_file}" || return 1

  jq -n --arg filename "$(basename "${submission_zip}")" \
    --arg notes "EvalCore weighted demo ${RUN_ID}; variant=${variant_name}" \
    '{projectFileName:$filename,notes:$notes}' > "${request_file}"
  request POST "/api/labs/${LAB_ID}/submissions" "${token}" "${request_file}" "${response_file}"
  require_request_ok "Create submission for student ${padded}" "${response_file}" || return 1
  if ! submission_id="$(jq -er '.data.submission.id // .submission.id' "${response_file}")"; then
    log "Create submission for student ${padded} returned no submission ID." >&2
    return 1
  fi
  if ! upload_url="$(jq -er '.data.upload.projectUploadUrl // .upload.projectUploadUrl' "${response_file}")"; then
    log "Create submission for student ${padded} returned no upload URL." >&2
    return 1
  fi

  put_file "${submission_zip}" "${upload_url}" "${student_dir}/upload-response.txt"
  if ! is_2xx; then
    log "Upload submission for student ${padded} failed with HTTP ${HTTP_STATUS:-000}." >&2
    return 1
  fi

  printf '%s' "${submission_id}" > "${student_dir}/submission-id"
  : > "${student_dir}/prepared"
  log "Prepared ${index}/${DEMO_SUBMISSION_COUNT}: student ${student_id}, submission ${submission_id}, variant ${variant_name}"
}

assert_unique_prepared_records() {
  local field index padded value total unique values_file

  for field in email student-id submission-id; do
    values_file="${TMP_DIR}/${field}-values.txt"
    : > "${values_file}"
    for index in $(seq 1 "${DEMO_SUBMISSION_COUNT}"); do
      printf -v padded '%03d' "${index}"
      [[ -s "${STUDENTS_DIR}/${padded}/${field}" ]] \
        || fail "Student ${padded} is missing ${field} proof."
      value="$(<"${STUDENTS_DIR}/${padded}/${field}")"
      printf '%s\n' "${value}" >> "${values_file}"
    done
    total="$(awk 'END { print NR + 0 }' "${values_file}")"
    unique="$(sort -u "${values_file}" | awk 'END { print NR + 0 }')"
    if (( total != DEMO_SUBMISSION_COUNT || unique != DEMO_SUBMISSION_COUNT )); then
      fail "Expected ${DEMO_SUBMISSION_COUNT} unique ${field} values, found ${unique}/${total}."
    fi
  done

  log "Verified ${DEMO_SUBMISSION_COUNT} unique emails, student IDs, and submission IDs."
}

complete_submission() {
  local index="$1" padded student_dir token submission_id response_file request_file status

  printf -v padded '%03d' "${index}"
  student_dir="${STUDENTS_DIR}/${padded}"
  token="$(<"${student_dir}/token")"
  submission_id="$(<"${student_dir}/submission-id")"
  response_file="${student_dir}/complete-response.json"
  request_file="${student_dir}/complete-request.json"
  printf '{"projectUploaded":true}\n' > "${request_file}"

  request POST "/api/submissions/${submission_id}/assets/complete" "${token}" "${request_file}" "${response_file}"
  require_request_ok "Complete submission ${submission_id}" "${response_file}" || return 1
  status="$(jq -r '.data.status // .status // empty' "${response_file}")"
  if [[ "${status}" != submitted ]]; then
    log "Submission ${submission_id} completed with unexpected status '${status:-missing}'." >&2
    return 1
  fi

  request GET "/api/submissions/${submission_id}" "${token}" "" "${response_file}"
  require_request_ok "Verify submission ${submission_id}" "${response_file}" || return 1
  status="$(jq -r '.data.status // .status // empty' "${response_file}")"
  if [[ "${status}" != submitted ]]; then
    log "Submission ${submission_id} did not remain submitted (status '${status:-missing}')." >&2
    return 1
  fi

  : > "${student_dir}/submitted"
  log "Submitted ${index}/${DEMO_SUBMISSION_COUNT}: ${submission_id}"
}

fetch_overview() {
  request GET "/api/evaluations/monitor/overview?labId=${LAB_ID}" "${LECTURER_TOKEN}" "" "${OVERVIEW_RESPONSE}"
  require_request_ok "Read evaluation monitor overview" "${OVERVIEW_RESPONSE}"
}

fetch_recent_evaluations() {
  request GET "/api/evaluations/monitor/recent?labId=${LAB_ID}&limit=${DEMO_SUBMISSION_COUNT}" \
    "${LECTURER_TOKEN}" "" "${RECENT_RESPONSE}"
  require_request_ok "Read recent weighted evaluations" "${RECENT_RESPONSE}"
}

expected_status_for_variant() {
  case "$1" in
    pass) printf 'passed\n' ;;
    fail-swagger | fail-pagination | fail-response-format | fail-multiple-criteria) printf 'failed\n' ;;
    readiness-error | build-error | invalid-compose) printf 'error\n' ;;
    *) return 1 ;;
  esac
}

expected_score_for_variant() {
  case "$1" in
    pass) printf '10.0\n' ;;
    fail-swagger) printf '9.5\n' ;;
    fail-pagination) printf '9.6\n' ;;
    fail-response-format) printf '9.2\n' ;;
    fail-multiple-criteria) printf '6.8\n' ;;
    readiness-error | build-error | invalid-compose) printf '0.0\n' ;;
    *) return 1 ;;
  esac
}

expected_error_code_for_variant() {
  case "$1" in
    fail-swagger | fail-pagination | fail-response-format | fail-multiple-criteria) printf 'NEWMAN_RUN_FAILED\n' ;;
    readiness-error) printf 'APP_READINESS_FAILED\n' ;;
    build-error) printf 'COMPOSE_BUILD_FAILED\n' ;;
    invalid-compose) printf 'COMPOSE_VALIDATION_FAILED\n' ;;
    pass) printf '\n' ;;
    *) return 1 ;;
  esac
}

assert_terminal_weighted_results() {
  local index padded submission_id variant expected_status expected_score expected_error_code
  local match_count row actual_status score max_score error_code
  local -A printed_variants=()

  if (( DEMO_SUBMISSION_COUNT > 100 )); then
    log "Skipping per-evaluation result proof because the monitor recent endpoint is capped at 100 rows."
    return 0
  fi

  fetch_recent_evaluations || return 1
  jq -e --argjson expected "${DEMO_SUBMISSION_COUNT}" '
    (.data // .) as $items
    | ($items | type) == "array" and
      ($items | length) == $expected and
      all($items[];
        .scoringMode == "weighted_rubric" and
        ((.maxScore | tonumber) == 10))
  ' "${RECENT_RESPONSE}" >/dev/null \
    || { log "Recent results do not contain exactly ${DEMO_SUBMISSION_COUNT} weighted 10-point evaluations." >&2; return 1; }

  for index in $(seq 1 "${DEMO_SUBMISSION_COUNT}"); do
    printf -v padded '%03d' "${index}"
    submission_id="$(<"${STUDENTS_DIR}/${padded}/submission-id")"
    variant="$(<"${STUDENTS_DIR}/${padded}/variant")"
    expected_status="$(expected_status_for_variant "${variant}")" \
      || { log "Unknown recorded variant '${variant}' for student ${padded}." >&2; return 1; }
    expected_score="$(expected_score_for_variant "${variant}")" \
      || { log "No expected score is defined for variant '${variant}'." >&2; return 1; }
    expected_error_code="$(expected_error_code_for_variant "${variant}")" \
      || { log "No expected error code is defined for variant '${variant}'." >&2; return 1; }
    match_count="$(jq -er --arg submissionId "${submission_id}" '
      [(.data // .)[] | select(.submissionId == $submissionId)] | length
    ' "${RECENT_RESPONSE}")" \
      || { log "Could not inspect recent results for submission ${submission_id}." >&2; return 1; }
    [[ "${match_count}" == 1 ]] \
      || { log "Expected one recent result for submission ${submission_id}, found ${match_count}." >&2; return 1; }
    row="$(jq -cer --arg submissionId "${submission_id}" '
      [(.data // .)[] | select(.submissionId == $submissionId)][0]
    ' "${RECENT_RESPONSE}")"
    actual_status="$(jq -r '.status' <<< "${row}")"
    if [[ "${actual_status}" != "${expected_status}" ]]; then
      log "Variant ${variant} produced '${actual_status}', expected '${expected_status}' (submission ${submission_id})." >&2
      return 1
    fi

    case "${expected_status}" in
      passed)
        jq -e --arg expectedScore "${expected_score}" \
          '(.score | tonumber) == ($expectedScore | tonumber) and .errorCode == null' \
          <<< "${row}" >/dev/null \
          || { log "Variant ${variant} did not produce expected score ${expected_score} without an error code." >&2; return 1; }
        ;;
      failed)
        jq -e --arg expectedScore "${expected_score}" --arg expectedErrorCode "${expected_error_code}" \
          '(.score | tonumber) == ($expectedScore | tonumber) and .errorCode == $expectedErrorCode' \
          <<< "${row}" >/dev/null \
          || { log "Variant ${variant} did not produce score ${expected_score} and error ${expected_error_code}." >&2; return 1; }
        ;;
      error)
        jq -e --arg expectedScore "${expected_score}" --arg expectedErrorCode "${expected_error_code}" \
          '(.score | tonumber) == ($expectedScore | tonumber) and .errorCode == $expectedErrorCode' \
          <<< "${row}" >/dev/null \
          || { log "Infrastructure variant ${variant} did not produce score ${expected_score} and error ${expected_error_code}." >&2; return 1; }
        ;;
    esac

    if [[ "${printed_variants[${variant}]:-}" != true ]]; then
      score="$(jq -r '.score // "n/a"' <<< "${row}")"
      max_score="$(jq -r '.maxScore // "n/a"' <<< "${row}")"
      error_code="$(jq -r '.errorCode // "none"' <<< "${row}")"
      log "Sample ${variant}: status=${actual_status}, score=${score}/${max_score}, errorCode=${error_code}."
      printed_variants["${variant}"]=true
    fi
  done

  log "Verified every terminal result against its assigned real ZIP variant."
}

read_overview() {
  jq -er '
    (.data // .) as $o
    | [
        ($o.total // 0),
        ($o.queued // 0),
        ($o.running // 0),
        ($o.passed // 0),
        ($o.failed // 0),
        ($o.error // 0),
        ($o.terminal // (($o.passed // 0) + ($o.failed // 0) + ($o.error // 0))),
        ($o.activeSlots // 0),
        ($o.runnerConcurrency // "unknown")
      ]
    | @tsv
  ' "${OVERVIEW_RESPONSE}"
}

wait_for_monitor_intake() {
  local deadline=$((SECONDS + DEMO_MONITOR_TIMEOUT_SECONDS))
  local fields total queued running passed failed error terminal active_slots runner_concurrency last_total=-1

  while (( SECONDS < deadline )); do
    fetch_overview || return 1
    fields="$(read_overview)" || return 1
    IFS=$'\t' read -r total queued running passed failed error terminal active_slots runner_concurrency <<< "${fields}"

    if [[ "${total}" != "${last_total}" ]]; then
      log "Evaluation intake: total=${total}/${DEMO_SUBMISSION_COUNT}, queued=${queued}, running=${running}, terminal=${terminal}, activeSlots=${active_slots}, runnerConcurrency=${runner_concurrency}"
      last_total="${total}"
    fi
    if (( total > DEMO_SUBMISSION_COUNT )); then
      log "Monitor observed ${total} evaluations for ${DEMO_SUBMISSION_COUNT} one-time submissions." >&2
      return 1
    fi
    if (( total == DEMO_SUBMISSION_COUNT )); then
      return 0
    fi
    sleep "${DEMO_MONITOR_POLL_SECONDS}"
  done

  log "Timed out after ${DEMO_MONITOR_TIMEOUT_SECONDS}s waiting for ${DEMO_SUBMISSION_COUNT} evaluations to enter the DB waiting room." >&2
  return 1
}

assert_monitor_pacing() {
  local fields total queued running passed failed error terminal active_slots runner_concurrency

  fetch_overview || return 1
  fields="$(read_overview)" || return 1
  IFS=$'\t' read -r total queued running passed failed error terminal active_slots runner_concurrency <<< "${fields}"

  if [[ ! "${runner_concurrency}" =~ ^[0-9]+$ ]] || (( runner_concurrency < 1 )); then
    log "Monitor did not report a positive numeric runnerConcurrency ('${runner_concurrency}'); pacing cannot be verified." >&2
    return 1
  fi
  if (( runner_concurrency != DEMO_EXPECTED_RUNNER_CONCURRENCY )); then
    log "Monitor runnerConcurrency is ${runner_concurrency}, expected ${DEMO_EXPECTED_RUNNER_CONCURRENCY}." >&2
    return 1
  fi
  if (( running > runner_concurrency )); then
    log "Scoped running count ${running} exceeds runnerConcurrency ${runner_concurrency}." >&2
    return 1
  fi
  if (( active_slots > runner_concurrency )); then
    log "Global activeSlots ${active_slots} exceeds runnerConcurrency ${runner_concurrency}." >&2
    return 1
  fi

  VERIFIED_RUNNER_CONCURRENCY="${runner_concurrency}"
  VERIFIED_ACTIVE_SLOTS="${active_slots}"
  log "Runner pacing verified: scoped running=${running}, global activeSlots=${active_slots}, runnerConcurrency=${runner_concurrency}."
}

inspect_local_sandboxes() {
  local runner_concurrency="$1" active_slots="$2" active_count running_rows exited_rows
  local row name project active_project tied_to_active active_exited_count=0
  local -a active_projects exited_sandboxes

  command -v docker >/dev/null 2>&1 || fail "docker is required to inspect local evaluation sandboxes."
  docker info >/dev/null 2>&1 || fail "Docker is unavailable; local sandbox pacing cannot be verified."

  running_rows="$(docker ps --format '{{.Names}}|{{.Label "com.docker.compose.project"}}|{{.State}}')" \
    || { log "Could not list running Docker sandboxes." >&2; return 1; }
  mapfile -t active_projects < <(
    printf '%s\n' "${running_rows}" \
      | awk -F'|' '$2 ~ /^evalcore-/ { print $2 }' \
      | sort -u
  )
  active_count="${#active_projects[@]}"
  if (( active_count > runner_concurrency )); then
    log "Active evalcore Compose projects (${active_count}) exceed runnerConcurrency ${runner_concurrency}: ${active_projects[*]}" >&2
    return 1
  fi
  if (( active_count > active_slots )); then
    log "Active evalcore Compose projects (${active_count}) exceed global activeSlots ${active_slots}: ${active_projects[*]}" >&2
    return 1
  fi

  exited_rows="$(docker ps -a --filter status=exited --format '{{.Names}}|{{.Label "com.docker.compose.project"}}')" \
    || { log "Could not list exited Docker sandboxes." >&2; return 1; }
  exited_sandboxes=()
  while IFS='|' read -r name project; do
    [[ "${name}" == evalcore-* || "${project}" == evalcore-* ]] || continue
    tied_to_active=false
    for active_project in "${active_projects[@]}"; do
      if [[ "${project}" == "${active_project}" ]]; then
        tied_to_active=true
        break
      fi
    done
    if [[ "${tied_to_active}" == true ]]; then
      active_exited_count=$((active_exited_count + 1))
    else
      exited_sandboxes+=("${name}")
    fi
  done <<< "${exited_rows}"
  if (( ${#exited_sandboxes[@]} > 0 )); then
    log "Exited evalcore sandbox containers were left behind: ${exited_sandboxes[*]}" >&2
    return 1
  fi

  if (( active_count == 0 )); then
    log "Active evalcore Compose projects: 0 (runner may still be claiming queued work)."
  else
    log "Active evalcore Compose projects: ${active_count}/${runner_concurrency} (${active_projects[*]})."
  fi
  if (( active_exited_count > 0 )); then
    log "Exited containers awaiting teardown inside active projects: ${active_exited_count}."
  fi
  log "No orphaned exited evalcore sandbox containers remain."
}

wait_for_terminal_evaluations() {
  local deadline=$((SECONDS + DEMO_WAIT_TIMEOUT_SECONDS))
  local fields total queued running passed failed error terminal active_slots runner_concurrency previous=""

  while (( SECONDS < deadline )); do
    fetch_overview || return 1
    fields="$(read_overview)" || return 1
    IFS=$'\t' read -r total queued running passed failed error terminal active_slots runner_concurrency <<< "${fields}"

    if [[ "${fields}" != "${previous}" ]]; then
      log "Evaluation progress: total=${total}, queued=${queued}, running=${running}, passed=${passed}, failed=${failed}, error=${error}, terminal=${terminal}, activeSlots=${active_slots}"
      previous="${fields}"
    fi

    if (( total > DEMO_SUBMISSION_COUNT || terminal > DEMO_SUBMISSION_COUNT )); then
      log "Monitor observed duplicate evaluation rows (total=${total}, terminal=${terminal}, expected=${DEMO_SUBMISSION_COUNT})." >&2
      return 1
    fi

    if (( total == DEMO_SUBMISSION_COUNT && terminal == DEMO_SUBMISSION_COUNT )); then
      log "Terminal results: passed=${passed}, failed=${failed}, error=${error}."
      if (( passed != EXPECTED_PASSED || failed != EXPECTED_FAILED || error != EXPECTED_ERROR )); then
        log "Terminal distribution differs from expected passed=${EXPECTED_PASSED}, failed=${EXPECTED_FAILED}, error=${EXPECTED_ERROR}." >&2
        return 1
      fi
      return 0
    fi
    sleep "${DEMO_MONITOR_POLL_SECONDS}"
  done

  log "Timed out after ${DEMO_WAIT_TIMEOUT_SECONDS}s waiting for terminal evaluations; processing continues in the background." >&2
  return 1
}

load_env_file "${ROOT_ENV_FILE}"
DEMO_SUBMISSION_COUNT="${DEMO_SUBMISSION_COUNT:-100}"
DEMO_SUBMIT_CONCURRENCY="${DEMO_SUBMIT_CONCURRENCY:-20}"
DEMO_VARIANT_MODE="${DEMO_VARIANT_MODE:-uniform}"
DEMO_VARIANTS_DIR="${DEMO_VARIANTS_DIR:-${ROOT_DIR}/../test/dist/evaluation/variants}"
DEMO_WAIT_FOR_COMPLETION="${DEMO_WAIT_FOR_COMPLETION:-false}"
DEMO_MONITOR_TIMEOUT_SECONDS="${DEMO_MONITOR_TIMEOUT_SECONDS:-300}"
DEMO_WAIT_TIMEOUT_SECONDS="${DEMO_WAIT_TIMEOUT_SECONDS:-14400}"
DEMO_MONITOR_POLL_SECONDS="${DEMO_MONITOR_POLL_SECONDS:-2}"
DEMO_EXPECTED_RUNNER_CONCURRENCY="${DEMO_EXPECTED_RUNNER_CONCURRENCY:-2}"
DEMO_ALLOW_REMOTE="${DEMO_ALLOW_REMOTE:-false}"
DEMO_CURL_CONNECT_TIMEOUT_SECONDS="${DEMO_CURL_CONNECT_TIMEOUT_SECONDS:-5}"
DEMO_CURL_API_TIMEOUT_SECONDS="${DEMO_CURL_API_TIMEOUT_SECONDS:-30}"
DEMO_CURL_UPLOAD_TIMEOUT_SECONDS="${DEMO_CURL_UPLOAD_TIMEOUT_SECONDS:-120}"
DEMO_CURL_HEALTH_TIMEOUT_SECONDS="${DEMO_CURL_HEALTH_TIMEOUT_SECONDS:-10}"
EVAL_FIXTURE_ZIP="${EVAL_FIXTURE_ZIP:-${ROOT_DIR}/../test/dist/evaluation/PRN232.LMS-Evaluation-Submission.zip}"
DEMO_RUBRIC_JSON="${DEMO_RUBRIC_JSON:-${ROOT_DIR}/fixtures/prn232-weighted-rubric.json}"

for command in awk curl jq seq sort tr unzip; do
  command -v "${command}" >/dev/null 2>&1 || fail "${command} is required."
done
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  fail "Bash 4.3 or newer is required for bounded parallel execution."
fi

require_positive_integer DEMO_SUBMISSION_COUNT "${DEMO_SUBMISSION_COUNT}"
require_positive_integer DEMO_SUBMIT_CONCURRENCY "${DEMO_SUBMIT_CONCURRENCY}"
require_positive_integer DEMO_MONITOR_TIMEOUT_SECONDS "${DEMO_MONITOR_TIMEOUT_SECONDS}"
require_positive_integer DEMO_WAIT_TIMEOUT_SECONDS "${DEMO_WAIT_TIMEOUT_SECONDS}"
require_positive_integer DEMO_MONITOR_POLL_SECONDS "${DEMO_MONITOR_POLL_SECONDS}"
require_positive_integer DEMO_EXPECTED_RUNNER_CONCURRENCY "${DEMO_EXPECTED_RUNNER_CONCURRENCY}"
require_positive_integer DEMO_CURL_CONNECT_TIMEOUT_SECONDS "${DEMO_CURL_CONNECT_TIMEOUT_SECONDS}"
require_positive_integer DEMO_CURL_API_TIMEOUT_SECONDS "${DEMO_CURL_API_TIMEOUT_SECONDS}"
require_positive_integer DEMO_CURL_UPLOAD_TIMEOUT_SECONDS "${DEMO_CURL_UPLOAD_TIMEOUT_SECONDS}"
require_positive_integer DEMO_CURL_HEALTH_TIMEOUT_SECONDS "${DEMO_CURL_HEALTH_TIMEOUT_SECONDS}"

DEMO_WAIT_FOR_COMPLETION="${DEMO_WAIT_FOR_COMPLETION,,}"
[[ "${DEMO_WAIT_FOR_COMPLETION}" == true || "${DEMO_WAIT_FOR_COMPLETION}" == false ]] \
  || fail "DEMO_WAIT_FOR_COMPLETION must be true or false."
DEMO_VARIANT_MODE="${DEMO_VARIANT_MODE,,}"
[[ "${DEMO_VARIANT_MODE}" == uniform || "${DEMO_VARIANT_MODE}" == mixed ]] \
  || fail "DEMO_VARIANT_MODE must be uniform or mixed."
DEMO_ALLOW_REMOTE="${DEMO_ALLOW_REMOTE,,}"
[[ "${DEMO_ALLOW_REMOTE}" == true || "${DEMO_ALLOW_REMOTE}" == false ]] \
  || fail "DEMO_ALLOW_REMOTE must be true or false."

GATEWAY_URL="${GATEWAY_URL:-http://localhost:${GATEWAY_PORT:-8080}}"
GATEWAY_URL="${GATEWAY_URL%/}"
DEMO_FRONTEND_URL="${DEMO_FRONTEND_URL:-http://localhost:3000}"
DEMO_LECTURER_EMAIL="${DEMO_LECTURER_EMAIL:-lecturer@ags.local}"
DEMO_LECTURER_PASSWORD="${DEMO_LECTURER_PASSWORD:-Password123!}"
DEFAULT_DEMO_STUDENT_PASSWORD='DemoBurst123!'
DEMO_STUDENT_PASSWORD="${DEMO_STUDENT_PASSWORD:-${DEFAULT_DEMO_STUDENT_PASSWORD}}"
RUN_ID="${DEMO_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-${RANDOM}}"
[[ "${RUN_ID}" =~ ^[A-Za-z0-9-]{1,48}$ ]] || fail "DEMO_RUN_ID may contain only letters, numbers, and hyphens (maximum 48 characters)."

if [[ -z "${EVAL_COLLECTION_JSON:-}" ]]; then
  if [[ "${DEMO_VARIANT_MODE}" == mixed ]]; then
    EVAL_COLLECTION_JSON="${ROOT_DIR}/../test/dist/evaluation/PRN232-LMS-LAB2-weighted.postman_collection.json"
  else
    EVAL_COLLECTION_JSON="${ROOT_DIR}/fixtures/PRN232-LMS-LAB2-weighted.postman_collection.json"
  fi
fi

if is_local_gateway_url "${GATEWAY_URL}"; then
  IS_LOCAL_GATEWAY=true
  command -v docker >/dev/null 2>&1 || fail "docker is required for a local burst demo."
  docker info >/dev/null 2>&1 || fail "Docker is unavailable; local sandbox pacing cannot be verified."
else
  IS_LOCAL_GATEWAY=false
  [[ "${DEMO_ALLOW_REMOTE}" == true ]] \
    || fail "Refusing non-local GATEWAY_URL '${GATEWAY_URL}'. Set DEMO_ALLOW_REMOTE=true only for an intentional staging demo."
  [[ "${GATEWAY_URL}" == https://* ]] \
    || fail "Refusing insecure remote GATEWAY_URL '${GATEWAY_URL}'. Remote demos must use HTTPS."
  if [[ "${DEMO_STUDENT_PASSWORD}" == "${DEFAULT_DEMO_STUDENT_PASSWORD}" ]]; then
    command -v od >/dev/null 2>&1 || fail "od is required to generate remote demo student credentials."
    random_password_material="$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')"
    [[ "${#random_password_material}" == 48 ]] || fail "Could not generate remote demo student credentials."
    DEMO_STUDENT_PASSWORD="Ec-${random_password_material}-A1!"
    log "Generated a strong per-run student password for the remote demo; it will not be printed."
  fi
fi

[[ -f "${EVAL_COLLECTION_JSON}" ]] || fail "Postman collection not found: ${EVAL_COLLECTION_JSON}"
[[ -f "${DEMO_RUBRIC_JSON}" ]] || fail "Weighted rubric not found: ${DEMO_RUBRIC_JSON}"
jq -e . "${EVAL_COLLECTION_JSON}" >/dev/null || fail "Postman collection is not valid JSON."
jq -e '
  (.criteria | length) == 12 and
  ([.criteria[].maxScore] | add) == 10 and
  (all(.criteria[];
    (.key | type == "string" and length > 0) and
    (.matchPattern | type == "string" and length > 0) and
    .maxScore > 0))
' "${DEMO_RUBRIC_JSON}" >/dev/null || fail "Weighted rubric must contain 12 valid criteria totaling 10.0."
while IFS= read -r match_pattern; do
  jq -e --arg pattern "${match_pattern}" \
    '[.. | strings | select(contains($pattern))] | length > 0' \
    "${EVAL_COLLECTION_JSON}" >/dev/null \
    || fail "Weighted collection has no assertion containing rubric pattern: ${match_pattern}"
done < <(jq -r '.criteria[].matchPattern' "${DEMO_RUBRIC_JSON}")

if [[ "${DEMO_VARIANT_MODE}" == uniform ]]; then
  [[ -f "${EVAL_FIXTURE_ZIP}" ]] || fail "Fixture ZIP not found: ${EVAL_FIXTURE_ZIP}"
  validate_submission_zip "${EVAL_FIXTURE_ZIP}" true
else
  for variant_name in "${VARIANT_NAMES[@]}"; do
    variant_zip="${DEMO_VARIANTS_DIR}/${variant_name}.zip"
    validate_submission_zip "${variant_zip}" true
  done
fi

build_demo_assignment_plan
print_demo_assignment_plan

umask 077
TMP_DIR="$(mktemp -d)"
STUDENTS_DIR="${TMP_DIR}/students"
OVERVIEW_RESPONSE="${TMP_DIR}/overview.json"
RECENT_RESPONSE="${TMP_DIR}/recent.json"
mkdir -p "${STUDENTS_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

check_required_services
log "Gateway and required services are healthy."
preflight_frontend_monitor
log "Recommended frontend: ${DEMO_FRONTEND_URL%/}/lecturer/live-grading"
log "Warm-up recommendation: run 'make smoke-evaluation' once after starting or recreating the stack before the full 100-submission review."

MAIN_REQUEST="${TMP_DIR}/request.json"
MAIN_RESPONSE="${TMP_DIR}/response.json"
jq -n --arg email "${DEMO_LECTURER_EMAIL}" --arg password "${DEMO_LECTURER_PASSWORD}" \
  '{email:$email,password:$password}' > "${MAIN_REQUEST}"
request POST /api/auth/login "" "${MAIN_REQUEST}" "${MAIN_RESPONSE}"
require_request_ok "Lecturer login" "${MAIN_RESPONSE}" || fail "Lecturer login failed."
LECTURER_TOKEN="$(jq -er '.data.accessToken // .accessToken // .data.token // .token' "${MAIN_RESPONSE}")" \
  || fail "Lecturer login returned no access token."

jq -n --arg name "EvalCore Burst ${RUN_ID}" \
  '{name:$name,description:"100 real student submissions with bounded evaluation execution"}' > "${MAIN_REQUEST}"
request POST /api/classes "${LECTURER_TOKEN}" "${MAIN_REQUEST}" "${MAIN_RESPONSE}"
require_request_ok "Create demo class" "${MAIN_RESPONSE}" || fail "Demo class creation failed."
CLASS_ID="$(jq -er '.data.id // .id // .data.classId // .classId' "${MAIN_RESPONSE}")" \
  || fail "Create class returned no class ID."
log "Created class: ${CLASS_ID}"

REQUIREMENT_PDF="${TMP_DIR}/evalcore-burst-requirements.pdf"
printf '%%PDF-1.0\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > "${REQUIREMENT_PDF}"
jq -n \
  --arg title "EvalCore Live Grading Burst ${RUN_ID}" \
  --arg requirement "$(basename "${REQUIREMENT_PDF}")" \
  --arg collection "$(basename "${EVAL_COLLECTION_JSON}")" \
  '{title:$title,description:"100-submission live grading monitor demo",deadline:"2099-12-31T23:59:59Z",requirementFileName:$requirement,collectionFileName:$collection}' > "${MAIN_REQUEST}"
request POST "/api/classes/${CLASS_ID}/labs" "${LECTURER_TOKEN}" "${MAIN_REQUEST}" "${MAIN_RESPONSE}"
require_request_ok "Create demo lab" "${MAIN_RESPONSE}" || fail "Demo lab creation failed."
LAB_ID="$(jq -er '.data.lab.id // .data.id // .lab.id // .id' "${MAIN_RESPONSE}")" \
  || fail "Create lab returned no lab ID."
REQUIREMENT_UPLOAD_URL="$(jq -er '.data.upload.requirementUploadUrl // .upload.requirementUploadUrl' "${MAIN_RESPONSE}")" \
  || fail "Create lab returned no requirement upload URL."
COLLECTION_UPLOAD_URL="$(jq -er '.data.upload.collectionUploadUrl // .upload.collectionUploadUrl' "${MAIN_RESPONSE}")" \
  || fail "Create lab returned no collection upload URL."
log "Created lab: ${LAB_ID}"

request PUT "/api/labs/${LAB_ID}/rubric" "${LECTURER_TOKEN}" "${DEMO_RUBRIC_JSON}" "${MAIN_RESPONSE}"
require_request_ok "Configure weighted rubric" "${MAIN_RESPONSE}" || fail "Weighted rubric configuration failed."
jq -e '
  (.data.totalScore // .totalScore | tonumber) == 10 and
  (.data.criteria // .criteria | length) == 12
' "${MAIN_RESPONSE}" >/dev/null || fail "Class Service did not return the expected 10-point weighted rubric."
log "Configured the 12-criterion weighted rubric (10.0 points)."

put_file "${REQUIREMENT_PDF}" "${REQUIREMENT_UPLOAD_URL}" "${TMP_DIR}/requirement-upload.txt"
is_2xx || fail "Requirement PDF upload failed with HTTP ${HTTP_STATUS:-000}."
put_file "${EVAL_COLLECTION_JSON}" "${COLLECTION_UPLOAD_URL}" "${TMP_DIR}/collection-upload.txt"
is_2xx || fail "Postman collection upload failed with HTTP ${HTTP_STATUS:-000}."
printf '{"requirementUploaded":true,"collectionUploaded":true}\n' > "${MAIN_REQUEST}"
request POST "/api/labs/${LAB_ID}/assets/complete" "${LECTURER_TOKEN}" "${MAIN_REQUEST}" "${MAIN_RESPONSE}"
require_request_ok "Activate demo lab" "${MAIN_RESPONSE}" || fail "Demo lab activation failed."
[[ "$(jq -r '.data.status // .data.lab.status // .status // empty' "${MAIN_RESPONSE}")" == active ]] \
  || fail "Demo lab did not become active."
log "Uploaded lab assets and activated lab ${LAB_ID}."

log "Preparing ${DEMO_SUBMISSION_COUNT} real student accounts and uploads (concurrency ${DEMO_SUBMIT_CONCURRENCY})."
if ! run_bounded prepare_student "${DEMO_SUBMISSION_COUNT}" "${DEMO_SUBMIT_CONCURRENCY}"; then
  fail "One or more students could not be prepared. Partial demo records remain visible for diagnosis."
fi
for index in $(seq 1 "${DEMO_SUBMISSION_COUNT}"); do
  printf -v padded '%03d' "${index}"
  [[ -f "${STUDENTS_DIR}/${padded}/prepared" ]] || fail "Student ${padded} has no prepared submission."
done
assert_unique_prepared_records
log "Prepared ${DEMO_SUBMISSION_COUNT}/${DEMO_SUBMISSION_COUNT}. Starting completion burst."

burst_started="$(date +%s)"
if ! run_bounded complete_submission "${DEMO_SUBMISSION_COUNT}" "${DEMO_SUBMIT_CONCURRENCY}"; then
  fail "One or more submissions failed to reach submitted. Successful submissions still emitted their real events."
fi
burst_elapsed=$(( $(date +%s) - burst_started ))
for index in $(seq 1 "${DEMO_SUBMISSION_COUNT}"); do
  printf -v padded '%03d' "${index}"
  [[ -f "${STUDENTS_DIR}/${padded}/submitted" ]] || fail "Submission ${padded} was not verified as submitted."
done
log "Submitted ${DEMO_SUBMISSION_COUNT}/${DEMO_SUBMISSION_COUNT} in ${burst_elapsed}s."

MONITOR_URL="${DEMO_FRONTEND_URL%/}/lecturer/live-grading?labId=${LAB_ID}"
log "LIVE GRADING MONITOR: ${MONITOR_URL}"
log "Frontend base route: ${DEMO_FRONTEND_URL%/}/lecturer/live-grading"
log "Waiting for RabbitMQ/outbox intake to create ${DEMO_SUBMISSION_COUNT} durable evaluation rows."
wait_for_monitor_intake || fail "Evaluation monitor did not observe the full accepted burst."
assert_monitor_pacing || fail "Evaluation runner pacing verification failed."
log "Runner concurrency: ${VERIFIED_RUNNER_CONCURRENCY}"
log "${DEMO_SUBMISSION_COUNT} submissions are accepted immediately; only ${VERIFIED_RUNNER_CONCURRENCY} evaluations run at once."
check_required_services
log "Gateway and required services remain healthy after the accepted burst."
if [[ "${IS_LOCAL_GATEWAY}" == true ]]; then
  inspect_local_sandboxes "${VERIFIED_RUNNER_CONCURRENCY}" "${VERIFIED_ACTIVE_SLOTS}" \
    || fail "Local Docker sandbox verification failed."
else
  log "Remote demo: local Docker sandbox inspection is not applicable."
fi

if [[ "${DEMO_WAIT_FOR_COMPLETION}" == true ]]; then
  log "DEMO_WAIT_FOR_COMPLETION=true; waiting for all real evaluations to finish."
  wait_for_terminal_evaluations || fail "Terminal evaluation wait did not finish cleanly."
  if [[ "${DEMO_VARIANT_MODE}" == mixed ]]; then
    assert_terminal_weighted_results || fail "Mixed weighted result verification failed."
  fi
  assert_monitor_pacing || fail "Final evaluation runner pacing verification failed."
  check_required_services
  if [[ "${IS_LOCAL_GATEWAY}" == true ]]; then
    inspect_local_sandboxes "${VERIFIED_RUNNER_CONCURRENCY}" "${VERIFIED_ACTIVE_SLOTS}" \
      || fail "Final local Docker sandbox verification failed."
  fi
  log "Live monitor: ${MONITOR_URL}"
  log "Done. All ${DEMO_SUBMISSION_COUNT} evaluations reached terminal state."
else
  log "Live monitor: ${MONITOR_URL}"
  log "Done. Evaluations will continue processing in the background."
fi
