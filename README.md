# Automated Grading System Ops

This repository contains local Docker orchestration for the Automated Grading System.

## Recommended: Full Docker App Stack

This is the tester/developer path. It requires Docker only. It does not require any service source repository, a local .NET SDK, or a local backend build.

1. Copy env:

```bash
cp .env.example .env
```

2. Pull latest images:

```bash
docker compose --profile app pull
```

3. Start the full app stack:

```bash
docker compose --profile app up -d
```

or:

```bash
make app-up
```

4. Check status:

```bash
docker compose --profile app ps
```

or:

```bash
make app-ps
```

5. Smoke test:

```bash
make smoke-app
```

6. Stop:

```bash
docker compose --profile app down
```

or:

```bash
make app-down
```

The root `compose.yaml` is the primary entry point:

- `docker compose up -d` starts infrastructure only (Postgres, RabbitMQ, MinIO).
- `docker compose --profile app up -d` starts infrastructure + Identity Service + Class Service + Submission Service + split Evaluation API/runner + Notification Service + Caddy gateway + Dozzle.

## App Stack Services

| Service          | Role                        |
|------------------|-----------------------------|
| PostgreSQL       | Relational database         |
| RabbitMQ         | Message broker              |
| MinIO            | Object storage (S3-compat)  |
| Identity Service | Auth and user management    |
| Class Service    | Classes, labs, assets       |
| Submission Service | Lab submissions and source assets |
| Evaluation Service | Public evaluation API and event consumer |
| Evaluation Runner | Internal Docker sandbox worker (no public port) |
| Notification Service | Evaluation result notifications and SMTP delivery |
| Gateway (Caddy)  | Reverse proxy / API gateway |
| Dozzle           | Local Docker container log viewer |

## App Commands

```bash
make env
make app-pull
make app-up
make app-ps
make smoke-app
make smoke-evaluation
make smoke-notification
make app-logs
make app-down
```

`make app-up` does not build backend images. Docker Compose pulls the configured images from DockerHub.

## URLs

- Gateway: `http://localhost:8080`
- Identity direct: `http://localhost:8081`
- Class Service direct: `http://localhost:8082`
- Submission Service direct: `http://localhost:8083`
- Evaluation Service direct: `http://localhost:8084`
- Notification Service direct: `http://localhost:8086`
- MinIO API: `http://localhost:9000`
- MinIO Console: `http://localhost:9001`
- RabbitMQ Console: `http://localhost:15672`
- Dozzle Logs: `http://localhost:9999`
- PostgreSQL: `localhost:5432`

## Gateway Routes

| Route               | Upstream         |
|---------------------|------------------|
| `GET /health`       | Gateway (Caddy)  |
| `GET /identity/health` | Identity Service |
| `GET /class/health` | Class Service    |
| `GET /submission/health` | Submission Service |
| `GET /evaluation/health` | Evaluation Service |
| `GET /notification/health` | Notification Service |
| `/api/auth/*`       | Identity Service |
| `/api/users/*`      | Identity Service |
| `/api/admin/users*` | Identity Service |
| `/api/classes*`     | Class Service    |
| `/api/labs/*/submissions*` | Submission Service |
| `/api/submissions/*/evaluations*` | Evaluation Service |
| `/api/evaluations*` | Evaluation Service |
| `/api/notifications*` | Notification Service |
| `/api/submissions*` | Submission Service |
| `/api/labs*`        | Class Service    |

The nested submission route must stay before the generic `/api/labs*` route in `caddy/Caddyfile`.

## Docker Images

Default images:

```bash
IDENTITY_IMAGE=dorrissdang/evalcore-identity-service:main
CLASS_IMAGE=dorrissdang/evalcore-class-service:main
SUBMISSION_IMAGE=dorrissdang/evalcore-submission-service:main
EVALUATION_IMAGE=dorrissdang/evalcore-evaluation-service:main
NOTIFICATION_IMAGE=dorrissdang/evalcore-notification-service:main
```

Override in `.env` for a specific tag or commit SHA:

