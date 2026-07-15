#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[demo-variants] %s\n' "$1"; }
fail() { printf '[demo-variants] ERROR: %s\n' "$1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${OPS_ROOT}/.." && pwd)"
BASE_ZIP="${DEMO_BASE_SUBMISSION_ZIP:-${WORKSPACE_ROOT}/test/dist/evaluation/PRN232.LMS-Evaluation-Submission.zip}"
OUTPUT_DIR="${DEMO_VARIANTS_OUTPUT_DIR:-${WORKSPACE_ROOT}/test/dist/evaluation/variants}"
FIXED_TIMESTAMP="202607160000.00"

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

for command in cat cp dirname find grep install mkdir mktemp perl rm sed sha256sum sort touch unzip zip zipinfo; do
  command -v "${command}" >/dev/null 2>&1 || fail "Required command is unavailable: ${command}"
done

[[ -f "${BASE_ZIP}" ]] || fail "Known-good submission ZIP not found: ${BASE_ZIP}"
mapfile -t BASE_ZIP_ENTRIES < <(unzip -Z1 "${BASE_ZIP}")
(( ${#BASE_ZIP_ENTRIES[@]} > 0 )) || fail "Base ZIP is empty."
ROOT_COMPOSE_COUNT=0
for entry in "${BASE_ZIP_ENTRIES[@]}"; do
  case "${entry}" in
    /* | .. | ../* | */../* | */.. | *\\*)
      fail "Base ZIP contains an unsafe path: ${entry}"
      ;;
    docker-compose.yml)
      ROOT_COMPOSE_COUNT=$((ROOT_COMPOSE_COUNT + 1))
      ;;
    */docker-compose.yml | */compose.yaml)
      fail "Base ZIP compose file must be at ZIP root, not ${entry}."
      ;;
  esac
  case "/${entry}" in
    */.git | */.git/* | */.env | */.env/* | */bin/* | */obj/*)
      fail "Base ZIP contains an excluded source-control, environment, or build-output path: ${entry}"
      ;;
  esac
done
(( ROOT_COMPOSE_COUNT == 1 )) || fail "Base ZIP must contain exactly one root docker-compose.yml."

if zipinfo -l "${BASE_ZIP}" | grep -Eq '^l'; then
  fail "Base ZIP contains a symbolic link."
fi

if unzip -p "${BASE_ZIP}" docker-compose.yml \
  | grep -Eqi 'privileged[[:space:]]*:|network_mode[[:space:]]*:[[:space:]]*host|/var/run/docker\.sock|pid[[:space:]]*:[[:space:]]*host|ipc[[:space:]]*:[[:space:]]*host|cap_add[[:space:]]*:|devices[[:space:]]*:|type[[:space:]]*:[[:space:]]*bind|-[[:space:]]*(/|\.\.?/)'; then
  fail "Base ZIP compose file contains a forbidden sandbox escape capability."
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
mkdir -p "${TMP_DIR}/output" "${OUTPUT_DIR}"

replace_exact() {
  local file="$1" old="$2" new="$3" count

  [[ -f "${file}" ]] || fail "Patch target not found: ${file}"
  count="$(OLD="${old}" perl -0777 -ne '$needle = $ENV{"OLD"}; $count = () = /\Q$needle\E/g; print $count' "${file}")"
  [[ "${count}" == 1 ]] || fail "Expected one patch marker in ${file}; found ${count}."
  OLD="${old}" NEW="${new}" perl -0777 -pi -e '$old = $ENV{"OLD"}; $new = $ENV{"NEW"}; s/\Q$old\E/$new/' "${file}"
}

extract_base() {
  local destination="$1"
  rm -rf "${destination}"
  mkdir -p "${destination}"
  unzip -q "${BASE_ZIP}" -d "${destination}"
}

archive_tree() {
  local source="$1" destination="$2"

  find "${source}" -exec touch -h -t "${FIXED_TIMESTAMP}" {} +
  (
    cd "${source}"
    LC_ALL=C find . -mindepth 1 -print \
      | LC_ALL=C sort \
      | zip -X -q "${destination}" -@
  )
}

patch_swagger() {
  local source="$1" program="${source}/PRN232.LMS.API/Program.cs"
  local using_marker='using System.Text.Json.Serialization;'
  local using_replacement=$'using System.Text.Json.Serialization;\nusing System.Text.Json.Nodes;'
  local app_marker=$'app.Services.InitializeLmsDatabase();\n\nif (app.Environment.IsDevelopment())'
  local app_replacement
  app_replacement="$(cat <<'PATCH'
app.Services.InitializeLmsDatabase();

// Demo variant: preserve the generated Swagger document but remove only its
// version marker so the dedicated Swagger/OpenAPI rubric assertion fails.
app.Use(async (context, next) =>
{
    if (!string.Equals(
            context.Request.Path.Value,
            "/swagger/v1/swagger.json",
            StringComparison.OrdinalIgnoreCase))
    {
        await next();
        return;
    }

    var originalBody = context.Response.Body;
    await using var buffer = new MemoryStream();
    context.Response.Body = buffer;

    try
    {
        await next();
        buffer.Position = 0;
        var document = await JsonNode.ParseAsync(buffer);
        if (document is JsonObject root)
        {
            root.Remove("openapi");
            root.Remove("swagger");
        }

        context.Response.Body = originalBody;
        context.Response.ContentLength = null;
        await context.Response.WriteAsync(document?.ToJsonString() ?? "{}");
    }
    finally
    {
        context.Response.Body = originalBody;
    }
});

if (app.Environment.IsDevelopment())
PATCH
)"

  replace_exact "${program}" "${using_marker}" "${using_replacement}"
  replace_exact "${program}" "${app_marker}" "${app_replacement}"
}

patch_pagination() {
  local source="$1"
  replace_exact \
    "${source}/PRN232.LMS.API/Controllers/LmsControllerBase.cs" \
    'Page = result.Page,' \
    'Page = result.Page + 1,'
}

patch_response_format() {
  local source="$1"
  replace_exact \
    "${source}/PRN232.LMS.API/Controllers/StudentsController.cs" \
    'return NotFoundResponse(exception);' \
    'return StatusCode(StatusCodes.Status200OK, new ApiResponse<StudentResponse> { Success = false, Message = exception.Message });'
}

patch_list_capabilities() {
  local source="$1"
  replace_exact \
    "${source}/PRN232.LMS.API/Controllers/LmsControllerBase.cs" \
    'PageSize = result.PageSize,' \
    'PageSize = result.PageSize + 1,'
  replace_exact \
    "${source}/PRN232.LMS.API/Extensions/ResponseShaper.cs" \
    $'.Where(property =>\n                requestedFields.Contains(property.Name) ||\n                requestedFields.Contains(ToCamelCase(property.Name)));' \
    $'.Where(property =>\n                !string.Equals(property.Name, "FullName", StringComparison.OrdinalIgnoreCase) &&\n                (requestedFields.Contains(property.Name) ||\n                 requestedFields.Contains(ToCamelCase(property.Name))));'
}

patch_readiness() {
  local source="$1"
  replace_exact \
    "${source}/PRN232.LMS.API/Program.cs" \
    $'app.MapGet("/health", () => Results.Ok(new\n{\n    status = "healthy"\n}));' \
    'app.MapGet("/health", () => Results.StatusCode(StatusCodes.Status503ServiceUnavailable));'
}

patch_build_error() {
  local source="$1"
  printf '\n#error DEMO_BUILD_ERROR_VARIANT\n' >> "${source}/PRN232.LMS.API/Program.cs"
}

patch_invalid_compose() {
  local source="$1"
  replace_exact \
    "${source}/docker-compose.yml" \
    $'services:\n  app:' \
    $'services:\n  application:'
}

build_variant() {
  local name="$1"
  local source="${TMP_DIR}/work-${name}"
  local destination="${TMP_DIR}/output/${name}.zip"

  if [[ "${name}" == pass ]]; then
    cp "${BASE_ZIP}" "${destination}"
    return
  fi

  extract_base "${source}"
  case "${name}" in
    fail-swagger)
      patch_swagger "${source}"
      ;;
    fail-pagination)
      patch_pagination "${source}"
      ;;
    fail-response-format)
      patch_response_format "${source}"
      ;;
    fail-multiple-criteria)
      patch_swagger "${source}"
      patch_pagination "${source}"
      patch_response_format "${source}"
      patch_list_capabilities "${source}"
      ;;
    readiness-error)
      patch_readiness "${source}"
      ;;
    build-error)
      patch_build_error "${source}"
      ;;
    invalid-compose)
      patch_invalid_compose "${source}"
      ;;
    *)
      fail "Unsupported variant: ${name}"
      ;;
  esac

  archive_tree "${source}" "${destination}"
}

log "Base ZIP: ${BASE_ZIP}"
log "Output directory: ${OUTPUT_DIR}"
for variant in "${VARIANT_NAMES[@]}"; do
  log "Building ${variant}.zip"
  build_variant "${variant}"
done

for variant in "${VARIANT_NAMES[@]}"; do
  source_zip="${TMP_DIR}/output/${variant}.zip"
  [[ "$(unzip -Z1 "${source_zip}" | grep -c '^docker-compose.yml$' || true)" == 1 ]] \
    || fail "${variant}.zip does not contain exactly one root docker-compose.yml."
  install -m 0644 "${source_zip}" "${OUTPUT_DIR}/${variant}.zip"
done

(
  cd "${OUTPUT_DIR}"
  sha256sum "${VARIANT_NAMES[@]/%/.zip}" > SHA256SUMS
)

log 'Generated deterministic submission variants:'
sed 's/^/[demo-variants]   /' "${OUTPUT_DIR}/SHA256SUMS"
