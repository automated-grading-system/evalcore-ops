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
- `https://prn232.dorriss.com`

Browser `PUT` to presigned URLs should work for:

- `lab-assets`
- `submission-assets`

The same MinIO API CORS setting covers `evaluation-reports`, which is reserved for future report downloads.

## Vercel and production CORS

The Vercel frontend at `https://prn232.dorriss.com` is included in the default
`CORS_ALLOWED_ORIGINS` and `MINIO_API_CORS_ALLOW_ORIGIN` values. Caddy handles
Gateway `/api/*` preflight requests and adds API response CORS headers for the
approved origins. The Gateway policy allows `Authorization` and `Content-Type`
headers and `GET`, `POST`, `PATCH`, `PUT`, `DELETE`, and `OPTIONS` methods.

For browser presigned uploads, MinIO must be published at a public HTTPS URL.
Set `S3_PUBLIC_ENDPOINT` in the deployment `.env` to that browser-reachable
URL (not `localhost` or `http://minio:9000`) and set `S3_USE_SSL=true`. MinIO
CORS must allow `https://prn232.dorriss.com`; presigned upload/download flows
need `GET`, `PUT`, `POST`, and `HEAD` available to the browser.

The frontend Vercel environment must set `NEXT_PUBLIC_API_URL` to the public
Cloudflare Tunnel URL for this Gateway, for example
`https://api-prn232.dorriss.com`.

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

Evaluation scoring has two explicit modes:

- Labs without a rubric keep the original equal-assertion policy. Passing assertions are divided by total assertions and scaled to a maximum score of 100.
- Labs with criteria configured through `PUT /api/labs/{labId}/rubric` use the lecturer-defined weights. A criterion receives its full weight only when every matching Newman assertion passes; a required criterion with no match receives zero and is reported as missing.

The original `make smoke-evaluation` path intentionally has no rubric. It remains the regression check for equal-assertion fallback.
Run `make smoke-rubric` for the corresponding end-to-end weighted check. It
configures the 10-point fixture, runs the weighted collection, and verifies the
evaluation API plus `report.json` scoring breakdown.

`make smoke-notification` runs the evaluation smoke, verifies the Notification inbox, notification, and delivery rows, and verifies the student's notification APIs through the gateway.

## Live grading burst demo

EvalCore deliberately separates accepting a submission from running its untrusted
project. Submission events are published through the durable outbox to RabbitMQ,
the Evaluation Service records queued evaluations in PostgreSQL as a durable
waiting room, and the runner starts only
`EVALUATION_RUNNER_CONCURRENCY` isolated Docker sandboxes at once. The default is
`2`; the system intentionally does not start 100 Docker jobs when 100 students
submit together.

For the review environment, use `EVALUATION_STARTUP_TIMEOUT_SECONDS=180`. This
gives a freshly created sandbox database more time to initialize without
changing, suppressing, or manufacturing an evaluation result. Existing `.env`
files override the Compose default, so update that local value before recreating
the runner if it is still set to `90`.

After starting or recreating the stack, run `make smoke-evaluation` once before
the full burst. That honest end-to-end check validates the fixture and warms the
Docker image/build cache; it does not seed evaluation results or bypass the
normal submission event path.

Run the real API demo with:

```bash
make demo-100-submissions
```

The lecturer frontend must already be running and its live monitor route must be
reachable. The script checks this before it creates any accounts, classes, or
submissions:

```bash
cd ../prn232-pe-evaluation-fe
bun run dev
```

The script creates a fresh class and active lab, configures the 12-criterion
10-point rubric from `fixtures/prn232-weighted-rubric.json`, registers 100 unique
student accounts through Identity, joins them to the class, uploads exactly one
real ZIP per student through the submission's presigned URL, and then completes
the submissions in a bounded burst. It verifies unique emails, student IDs, and
submission IDs. It never seeds the database and never calls a manual evaluation
endpoint. It waits only until all accepted events appear in the Evaluation
database by default; the Docker evaluations continue in the background while
the lecturer watches `http://localhost:3000/lecturer/live-grading`.

The default `DEMO_VARIANT_MODE=uniform` preserves the pacing/stress demo: every
student submits the known-good ZIP and should receive `passed` with `10.0/10.0`.

Build the deterministic submission variants and run the self-verifying small
mixed demo with:

```bash
make demo-build-variants
make demo-10-submissions-mixed
```

The generator derives every ZIP from the known-good submission fixture and
writes them to `../test/dist/evaluation/variants`. That workspace fixture path
is not tracked by the Ops repository, so generated ZIPs stay local and can be
recreated at any time from the committed generator.

