#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$(mktemp)"
trap 'rm -f "${CONFIG_FILE}"' EXIT

log() { printf '[check-onprem-env] %s\n' "$1"; }
fail() { log "FAILURE: $1" >&2; exit 1; }

for command in docker mktemp python3; do
  command -v "${command}" >/dev/null 2>&1 || fail "${command} is required."
done

cd "${ROOT_DIR}"
log "Resolving Docker Compose configuration without displaying secret values."
if ! docker compose --profile app config --format json >"${CONFIG_FILE}" 2>/dev/null; then
  fail "docker compose config failed; run 'docker compose --profile app config --quiet' for details."
fi

python3 - "${CONFIG_FILE}" "${ROOT_DIR}/.env" <<'PY'
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

config_path = Path(sys.argv[1])
env_path = Path(sys.argv[2])
config = json.loads(config_path.read_text(encoding="utf-8"))
services = config.get("services", {})
errors = []
warnings = []


def read_dotenv(path):
    values = {}
    if not path.is_file():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        name = name.strip()
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
                value = value[1:-1]
            values[name] = value
    return values


dotenv = read_dotenv(env_path)


def requested_value(name):
    return os.environ.get(name, dotenv.get(name))


def service_env(service):
    service_config = services.get(service)
    if not isinstance(service_config, dict):
        errors.append(f"composed service '{service}' is missing")
        return {}
    environment = service_config.get("environment", {})
    if not isinstance(environment, dict):
        errors.append(f"composed service '{service}' has no environment map")
        return {}
    return {str(key): "" if value is None else str(value) for key, value in environment.items()}


envs = {}


def get_env(service):
    if service not in envs:
        envs[service] = service_env(service)
    return envs[service]


def require_keys(service_names, keys):
    for service in service_names:
        environment = get_env(service)
        for key in keys:
            if not environment.get(key):
                errors.append(f"{service} is missing required {key}")


def require_consistent(service_names, keys):
    for key in keys:
        values = {get_env(service).get(key) for service in service_names}
        if None not in values and len(values) > 1:
            errors.append(f"{key} is inconsistent across: {', '.join(service_names)}")


def require_requested_value(service_names, keys):
    for key in keys:
        expected = requested_value(key)
        if expected is None:
            continue
        for service in service_names:
            actual = get_env(service).get(key)
            if actual is not None and actual != expected:
                errors.append(f"{service} does not resolve {key} from the deployment environment")


s3_services = [
    "identity-service",
    "class-service",
    "submission-service",
    "evaluation-service",
    "evaluation-runner",
]
s3_keys = [
    "S3_ENDPOINT",
    "S3_INTERNAL_ENDPOINT",
    "S3_PUBLIC_ENDPOINT",
    "S3_ACCESS_KEY",
    "S3_SECRET_KEY",
    "S3_USE_SSL",
]
rabbit_services = [
    "class-service",
    "submission-service",
    "evaluation-service",
    "evaluation-runner",
    "notification-service",
]
rabbit_keys = [
    "RABBITMQ_HOST",
    "RABBITMQ_PORT",
    "RABBITMQ_USERNAME",
    "RABBITMQ_PASSWORD",
    "RABBITMQ_EXCHANGE",
]

require_keys(s3_services, s3_keys)
require_consistent(s3_services, s3_keys)
require_requested_value(
    s3_services,
    ["S3_ENDPOINT", "S3_INTERNAL_ENDPOINT", "S3_PUBLIC_ENDPOINT", "S3_USE_SSL"],
)
require_keys(rabbit_services, rabbit_keys)
require_consistent(rabbit_services, rabbit_keys)
require_requested_value(rabbit_services, ["RABBITMQ_HOST", "RABBITMQ_PORT", "RABBITMQ_EXCHANGE"])

required_service_urls = {
    "submission-service": ["CLASS_SERVICE_BASE_URL"],
    "evaluation-service": ["CLASS_SERVICE_BASE_URL", "SUBMISSION_SERVICE_BASE_URL", "GRADING_GRPC_URL"],
    "evaluation-runner": ["CLASS_SERVICE_BASE_URL", "SUBMISSION_SERVICE_BASE_URL", "GRADING_GRPC_URL"],
    "notification-service": ["IDENTITY_SERVICE_BASE_URL"],
}
for service, keys in required_service_urls.items():
    require_keys([service], keys)
    require_requested_value([service], keys)

require_consistent(
    ["evaluation-service", "evaluation-runner"],
    ["CLASS_SERVICE_BASE_URL", "SUBMISSION_SERVICE_BASE_URL", "GRADING_GRPC_URL"],
)

cors_services = [
    "identity-service",
    "class-service",
    "submission-service",
    "evaluation-service",
    "evaluation-runner",
    "notification-service",
]
require_keys(cors_services, ["CORS_ALLOWED_ORIGINS"])
require_consistent(cors_services, ["CORS_ALLOWED_ORIGINS"])
require_requested_value(cors_services, ["CORS_ALLOWED_ORIGINS"])

