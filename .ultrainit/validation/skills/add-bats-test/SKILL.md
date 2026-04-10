---
name: add-bats-test
description: "
  Scaffold a new bats unit test file for a lib/*.sh function. Use when
  add a test, write a test for this function, add unit coverage, or cover
  this edge case with a test. Do NOT use for integration tests (those go
  in tests/integration/ with phase-level setup) or for script validator
  tests (those go in tests/scripts/).
---

## Before You Start

- `tests/unit/agent_run.bats` — canonical example of agent function tests
- `tests/unit/config_budget.bats` — example of pure function tests (no mock claude)
- `tests/helpers/test_helper.bash` — `_common_setup`, `make_claude_envelope` API
- `tests/helpers/mock_claude.bash` — `setup_mock_claude`, `create_dispatch_response`

## Steps

### 1. Determine test location and type

| Function under test | Test file location |
|---------------------|--------------------|
| `lib/*.sh` function (no claude call) | `tests/unit/<subsystem>.bats` |
| `lib/*.sh` function (calls `run_agent`) | `tests/unit/<subsystem>.bats` + mock claude |
| Phase entry function | `tests/integration/<phase>.bats` |
| `scripts/validate-*.sh` | `tests/scripts/validate_<name>.bats` |
| Budget/state edge case | `tests/edge/<domain>.bats` |

### 2. Create the .bats file

Every unit test file must follow this exact setup order:

```bash
#!/usr/bin/env bats
# Tests for <function-name> in lib/<file>.sh

setup() {
    load '../helpers/test_helper'
    _common_setup              # creates TEST_TMPDIR, exports defaults, sources all 9 libs
    load '../helpers/mock_claude'
    setup_mock_claude          # installs mock binary on PATH (needed only if testing claude calls)
}

teardown() {
    _common_teardown
}
```

If the functions under test never call `run_agent` or `claude -p` directly, omit the `mock_claude` lines.

**Do not call `setup_mock_claude` before `_common_setup`** — the mock binary writes to `$TEST_TMPDIR/mock_bin/` which doesn't exist until `_common_setup` creates it.

### 3. Write the success path test

```bash
@test "<function>: writes findings on success" {
    # Arrange: create mock response
    make_claude_envelope \
        "$(cat "$BATS_TEST_DIRNAME/../fixtures/findings/<agent>.json")" \
        "0.15" > "$MOCK_CLAUDE_RESPONSE"

    # Act
    run run_agent "<name>" "@${SCRIPT_DIR}/prompts/<name>.md" \
        "${SCRIPT_DIR}/schemas/<name>.json" \
        "Read,Bash(find:*)" "haiku" "gather"

    # Assert
    assert_success
    assert_file_exists "$WORK_DIR/findings/<name>.json"
    run jq -e '.key' "$WORK_DIR/findings/<name>.json"
    assert_success
}
```

### 4. Write the resumability test

Every agent must be skippable when findings exist and `FORCE=false`:

```bash
@test "<function>: skips when findings exist and FORCE=false" {
    # Pre-create findings
    echo '{"findings":[]}' > "$WORK_DIR/findings/<name>.json"

    FORCE=false run run_agent "<name>" "prompt" "schema" "tools" "haiku"
    assert_success

    # Verify mock was not called
    run grep -c 'CALL:' "$MOCK_CLAUDE_LOG"
    assert_output "0"
}
```

### 5. Write the budget exhaustion test

```bash
@test "<function>: rejects when budget exhausted" {
    # Pre-populate costs to exhaust budget
    echo "gather|prior-agent|$(echo "$TOTAL_BUDGET + 1" | bc)" \
        > "$WORK_DIR/costs/prior-agent.cost"

    run run_agent "<name>" "prompt" "schema" "tools" "haiku"
    assert_failure
}
```

### 6. Cost file format assertion

For agents that should record costs:

```bash
@test "<function>: records cost to cost file" {
    make_claude_envelope '{}' '0.42' > "$MOCK_CLAUDE_RESPONSE"
    run run_agent "<name>" "prompt" "${SCRIPT_DIR}/schemas/<name>.json" "tools"
    assert_success
    assert_file_exists "$WORK_DIR/costs/<name>.cost"
    run grep '0.42' "$WORK_DIR/costs/<name>.cost"
    assert_success
}
```

### 7. Important test conventions

- **Set env vars BEFORE `_common_setup`**: `config.sh` reads `${VAR:-default}` at source time. Setting `TOTAL_BUDGET` after `_common_setup` has no effect.
- **bc produces `.20` not `0.20`** for values < 1. Assert both forms: `[[ "$x" == ".20" || "$x" == "0.20" ]]`
- **Color codes**: `_common_setup` exports empty color codes (`RED=''`) — ANSI codes are stripped for clean `assert_output --partial` matching.
- **`ULTRAINIT_MAX_RETRIES=1`** is set in `_common_setup` — tests won't wait for 3 retries.

## Verify

```bash
make test-unit
```

Or for a single file:
```bash
docker run --rm -v "$(pwd)":/workspace -w /workspace \
    ghcr.io/joelbarmettleruzh/ultrainit-test:latest \
    bats tests/unit/my-new-test.bats
```

## Common Mistakes

1. **Passing raw fixture JSON without `make_claude_envelope`** — `run_agent` extracts `.structured_output` from the response. Without the envelope wrapper, it writes `"null"` to findings silently.

2. **Loading `mock_claude` before `_common_setup`** — the mock binary is written to `$TEST_TMPDIR/mock_bin/` which `_common_setup` creates. Wrong order causes `setup_mock_claude` to fail.

3. **Not setting budget env vars before sourcing** — `_common_setup` sources all libs. Variables read at source time can't be changed after sourcing. Set overrides before calling `_common_setup`.

4. **Using `assert_output` without `--partial` for multi-line output** — validator output includes dynamic metrics. Use `assert_output --partial 'VERDICT: PASS'` not exact match.
