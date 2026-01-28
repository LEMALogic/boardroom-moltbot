# Boardroom Command Center Makefile
# ==================================
# Build, test, and deploy commands for the Boardroom Command Center

.PHONY: build build-console build-proxy \
        run stop restart logs shell \
        test test-all test-branding \
        dev clean prune \
        create-user remove-user \
        push deploy-prod

# Docker compose file location
COMPOSE := docker compose -f docker/docker-compose.yml

# ==============================================================================
# Building
# ==============================================================================

## Build all Docker containers
build:
	$(COMPOSE) build

## Build just the console container
build-console:
	$(COMPOSE) build console

## Build just the proxy container
build-proxy:
	$(COMPOSE) build proxy

# ==============================================================================
# Running
# ==============================================================================

## Start the full stack
run:
	$(COMPOSE) up -d

## Stop all containers
stop:
	$(COMPOSE) down

## Stop and start (restart all containers)
restart: stop run

## Show container logs (follow mode)
logs:
	$(COMPOSE) logs -f

## SSH into the console container
shell:
	$(COMPOSE) exec console /bin/bash

# ==============================================================================
# Testing
# ==============================================================================

## Run Playwright E2E tests (real LLM)
test:
	cd tests && npx playwright test

## Run all tests including real LLM chat
test-all:
	cd tests && npx playwright test --project=all

## Verify no Clawdbot/Moltbot text in UI (branding check)
test-branding:
	cd tests && npx playwright test e2e/branding.spec.ts

# ==============================================================================
# Development
# ==============================================================================

## Start in development mode with auto-reload
dev:
	docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up

## Remove all containers and volumes
clean:
	$(COMPOSE) down -v --remove-orphans

## Docker system prune (remove unused data)
prune:
	docker system prune -f

# ==============================================================================
# User Management
# ==============================================================================

## Create a new user (usage: make create-user USER=username)
create-user:
ifndef USER
	$(error USER is required. Usage: make create-user USER=username)
endif
	./scripts/create-user.sh $(USER)

## Remove a user (usage: make remove-user USER=username)
remove-user:
ifndef USER
	$(error USER is required. Usage: make remove-user USER=username)
endif
	./scripts/remove-user.sh $(USER)

# ==============================================================================
# Deployment
# ==============================================================================

## Push images to ghcr.io
push:
	$(COMPOSE) push

## Deploy to production
deploy-prod:
	@echo "Deploying to production..."
	docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d