Mixed mode uses the weighted collection under
`../test/dist/evaluation/PRN232-LMS-LAB2-weighted.postman_collection.json` and
the real ZIPs under `../test/dist/evaluation/variants`. Every represented
variant is interleaved deterministically across unique students. For counts of
at least eight, every variant appears at least once; the 10-student target uses
three passing ZIPs and one of each of the other seven variants. Once all ten
evaluations finish, the script joins monitor results back to each stored
submission ID and verifies scoring mode, the 10-point maximum, expected status,
reduced scores for assertion failures, and zero-score coded infrastructure
errors.

For the full review intake, run:

```bash
make demo-100-submissions-mixed
```

The exact 100-student distribution is 60 pass, 8 Swagger failures, 10
pagination failures, 8 response-format failures, 6 multiple-criteria failures,
4 readiness errors, 2 build errors, and 2 invalid-Compose errors. The full target
does not wait for every sandbox unless `DEMO_WAIT_FOR_COMPLETION=true` is set.

After intake, the script verifies that scoped `running` and global `activeSlots`
do not exceed the API's numeric `runnerConcurrency`, rechecks service health,
and, for a local Gateway, reports active `evalcore-*` Compose projects and
rejects excess projects or exited sandbox leftovers.

Tune HTTP burst size independently from runner pacing:

```bash
DEMO_SUBMISSION_COUNT=10 DEMO_SUBMIT_CONCURRENCY=5 make demo-100-submissions
```

To keep polling until every evaluation reaches a terminal state, opt in
explicitly. Uniform mode requires every result to pass. Mixed mode instead
requires its exact expected passed/failed/error distribution; genuine grading
failures and infrastructure errors are successful evidence for that demo:

```bash
DEMO_WAIT_FOR_COMPLETION=true make demo-100-submissions
```

The burst demo defaults to
`fixtures/PRN232-LMS-LAB2-weighted.postman_collection.json`. Its assertion
names contain the rubric match patterns and still execute real HTTP/OpenAPI
checks. Docker Deployment is represented by successful Compose readiness plus
the health assertion. Architecture, project naming, model coverage, and Code
Quality use documented runtime/OpenAPI proxies; Newman alone cannot fully prove
source organization or maintainability. A future static-analysis plugin should
replace those proxies where full rigor is required.

The rubric total is 10.0 and each criterion has its own `maxScore`. Normal
Newman assertion failures reduce the weighted score and remain `failed` business
results. Invalid packages, build failures, and readiness failures remain
zero-score `error` results; the script does not disguise them as rubric misses.

Useful optional settings are `DEMO_VARIANT_MODE` (`uniform` by default),
`DEMO_VARIANTS_DIR`, `DEMO_MONITOR_TIMEOUT_SECONDS` (default `300`),
`DEMO_WAIT_TIMEOUT_SECONDS` (default `14400`), `DEMO_MONITOR_POLL_SECONDS`
(default `2`), `DEMO_EXPECTED_RUNNER_CONCURRENCY` (default `2`),
`DEMO_FRONTEND_URL`, `EVAL_FIXTURE_ZIP`, and
`EVAL_COLLECTION_JSON`. Override `DEMO_RUBRIC_JSON` only together with a
collection whose real assertion names match every required criterion. API calls
Mixed mode's exact score/error self-verification is calibrated to the supplied
rubric, collection, and generated variants. API calls and uploads also have
bounded connection and
request timeouts so a stalled service cannot leave a parallel worker hanging;
override `DEMO_CURL_CONNECT_TIMEOUT_SECONDS`,
`DEMO_CURL_HEALTH_TIMEOUT_SECONDS`, `DEMO_CURL_API_TIMEOUT_SECONDS`, or
`DEMO_CURL_UPLOAD_TIMEOUT_SECONDS` only when the target environment needs it.
Each run uses fresh timestamped accounts and data so that its lab-scoped monitor
counts remain unambiguous.

For safety, `GATEWAY_URL` must use `localhost`, `127.0.0.1`, or `[::1]` by
default. A deliberate staging run must opt in, use an HTTPS Gateway so demo
credentials and tokens remain encrypted in transit, and point at a reachable
frontend:

```bash
DEMO_ALLOW_REMOTE=true \
GATEWAY_URL=https://api-staging.example.com \
DEMO_FRONTEND_URL=https://staging.example.com \
make demo-100-submissions
```

Remote runs never use the local demo student password. Set a non-default
`DEMO_STUDENT_PASSWORD`, or leave it empty and the script generates a strong
per-run password without printing it.

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
