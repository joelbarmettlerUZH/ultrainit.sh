---
name: add-edge-test
description: "
  Scaffold a new edge test file for a known failure domain in ultrainit.
  Use when add an edge test, document this bug in tests, test boundary
  behavior, regression test for this fix, or cover this known limitation.
  Do NOT use for unit tests of lib functions — those go in tests/unit/.
---

## Before You Start

- `tests/edge/corrupt_state.bats` — bug-documenting test pattern (documents known silent failure)
- `tests/edge/special_characters.bats` — how to test shell expansion edge cases
- `tests/edge/numeric_edge_cases.bats` — bc arithmetic boundary tests
- `tests/helpers/test_helper.bash` — `_common_setup` (all 9 libs sourced, including `synthesize.sh`'s `nullglob` side effect)

## When to Use Edge Tests vs Unit Tests

| Scenario | Location |
|----------|----------|
| Testing a known bug (regression) | `tests/edge/` |
| Testing CLI argument parsing | `tests/edge/cli_args.bats` |
| Testing budget boundary conditions | `tests/edge/budget_exhaustion.bats` |
| Testing a lib function's normal behavior | `tests/unit/` |
| Testing a shell expansion quirk | `tests/edge/` |

## Steps

### 1. Create the test file

```bash
touch tests/edge/<domain>.bats
```

File header:

```bash
#!/usr/bin/env bats
# Edge cases for <domain>: <one-line description of what failure domain this covers>

setup() {
    load '../helpers/test_helper'
    _common_setup
    # Only add mock_claude if testing agent execution paths:
    # load '../helpers/mock_claude'
    # setup_mock_claude
}

teardown() {
    _common_teardown
}
```

### 2. Write bug-documenting tests

Edge tests document actual behavior (including bugs), not ideal behavior. The pattern from `tests/edge/corrupt_state.bats`:

```bash
@test "cost files without pipe delimiters are silently treated as zero spend" {
    # Inject malformed cost file (no pipe separators)
    echo "50.00" > "$WORK_DIR/costs/agent.cost"

    run check_budget
    # Documents the bug: malformed files contribute $0, not $50
    assert_success  # budget check passes even though it should detect $50
}
```

If you are documenting a known bug, add a comment explaining the bug and why it isn't fixed yet.

### 3. Manual state injection

Edge tests often need specific preconditions. Inject state directly:

```bash
@test "bc produces .20 not 0.20 for values under 1" {
    # Set budget so AGENT_BUDGET will be fractional
    TOTAL_BUDGET="1.00"
    _common_setup  # re-source with new budget

    # bc with scale=2: result is '.20' not '0.20'
    local result
    result=$(echo 'scale=2; 1/5' | bc)
    [[ "$result" == ".20" || "$result" == "0.20" ]]
}
```

### 4. nullglob side effect tests

Because `synthesize.sh` sets `shopt -s nullglob` globally at source time (via `_common_setup`), edge tests can test nullglob interactions:

```bash
@test "empty costs directory does not block budget check" {
    # With nullglob: *.cost matches nothing, expands to empty string
    rm -f "$WORK_DIR/costs"/*.cost
    run check_budget
    assert_success
}
```

Note: You **cannot** test non-nullglob behavior in isolation — `_common_setup` always sources `synthesize.sh`, which always sets nullglob.

### 5. Special character edge cases

For shell expansion bugs (see `tests/edge/special_characters.bats`):

```bash
@test "prompts with apostrophes use @file form to avoid expansion" {
    local prompt_file="$TEST_TMPDIR/prompt.txt"
    echo "This project's goal is testing" > "$prompt_file"

    make_claude_envelope '{}' '0.10' > "$MOCK_CLAUDE_RESPONSE"

    run run_agent "test-agent" "@${prompt_file}" \
        "${SCRIPT_DIR}/schemas/identity.json" "Read" "haiku"
    assert_success
}
```

## Verify

```bash
make test-edge
```

Or for a single file:
```bash
docker run --rm -v "$(pwd)":/workspace -w /workspace \
    ghcr.io/joelbarmettleruzh/ultrainit-test:latest \
    bats tests/edge/<domain>.bats
```

## Common Mistakes

1. **Testing current (buggy) behavior as if it were correct** — the project rule says "write tests to test the actually correct behaviour". For bug-documenting tests, clearly label them as documenting a known bug with a comment, not as asserting the correct behavior.

2. **Forgetting nullglob is always active** — `synthesize.sh` sets `shopt -s nullglob` at source time. All glob patterns in all tests expand differently than they would in isolation. Tests that rely on a glob pattern returning the literal string when no files match will silently pass for the wrong reason.
