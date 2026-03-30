SHELL := /bin/bash
.PHONY: bundle clean check test

DIST_DIR := dist
BUNDLE := $(DIST_DIR)/ultrainit.sh

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

clean:
	rm -rf $(DIST_DIR)
