SHELL := /bin/bash
# := not ?=: with ?= the $(shell ...) re-runs on every reference, so `make up`
# would build one tag and then try to deploy a different one.
TAG := $(or $(TAG),local-$(shell git rev-parse --short=12 HEAD 2>/dev/null || date +%s))
IDENTITY ?= $(HOME)/.config/gsp/backup-identity.txt

.PHONY: help setup build up deploy rollback status backup restore drill zdt logs down lint test

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

setup: ## generate secrets, backup keypair, dev TLS cert, .env
	@test -f .env || cp .env.example .env
	scripts/init-secrets.sh
	scripts/gen-dev-cert.sh

build: ## build the app image as gsp-notes:$(TAG)
	docker build -t gsp-notes:$(TAG) --build-arg APP_VERSION=$(TAG) app

up: setup build ## first run: build and deploy the current checkout
	scripts/deploy.sh $(TAG)

deploy: ## deploy TAG=<tag> with blue/green switch
	scripts/deploy.sh $(TAG)

rollback: ## flip traffic back to the previous colour
	scripts/rollback.sh

status: ## what is running, what is live, when was the last backup
	scripts/status.sh

backup: ## take a backup now
	scripts/backup.sh

restore: ## restore newest off-site backup (IDENTITY=path/to/key)
	scripts/restore.sh --identity $(IDENTITY)

drill: ## destroy the db volume and restore it, with timings
	scripts/restore-drill.sh --identity $(IDENTITY)

zdt: ## deploy TAG under load and record dropped requests
	scripts/zero-downtime-test.sh $(TAG) 60

logs: ## tail all container logs
	source scripts/lib/common.sh && dc logs -f --tail 50

down: ## stop everything (keeps the data volume)
	source scripts/lib/common.sh && dc down

lint:
	cd app && npm run lint
	shellcheck -x scripts/*.sh scripts/lib/*.sh mongo/init/*.sh

test:
	cd app && npm test
