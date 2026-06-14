# Automated Grading System Ops

This repository contains local Docker orchestration for the Automated Grading System.

## Recommended: Full Docker Auth Stack

This is the tester/developer path. It requires Docker only. It does not require the Identity source repository, a local .NET SDK, or a local backend build.

1. Copy env:

```bash
cp .env.example .env
```

2. Start the full auth stack:

```bash
docker compose --profile app up -d
```

or:

```bash
make app-up
```

3. Check status:

```bash
docker compose --profile app ps
```

or:

```bash
make app-ps
```

4. Smoke test:

```bash
make smoke-app
```

5. Stop:

```bash
docker compose --profile app down
```

or:

```bash
make app-down
```

The root `compose.yaml` is the primary entry point:

- `docker compose up -d` starts infrastructure only.
- `docker compose --profile app up -d` starts infrastructure, Identity Service, and the Caddy gateway.

## App Commands

```bash
make env
make app-pull
make app-up
make app-ps
make smoke-app
make app-logs
make app-down
```

`make app-up` does not build backend images. Docker Compose pulls or uses the configured Identity image.

## URLs

- Gateway: `http://localhost:8080`
- Identity direct: `http://localhost:8081`
- RabbitMQ Management: `http://localhost:15672`
- MinIO Console: `http://localhost:9001`
- PostgreSQL: `localhost:5432`

Gateway test URLs:

- Gateway health: `http://localhost:8080/health`
- Identity health through gateway: `http://localhost:8080/identity/health`
- Identity login through gateway: `http://localhost:8080/api/auth/login`
- Current user through gateway: `http://localhost:8080/api/users/me`

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

## Identity Image

Default image:

```bash
IDENTITY_IMAGE=dorrissdang/evalcore-identity-service:main
```

Override it in `.env` for a specific tag:

```bash
IDENTITY_IMAGE=dorrissdang/evalcore-identity-service:v1
```

or:

```bash
IDENTITY_IMAGE=dorrissdang/evalcore-identity-service:sha-xxxx
```

## Environment Files

Root `.env.example` is the primary environment template for `compose.yaml`.

```bash
make env
```

creates root `.env` if missing and also creates legacy `compose/.env` if missing. Existing env files are not overwritten.

Do not commit `.env` or `compose/.env`.

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
