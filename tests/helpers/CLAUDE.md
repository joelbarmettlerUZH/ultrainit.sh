# tests/helpers/ — Shared Test Infrastructure

Two files that together define the entire test support layer for the bats-core suite.

## Files

- `test_helper.bash` — bootstraps isolated test environment, exports defaults, sources libs, provides `make_claude_envelope`
- `mock_claude.bash` — installs a PATH-based fake `claude` binary that intercepts all `claude -p` calls

## Loading Order

Every `.bats` `setup()` must follow this exact sequence:

```bash
setup() {
    load '../helpers/test_helper'   # provides _common_setup, make_claude_envelope
    _common_setup                   # creates tmpdir, sets env, sources all 9 libs
    load '../helpers/mock_claude'   # provides setup_mock_claude
    setup_mock_claude               # installs mock binary on PATH
}
```

`setup_mock_claude` must be called AFTER `_common_setup` because the mock binary is written to `$TEST_TMPDIR/mock_bin/`, which doesn't exist until `_common_setup` creates `TEST_TMPDIR`.

Tests for standalone scripts (`tests/scripts/`) skip `setup_mock_claude` — the validators never call `claude`.

## `_common_setup()` Behavior

1. Creates `TEST_TMPDIR=$(mktemp -d)` as the test root
2. Sets `WORK_DIR=$TEST_TMPDIR/.ultrainit` with full subdirectory structure (findings, logs, costs, synthesis, etc.)
3. Sets `TARGET_DIR=$TEST_TMPDIR/target`
4. Exports all env defaults **before** sourcing libs (libs use `${VAR:-default}` at source time):
   - `FORCE=false`, `DRY_RUN=false`, `NON_INTERACTIVE=true`, `VERBOSE=false`
   - `TOTAL_BUDGET=10.00`, `AGENT_BUDGET=0.50`, `AGENT_MODEL=haiku`, `SYNTH_MODEL=sonnet`
   - `ULTRAINIT_MAX_RETRIES=1` (prevents retry delays in error-path tests)
   - Color codes exported as empty strings (prevents ANSI from breaking `assert_output --partial`)
5. Sources all 9 lib files in dependency order (utils → config → agent → gather → ask → research → synthesize → validate → merge)

## `mock_claude.bash` Details

### How the Mock Works

A real executable bash script is written to `$TEST_TMPDIR/mock_bin/claude` and `$TEST_TMPDIR/mock_bin/` is prepended to `$PATH`. Every child process inherits this PATH, including those spawned by `run_agents_parallel` in separate bash subshells. This is the only mocking approach that works across subprocess boundaries.

### Three Response Modes

**Single mode**: Set `$MOCK_CLAUDE_RESPONSE` to a file path containing the envelope JSON. The mock returns that file for every invocation.

**Dispatch mode**: Set `$MOCK_CLAUDE_DISPATCH_DIR` to a directory. Create per-agent files with `create_dispatch_response`:
```bash
create_dispatch_response 'identity' "$(cat fixtures/findings/identity.json)" '0.15'
```
The mock does case-insensitive substring matching of the agent name against the `--json-schema` argument basename (stripping `.json`). First match wins. Falls back to `$MOCK_CLAUDE_RESPONSE` if no match.

**Error mode**: Set `$MOCK_CLAUDE_EXIT_CODE=1`. The mock exits with that code for all invocations.

### Special Case: `claude auth status`

The mock detects the `auth` argument and returns `{"loggedIn": true}` unconditionally. This special case must be preserved — `lib/config.sh` calls `claude auth status` to verify authentication. If the mock is modified, keep this check before the general dispatch logic.

### Logging

All invocations are appended to `$MOCK_CLAUDE_LOG`:
- `CALL: <full command line>` for every invocation
- `STDIN: N bytes` when data is piped via stdin (for large-prompt testing)

Assert that mock was called: `assert grep -q 'CALL:' "$MOCK_CLAUDE_LOG"`
Assert that mock was NOT called (skip behavior): `refute_output --partial 'CALL:'` after `run cat "$MOCK_CLAUDE_LOG"`

### `make_claude_envelope()`

Wraps structured output JSON in the real `claude -p --output-format json` response shape:

```bash
make_claude_envelope '{"key":"val"}' "0.42"          # is_error=false, cost=0.42
make_claude_envelope '{"key":"val"}' "5.00" "true"   # is_error=true
```

Output:
```json
{"is_error": false, "total_cost_usd": 0.42, "structured_output": {"key": "val"}}
```

For budget exhaustion tests, write the envelope manually with `subtype: "error_max_budget_usd"`.

## Critical Gotchas

**Dispatch mode name matching is case-insensitive substring matching.** An agent named `docs` will match before `docs-scanner` if `docs.json` appears first in glob expansion. Name dispatch files unambiguously — longer/more-specific names should come first alphabetically.

**Env vars must be exported before sourcing libs.** `config.sh` reads `${VAR:-default}` at source time. Setting `TOTAL_BUDGET` after `_common_setup` has no effect on already-computed budget values.

**The mock binary uses `local` at global scope.** The heredoc uses a quoted delimiter (`<<'MOCK_SCRIPT'`) so variables are literal at write time. `local` at script top level is silently ignored by bash (doesn't fail, but variables are not scoped). Do not rely on variable scoping inside the mock binary.

**`make_claude_envelope` uses `{}` for missing first arg.** `local structured_output="${1:-\{\}}"`. Passing an empty string uses `{}` as structured output. Always pass a valid JSON object as `$1`.