database_services = [
    "identity-service",
    "class-service",
    "submission-service",
    "evaluation-service",
    "notification-service",
]
require_keys(database_services, ["DATABASE_URL"])


def endpoint_host(value):
    if not value:
        return ""
    candidate = value if "://" in value else f"//{value}"
    try:
        return (urlsplit(candidate).hostname or "").lower()
    except ValueError:
        return ""


def is_local_endpoint(value):
    host = endpoint_host(value)
    return host in {"minio", "localhost", "127.0.0.1", "::1"}


identity_env = get_env("identity-service")
s3_endpoint = identity_env.get("S3_ENDPOINT", "")
s3_internal = identity_env.get("S3_INTERNAL_ENDPOINT", "")
s3_public = identity_env.get("S3_PUBLIC_ENDPOINT", "")
s3_use_ssl = identity_env.get("S3_USE_SSL", "").lower()

if s3_public and not is_local_endpoint(s3_public):
    if is_local_endpoint(s3_endpoint):
        errors.append("S3_PUBLIC_ENDPOINT is external but S3_ENDPOINT still resolves to local MinIO")
    if is_local_endpoint(s3_internal):
        errors.append("S3_PUBLIC_ENDPOINT is external but S3_INTERNAL_ENDPOINT still resolves to local MinIO")

frontend_values = [
    requested_value("DEMO_FRONTEND_URL"),
    requested_value("FRONTEND_URL"),
    requested_value("PUBLIC_FRONTEND_URL"),
]
public_frontend = any(
    value and "prn232.dorriss.com" in value.lower() for value in frontend_values
)
if public_frontend and endpoint_host(s3_public) in {"localhost", "127.0.0.1", "::1"}:
    errors.append("S3_PUBLIC_ENDPOINT uses localhost while the frontend deployment is prn232.dorriss.com")

if any(value.lower().startswith("https://") for value in [s3_endpoint, s3_internal, s3_public]):
    if s3_use_ssl != "true":
        warnings.append("an S3 endpoint uses HTTPS but S3_USE_SSL is not true")

jwt_secret = identity_env.get("JWT_SECRET", "")
if jwt_secret.startswith("change-me-") or "local-dev" in jwt_secret:
    warnings.append("JWT_SECRET still uses a default development value")

internal_token = identity_env.get("INTERNAL_SERVICE_TOKEN", "")
if internal_token.startswith("dev-internal-service-token"):
    warnings.append("INTERNAL_SERVICE_TOKEN still uses the default development value")


def sanitized_endpoint(value):
    if not value:
        return "<missing>"
    try:
        parts = urlsplit(value)
    except ValueError:
        return "<invalid>"
    if not parts.scheme or not parts.netloc:
        return value.split("?", 1)[0].split("#", 1)[0]
    host = parts.hostname or ""
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    try:
        port = f":{parts.port}" if parts.port is not None else ""
    except ValueError:
        port = ""
    return urlunsplit((parts.scheme, f"{host}{port}", parts.path, "", ""))


def database_host(value):
    if not value:
        return None
    match = re.search(r"(?:^|;)\s*(?:Host|Server)\s*=\s*([^;]+)", value, re.IGNORECASE)
    if match:
        host = match.group(1).strip().rsplit("@", 1)[-1]
        return host.split()[0] if host else None
    try:
        parsed = urlsplit(value)
    except ValueError:
        return None
    return parsed.hostname


evaluation_env = get_env("evaluation-service")
class_env = get_env("class-service")
rabbitmq_host = class_env.get("RABBITMQ_HOST", "")
if "://" in rabbitmq_host:
    rabbitmq_host = endpoint_host(rabbitmq_host)
else:
    rabbitmq_host = rabbitmq_host.rsplit("@", 1)[-1]

print("[check-onprem-env] Resolved non-secret deployment configuration:")
print(f"  S3_ENDPOINT={sanitized_endpoint(s3_endpoint)}")
print(f"  S3_INTERNAL_ENDPOINT={sanitized_endpoint(s3_internal)}")
print(f"  S3_PUBLIC_ENDPOINT={sanitized_endpoint(s3_public)}")
print(f"  S3_USE_SSL={s3_use_ssl or '<missing>'}")
print(f"  RABBITMQ_HOST={rabbitmq_host or '<missing>'}")
print(f"  GRADING_GRPC_URL={sanitized_endpoint(evaluation_env.get('GRADING_GRPC_URL', ''))}")
print(f"  CORS_ALLOWED_ORIGINS={evaluation_env.get('CORS_ALLOWED_ORIGINS', '<missing>')}")
print("  DATABASE_URL hosts:")
for service in database_services:
    host = database_host(get_env(service).get("DATABASE_URL", ""))
    print(f"    {service}={host or '<unable-to-parse>'}")

for warning in warnings:
    print(f"[check-onprem-env] WARNING: {warning}", file=sys.stderr)

if errors:
    for error in errors:
        print(f"[check-onprem-env] FAILURE: {error}", file=sys.stderr)
    sys.exit(1)

print("[check-onprem-env] PASS: Compose environment wiring is on-prem compatible.")
PY
