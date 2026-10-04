SHELL := /bin/bash
.DEFAULT_GOAL := help

# Root is needed only for deploy/destroy; sudo asks for a password if required.
SUDO := $(shell [ "$$(id -u)" -eq 0 ] || echo sudo)

.PHONY: help deploy check demo-logs demo-metrics creds canary destroy lint

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

deploy: ## Deploy everything on this host (idempotent, safe to re-run)
	$(SUDO) ./deploy.sh

check: ## Smoke-check all components (Gateway, app, TLS, metrics, logs)
	./scripts/check.sh

demo-logs: ## Send a request with X-Request-ID and find it in Loki
	./scripts/demo-logs.sh

demo-metrics: ## Generate traffic and print key PromQL results
	./scripts/demo-metrics.sh

creds: ## Print URLs and the Grafana login
	./scripts/creds.sh

canary: ## Set the share of traffic for v2, e.g. make canary W=50
	./scripts/canary.sh $(W)

destroy: ## Remove the cluster from this host (asks for confirmation; YES=1 to skip)
	$(SUDO) YES=$(YES) ./scripts/destroy.sh

lint: ## Static checks: shellcheck, yamllint, helm lint, kubeconform
	./scripts/lint.sh
