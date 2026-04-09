SHELL := /bin/bash
.PHONY: bundle clean check test test-unit test-scripts test-integration test-edge test-image smoke smoke-source

DIST_DIR := dist
BUNDLE := $(DIST_DIR)/ultrainit.sh
TEST_IMAGE := ghcr.io/joelbarmettleruzh/ultrainit-test:latest
DOCKER_RUN := docker run --rm -v $(CURDIR):/workspace $(TEST_IMAGE)

SOURCES := ultrainit.sh \
	$(wildcard lib/*.sh) \
	$(wildcard prompts/*.md) \
	$(wildcard schemas/*.json)

# Build a single self-contained ultrainit.sh
bundle: $(BUNDLE)

$(BUNDLE): bundle.sh $(SOURCES)
	@mkdir -p $(DIST_DIR)
	bash bundle.sh > $(BUNDLE)
	chmod +x $(BUNDLE)
	@echo ""
	@echo "Bundled: $(BUNDLE) ($$(wc -c < $(BUNDLE) | tr -d ' ') bytes)"
	@echo "  libs:    $$(ls lib/*.sh | wc -l) files"
	@echo "  prompts: $$(ls prompts/*.md | wc -l) files"
	@echo "  schemas: $$(ls schemas/*.json | wc -l) files"

# Syntax-check all shell scripts
check:
	@echo "Checking shell syntax..."
	@bash -n ultrainit.sh && echo "  ultrainit.sh: OK"
	@for f in lib/*.sh; do bash -n "$$f" && echo "  $$f: OK"; done
	@echo "Checking JSON schemas..."
	@for f in schemas/*.json; do jq empty "$$f" && echo "  $$f: OK"; done
	@echo "All checks passed."

# Run on the test repo (requires test-repos/open-webui to exist)
test: $(BUNDLE)
	@echo "Testing bundled script on open-webui..."
	bash $(BUNDLE) --non-interactive --skip-research test-repos/open-webui

# ── Docker-based bats tests ─────────────────────────────

test-unit: ## Run unit tests in Docker
	$(DOCKER_RUN) tests/unit/

test-scripts: ## Run standalone validator tests in Docker
	$(DOCKER_RUN) tests/scripts/

test-integration: ## Run integration tests in Docker
	$(DOCKER_RUN) tests/integration/

test-edge: ## Run edge case tests in Docker
	$(DOCKER_RUN) tests/edge/

test-all: ## Run all bats tests in Docker
	$(DOCKER_RUN) --recursive tests/

test-image: ## Build the test Docker image locally
	docker build -f Dockerfile.test -t $(TEST_IMAGE) .

# ── Smoke tests (real Claude, real codebase) ───────────────

smoke: $(BUNDLE) ## Smoke test: run bundled ultrainit on mini-project (~$1-3)
	bash tests/smoke/run-smoke.sh

smoke-source: ## Smoke test: run from source on mini-project (~$1-3)
	bash tests/smoke/run-smoke.sh --source

clean:
	rm -rf $(DIST_DIR)
