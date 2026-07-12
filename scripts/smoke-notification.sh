#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[smoke-notification] %s\n' "$1"; }
fail() { log "FAILURE: $1" >&2; exit 1; }

load_env_file() {
  local line
  [[ -f "${ROOT_DIR}/.env" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    export "${line}"
  done < "${ROOT_DIR}/.env"
}

query_until() {
  local query="$1" value=""
  for _ in $(seq 1 30); do
    value="$(docker compose --profile app exec -T postgres psql -At -U "${POSTGRES_USER:-ags}" -d "${POSTGRES_DB:-ags}" -c "${query}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && { printf '%s' "${value}"; return 0; }
    sleep 2
  done
  return 1
}

load_env_file
GATEWAY_URL="${GATEWAY_URL:-http://localhost:${GATEWAY_PORT:-8080}}"
NOTIFICATION_URL="http://localhost:${NOTIFICATION_PUBLIC_PORT:-8086}"

curl -fsS "${GATEWAY_URL}/notification/health" >/dev/null || fail "Notification gateway health is unavailable."
curl -fsS "${NOTIFICATION_URL}/health" >/dev/null || fail "Notification direct health is unavailable."
log "Notification health checks passed."

evaluation_output="$(make -C "${ROOT_DIR}" smoke-evaluation)" || {
  printf '%s\n' "${evaluation_output:-}"
  fail "Evaluation smoke failed."
}
printf '%s\n' "${evaluation_output}"
evaluation_id="$(sed -n 's/^\[smoke-evaluation\] Evaluation ID: //p' <<<"${evaluation_output}" | tail -n 1)"
[[ "${evaluation_id}" =~ ^[0-9a-fA-F-]{36}$ ]] || fail "Evaluation ID was not reported."

inbox_status="$(query_until "SELECT status FROM notification.inbox_events WHERE event_type = 'EvaluationCompleted' AND event_key = '${evaluation_id}' ORDER BY received_at DESC LIMIT 1;")" || fail "Timed out waiting for inbox event."
[[ "${inbox_status}" == "processed" ]] || fail "Inbox event is '${inbox_status}', expected processed."
notification_row="$(query_until "SELECT id || '|' || user_id FROM notification.notifications WHERE evaluation_id = '${evaluation_id}'::uuid ORDER BY created_at DESC LIMIT 1;")" || fail "Notification row was not created."
notification_id="${notification_row%%|*}"
student_id="${notification_row##*|}"
delivery_status="$(query_until "SELECT d.status FROM notification.email_deliveries d WHERE d.notification_id = '${notification_id}'::uuid ORDER BY d.created_at DESC LIMIT 1;")" || fail "Email delivery row was not created."

if [[ "${NOTIFICATION_EMAIL_ENABLED:-false}" == true ]]; then
  [[ "${delivery_status}" == sent ]] || fail "Expected sent email, got ${delivery_status}."
else
  [[ "${delivery_status}" == skipped ]] || fail "Expected skipped email, got ${delivery_status}."
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
login() {
  curl -sS -o "$2" -w '%{http_code}' -H 'Content-Type: application/json' --data "{\"email\":\"$1\",\"password\":\"Password123!\"}" "${GATEWAY_URL}/api/auth/login"
}
student_login_status="$(login student@ags.local "${tmp_dir}/student-login.json")" || student_login_status=000
[[ "${student_login_status}" == 200 ]] || fail "Student login failed."
student_token="$(jq -r '.accessToken // .data.accessToken // .token // .data.token // empty' "${tmp_dir}/student-login.json")"
[[ -n "${student_token}" ]] || fail "Student login returned no token."

student_list_status="$(curl -sS -o "${tmp_dir}/student-list.json" -w '%{http_code}' -H "Authorization: Bearer ${student_token}" "${GATEWAY_URL}/api/notifications/my?page=1&pageSize=100")" || student_list_status=000
[[ "${student_list_status}" == 200 ]] || fail "Student notification list failed."
jq -e --arg id "${notification_id}" '.. | objects | select(.id? == $id)' "${tmp_dir}/student-list.json" >/dev/null || fail "Student list did not contain notification."

unread_status="$(curl -sS -o "${tmp_dir}/unread-before.json" -w '%{http_code}' -H "Authorization: Bearer ${student_token}" "${GATEWAY_URL}/api/notifications/my/unread-count")" || unread_status=000
[[ "${unread_status}" == 200 ]] || fail "Unread count failed."
unread_before="$(jq -r '.data.count // empty' "${tmp_dir}/unread-before.json")"
[[ "${unread_before}" =~ ^[0-9]+$ && "${unread_before}" -ge 1 ]] || fail "Unread count did not include new notification."

mark_status="$(curl -sS -o "${tmp_dir}/mark-read.json" -w '%{http_code}' -X PATCH -H "Authorization: Bearer ${student_token}" "${GATEWAY_URL}/api/notifications/${notification_id}/read")" || mark_status=000
[[ "${mark_status}" == 200 ]] || fail "Mark read failed."
unread_after_status="$(curl -sS -o "${tmp_dir}/unread-after.json" -w '%{http_code}' -H "Authorization: Bearer ${student_token}" "${GATEWAY_URL}/api/notifications/my/unread-count")" || unread_after_status=000
[[ "${unread_after_status}" == 200 ]] || fail "Unread count after read failed."
unread_after="$(jq -r '.data.count // empty' "${tmp_dir}/unread-after.json")"
[[ "${unread_after}" =~ ^[0-9]+$ && "${unread_after}" -lt "${unread_before}" ]] || fail "Unread count did not decrease."

read_all_status="$(curl -sS -o "${tmp_dir}/read-all.json" -w '%{http_code}' -X PATCH -H "Authorization: Bearer ${student_token}" "${GATEWAY_URL}/api/notifications/my/read-all")" || read_all_status=000
[[ "${read_all_status}" == 200 ]] || fail "Read all failed."

lecturer_login_status="$(login lecturer@ags.local "${tmp_dir}/lecturer-login.json")" || lecturer_login_status=000
[[ "${lecturer_login_status}" == 200 ]] || fail "Lecturer login failed."
lecturer_token="$(jq -r '.accessToken // .data.accessToken // .token // .data.token // empty' "${tmp_dir}/lecturer-login.json")"
lecturer_list_status="$(curl -sS -o "${tmp_dir}/lecturer-list.json" -w '%{http_code}' -H "Authorization: Bearer ${lecturer_token}" "${GATEWAY_URL}/api/notifications/my?page=1&pageSize=100")" || lecturer_list_status=000
[[ "${lecturer_list_status}" == 200 ]] || fail "Lecturer notification list failed."
! jq -e --arg id "${notification_id}" '.. | objects | select(.id? == $id)' "${tmp_dir}/lecturer-list.json" >/dev/null || fail "Lecturer can see student notification."

log '============================================================'
log 'Notification flow OK.'
log "Evaluation ID: ${evaluation_id}"
log "Student ID: ${student_id}"
log "Notification ID: ${notification_id}"
log "Email delivery status: ${delivery_status}"
log '============================================================'
