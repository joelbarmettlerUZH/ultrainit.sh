---
name: add-integration-test
description: "
  Scaffold a new integration test for a phase function in tests/integration/.
  Use when add a phase-level test, test the full gather phase, integration
  test for synthesize, test resume behavior, or test agent failure handling
  at phase level. Do NOT use for unit tests of individual functions — those
  belong in tests/unit/.
---

## Before You Start

- `tests/integration/gather_phase.bats` — dispatch mode setup pattern, failure gating tests
- `tests/integration/synthesize_phase.bats` — synthesis retry, ULTRAINIT_MAX_RETRIES usage
- `tests/integration/resume.bats` — state.json phase-completion skip pattern
- `tests/helpers/test_helper.bash` — `_common_setup`, `make_claude_envelope`
- `tests/fixtures/findings/` — all 8 findings fixtures to use in dispatch

## Steps

### 1. Create the .bats file

```bash
touch tests/integration/<phase>_<scenario>.bats
```

Boilerplate (copy from `tests/integration/gather_phase.bats`):

```bash
#!/usr/bin/env bats
# Integration tests for <phase_function>: <scenario>

setup() {
    load '../helpers/test_helper'
    _common_setup
    load '../helpers/mock_claude'
    setup_mock_claude

    # Set ULTRAINIT_MAX_RETRIES=1 for any test involving synthesis
    # (prevents 30s retry delays in error-path tests)
    export ULTRAINIT_MAX_RETRIES=1
}

teardown() {
    _common_teardown
}
```

### 2. Choose mock mode

**Dispatch mode** (for multi-agent phase tests):

```bash
@test "gather_evidence: all agents succeed" {
    # Create dispatch responses for all 8 core agents
    for agent in identity commands git-forensics patterns tooling docs-scanner security-scan structure-scout; do
        make_claude_envelope \
            "$(cat "$BATS_TEST_DIRNAME/../fixtures/findings/${agent}.json")" \
            "0.15" > "$MOCK_CLAUDE_DISPATCH_DIR/${agent}.json"
    done

    run gather_evidence
    assert_success
    assert_file_exists "$WORK_DIR/findings/identity.json"
    run jq '.gather' "$WORK_DIR/state.json"
    refute_output 'null'
}
```

**Single mode** (for synthesis tests):

```bash
@test "synthesize: pass 1 writes CLAUDE.md output" {
    # Pre-populate all findings that build_docs_context reads
    for agent in identity commands git-forensics patterns tooling docs-scanner security-scan structure-scout; do
        cp "$BATS_TEST_DIRNAME/../fixtures/findings/${agent}.json" \
            "$WORK_DIR/findings/"
    done
    cp "$BATS_TEST_DIRNAME/../fixtures/developer-answers.json" \
        "$WORK_DIR/developer-answers.json"

    make_claude_envelope \
        "$(cat "$BATS_TEST_DIRNAME/../fixtures/synthesis/output-docs.json")" \
        "2.50" > "$MOCK_CLAUDE_RESPONSE"

    run synthesize
    assert_success
    assert_file_exists "$WORK_DIR/synthesis/output-docs.json"
}
```

### 3. Write resume/skip tests

```bash
@test "gather_evidence: skips when phase already complete" {
    # Mark gather complete in state.json
    mark_phase_complete "gather"

    FORCE=false run gather_evidence
    assert_success
    # Verify mock was never called
    run grep -c 'CALL:' "$MOCK_CLAUDE_LOG"
    assert_output "0"
}
```

### 4. Pre-populate findings for downstream phase tests

Synthesis tests require all findings to exist. Copy fixtures, not raw — dispatch routing needs the three-way identity:

```bash
# Correct: copy to $WORK_DIR/findings/ (not synthesis/)
cp "$BATS_TEST_DIRNAME/../fixtures/findings/identity.json" "$WORK_DIR/findings/"

# WRONG: developer-answers.json goes in $WORK_DIR, NOT findings/
cp "$BATS_TEST_DIRNAME/../fixtures/developer-answers.json" "$WORK_DIR/developer-answers.json"
```

### 5. Assert on phase state and findings

```bash
# Phase completion
run is_phase_complete "gather"
assert_success

# Findings file exists and has correct content
assert_file_exists "$WORK_DIR/findings/identity.json"
run jq -e '.name' "$WORK_DIR/findings/identity.json"
assert_success
```

## Verify

```bash
make test-integration
```

Check raw output — integration tests run with `|| true` in CI and always show green.

## Common Mistakes

1. **Forgetting `make_claude_envelope` wrapper** — raw fixture JSON causes `run_agent` to write `"null"` to findings silently. Every mock response must be envelope-wrapped.

2. **Dispatch name collision** — dispatch mode matches by case-insensitive substring of `--json-schema` basename. If `docs.json` appears before `docs-scanner.json` in alphabetical order, the wrong fixture is served. Use more specific names.

3. **Systemic failure threshold math** — `gather_phase.bats` pre-creates exactly 4 of 8 findings to test systemic failure (3+ of 8 failed). If you add a 9th core agent, update this test.
