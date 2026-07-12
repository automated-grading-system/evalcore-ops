ROOT_ENV_FILE := .env
ROOT_ENV_EXAMPLE := .env.example
LEGACY_COMPOSE_FILE := compose/docker-compose.infra.yml
LEGACY_GATEWAY_COMPOSE_FILE := compose/docker-compose.gateway.yml
LEGACY_ENV_FILE := compose/.env
LEGACY_ENV_EXAMPLE := compose/.env.example
COMPOSE := COMPOSE_IGNORE_ORPHANS=True docker compose --env-file $(LEGACY_ENV_FILE) -f $(LEGACY_COMPOSE_FILE)
GATEWAY_COMPOSE := COMPOSE_IGNORE_ORPHANS=True docker compose --env-file $(LEGACY_ENV_FILE) -f $(LEGACY_GATEWAY_COMPOSE_FILE)
APP_COMPOSE := docker compose --env-file $(ROOT_ENV_FILE)

.PHONY: env infra-up infra-down infra-reset infra-logs infra-ps smoke-infra
.PHONY: gateway-up gateway-down gateway-restart gateway-logs gateway-ps smoke-auth auth-stack-up auth-stack-down
.PHONY: app-pull app-up app-down app-restart app-ps app-logs smoke-app smoke-evaluation
.PHONY: services-pull services-up services-down web-up stack-up stack-down

env:
	@if [ ! -f "$(ROOT_ENV_FILE)" ]; then \
		cp "$(ROOT_ENV_EXAMPLE)" "$(ROOT_ENV_FILE)"; \
		echo "Created $(ROOT_ENV_FILE) from $(ROOT_ENV_EXAMPLE)"; \
	else \
		echo "$(ROOT_ENV_FILE) already exists"; \
	fi
	@if [ ! -f "$(LEGACY_ENV_FILE)" ]; then \
		cp "$(LEGACY_ENV_EXAMPLE)" "$(LEGACY_ENV_FILE)"; \
		echo "Created $(LEGACY_ENV_FILE) from $(LEGACY_ENV_EXAMPLE)"; \
	else \
		echo "$(LEGACY_ENV_FILE) already exists"; \
	fi

infra-up: env
	$(COMPOSE) up -d

infra-down: env
	$(COMPOSE) down

infra-reset: env
	$(COMPOSE) down -v

infra-logs: env
	$(COMPOSE) logs -f

infra-ps: env
	$(COMPOSE) ps postgres rabbitmq minio minio-init

smoke-infra: env
	./scripts/smoke-infra.sh

gateway-up: env
	$(GATEWAY_COMPOSE) up -d

gateway-down: env
	$(GATEWAY_COMPOSE) down

gateway-restart: env
	$(GATEWAY_COMPOSE) restart gateway

gateway-logs: env
	$(GATEWAY_COMPOSE) logs -f

gateway-ps: env
	$(GATEWAY_COMPOSE) ps gateway

smoke-auth: env
	./scripts/smoke-auth-gateway.sh

app-pull: env
	$(APP_COMPOSE) --profile app pull

app-up: env
	$(APP_COMPOSE) --profile app up -d

app-down: env
	$(APP_COMPOSE) --profile app down

app-restart: env
	$(APP_COMPOSE) --profile app restart

app-ps: env
	$(APP_COMPOSE) --profile app ps

app-logs: env
	$(APP_COMPOSE) --profile app logs -f

smoke-app: env
	./scripts/smoke-auth-gateway.sh

smoke-evaluation: env
	./scripts/smoke-evaluation.sh

auth-stack-up:
	$(MAKE) infra-up
	$(MAKE) gateway-up
	@echo "Identity Service must be running separately on host port 8081."

auth-stack-down:
	$(MAKE) gateway-down
	$(MAKE) infra-down
	@echo "Identity Service was not stopped because it runs from its own repository."

services-pull services-up services-down web-up stack-up stack-down:
	@echo "Not implemented yet. This will be added after backend images exist."