```bash
IDENTITY_IMAGE=dorrissdang/evalcore-identity-service:v1
IDENTITY_IMAGE=dorrissdang/evalcore-identity-service:sha-xxxx

CLASS_IMAGE=dorrissdang/evalcore-class-service:v1
CLASS_IMAGE=dorrissdang/evalcore-class-service:sha-xxxx

SUBMISSION_IMAGE=dorrissdang/evalcore-submission-service:v1
SUBMISSION_IMAGE=dorrissdang/evalcore-submission-service:sha-xxxx

EVALUATION_IMAGE=dorrissdang/evalcore-evaluation-service:v1
EVALUATION_IMAGE=dorrissdang/evalcore-evaluation-service:sha-xxxx

NOTIFICATION_IMAGE=dorrissdang/evalcore-notification-service:v1
NOTIFICATION_IMAGE=dorrissdang/evalcore-notification-service:sha-xxxx
```

## MinIO Buckets

The stack creates these buckets on startup:

- `lab-assets`
- `submission-assets`
- `evaluation-reports`

`evaluation-reports` is reserved for the Evaluation Service.

MinIO CORS is configured with `MINIO_API_CORS_ALLOW_ORIGIN` for browser presigned uploads and downloads. The `minio-init` service creates the intended buckets and logs the active MinIO API CORS setting.

Allowed frontend origins:

- `http://localhost:3000`
- `http://localhost:5173`

Browser `PUT` to presigned URLs should work for:

- `lab-assets`
- `submission-assets`

The same MinIO API CORS setting covers `evaluation-reports`, which is reserved for future report downloads.

## Dozzle Logs

Dozzle is available at `http://localhost:9999` when the app profile is running. It is for local development only and is used to view Docker container logs.

Dozzle reads Docker metadata and logs through the read-only Docker socket mount. It is not routed through Caddy and should not be exposed publicly.

## Current Flow

The app smoke test covers the full gateway path:

1. Lecturer creates a class.
2. Student joins the class.
3. Lecturer creates a lab and uploads the requirement PDF and Postman collection to MinIO with presigned URLs.
4. Lecturer completes lab assets and the lab becomes active.
5. Student creates a submission.
6. Student uploads a ZIP to MinIO with the submission presigned URL.
7. Student completes submission assets and the submission becomes submitted.
8. Student lists and opens their submitted work.
9. Lecturer lists lab submissions and downloads the submitted ZIP.
10. Evaluation consumes `SubmissionSubmitted`, runs the isolated Docker Compose/Newman sandbox, and publishes `EvaluationCompleted`.
11. Notification consumes `EvaluationCompleted`, resolves the student through Identity's protected internal endpoint, and creates an email delivery record. Set `NOTIFICATION_EMAIL_ENABLED=true` plus SMTP settings in `.env` to send email; otherwise the delivery is recorded as `skipped`.

`make smoke-evaluation` uses the known-good fixture under `../test/dist/evaluation`, exercises the automatic consumer path only, and verifies the final score, artifacts, published outbox event, and sandbox cleanup. Override the fixture paths with `EVAL_FIXTURE_ZIP` and `EVAL_COLLECTION_JSON` when needed.

`make smoke-notification` runs the evaluation smoke, verifies the Notification inbox, notification, and delivery rows, and verifies the student's notification APIs through the gateway.

## Credentials

RabbitMQ:

- Username: `ags`
- Password: `ags_password`

MinIO:

- Username: `ags`
- Password: `ags_password`

Demo Identity accounts:

- `admin@ags.local` / `Password123!`
- `lecturer@ags.local` / `Password123!`
- `student@ags.local` / `Password123!`

## Frontend Env

```bash
NEXT_PUBLIC_API_URL=http://localhost:8080
NEXT_PUBLIC_USE_MOCK_AUTH=false
```

## Environment Files

Root `.env.example` is the primary environment template for `compose.yaml`.

```bash
make env
```

creates root `.env` if missing and also creates legacy `compose/.env` if missing. Existing env files are not overwritten.

Do not commit `.env` or `compose/.env`.

If your local `.env` predates OPS-005, add the new CLASS_* and SUBMISSION_* variables manually or regenerate it:

```bash
rm .env && cp .env.example .env
```

## Legacy Host Mode

Legacy host-mode still exists for backend debugging:

- Infrastructure uses `compose/docker-compose.infra.yml`.
- Gateway uses `compose/docker-compose.gateway.yml`.
- The gateway can route to a host-running Identity Service with `IDENTITY_UPSTREAM=host.docker.internal:8081`.

Useful legacy commands:

```bash
make infra-up
make infra-ps
make smoke-infra
make gateway-up
make gateway-ps
make smoke-auth
make auth-stack-down
```

Full Docker mode is recommended for testers.
