# tests/ — bats-core Test Suite

All tests run inside Docker using the pre-built `ghcr.io/joelbarmettleruzh/ultrainit-test:latest` image. No real Claude API calls are made in any test.

## Running Tests

```bash
make test-image          # Build test image locally (required if Dockerfile.test changed)
make test-unit           # tests/unit/ — individual lib functions
make test-scripts        # tests/scripts/ — validate-skill.sh, validate-subagent.sh
make test-edge           # tests/edge/ — boundary conditions, known bugs
make test-integration    # tests/integration/ — phase-level pipeline
make test-all            # all of the above
```

Smoke tests are intentionally excluded from `make test-all` — they make real API calls:
```bash
bash tests/smoke/run-smoke.sh --source   # ~$2 with haiku
```

## Directory Structure

```
tests/
├── helpers/
│   ├── test_helper.bash     # _common_setup, _common_teardown, make_claude_envelope
│   └── mock_claude.bash     # PATH-based mock claude binary
├── unit/                    # 11 .bats files, one per lib subsystem
├── integration/             # 3 .bats files: gather_phase, synthesize_phase, resume
├── scripts/                 # 2 .bats files: validate_skill, validate_subagent
├── edge/                    # 8 .bats files: budget, corrupt state, special chars, etc.
├── fixtures/
│   ├── findings/            # 8 JSON fixtures for Phase 1 agents
│   ├── synthesis/           # output-docs.json, output-tooling.json, output.json
│   ├── skills/              # valid + invalid SKILL.md fixtures
│   ├── subagents/           # valid + invalid subagent fixtures
│   ├── envelopes/           # (empty, reserved)
│   ├── hooks/               # (empty, reserved)
│   └── developer-answers.json
└── smoke/
    ├── run-smoke.sh
    └── mini-project/        # 4-file minimal Flask API target
```

## Test Infrastructure

### Setup Pattern

Every `.bats` file must follow this exact setup order:

```bash
setup() {
    load '../helpers/test_helper'
    _common_setup          # creates TEST_TMPDIR, exports env defaults, sources all 9 libs
    load '../helpers/mock_claude'
    setup_mock_claude      # writes mock binary to TEST_TMPDIR/mock_bin/, prepends to PATH
}

teardown() {
    _common_teardown       # rm -rf TEST_TMPDIR
}
```

Do not call `setup_mock_claude` before `_common_setup` — `TEST_TMPDIR` must exist first. Tests for standalone scripts (`tests/scripts/`) do not call `setup_mock_claude` because validators never invoke `claude`.

### Why All Libs Are Sourced Together

`_common_setup()` sources ALL 9 lib files in dependency order on every test setup. This is intentional: `synthesize.sh` sets `shopt -s nullglob` globally at source time. If sourced alone, this wouldn't affect `config.sh`. Sourced together, the glob option bleeds across libs — exactly as in production. Tests in `tests/edge/corrupt_state.bats` explicitly test this interaction.

### Mock Claude Binary

Function-level mocking fails across subprocess boundaries. Instead, a real executable `claude` binary is written to `$TEST_TMPDIR/mock_bin/` and prepended to `$PATH`. Every child process spawned by `run_agents_parallel` inherits this PATH.

Three modes:
- **Single mode**: set `$MOCK_CLAUDE_RESPONSE` to a file path; the mock returns that file's content for all calls
- **Dispatch mode**: set `$MOCK_CLAUDE_DISPATCH_DIR`; the mock matches agent name from `--json-schema` filename and returns the matching file
- **Error mode**: set `$MOCK_CLAUDE_EXIT_CODE=1`; the mock exits with that code

All invocations are logged to `$MOCK_CLAUDE_LOG` with `CALL:` prefix. Stdin is logged as `STDIN: N bytes`. Assert on these to verify mock was called (or not called, for skip tests).

### Response Envelope

Every mock response must match the real `claude -p --output-format json` envelope:
```json
{"is_error": false, "total_cost_usd": 0.42, "structured_output": {...}}
```

Use `make_claude_envelope` from `test_helper.bash`:
```bash
make_claude_envelope '{"key":"val"}' "0.42" > "$MOCK_CLAUDE_RESPONSE"
```

Never pass raw fixture JSON where an envelope is expected — `run_agent()` extracts `.structured_output` from the envelope and will get `null`, writing `"null"` to the findings file silently.

## Test Conventions

- **Cost file format**: `phase|agent_name|amount_usd` — one file per agent in `$WORK_DIR/costs/`
- **Budget comparisons**: always string equality against what `bc` produces (`.20` not `0.20` for values < 1)
- **Fixture mutations**: always copy with `cp` into `$TEST_TMPDIR`; never reference fixture files in-place
- **`ULTRAINIT_MAX_RETRIES=1`**: set in test environments to prevent synthesis retry delays
- **Color codes exported empty**: `_common_setup` exports `RED='' GREEN='' BOLD=''` etc. to prevent ANSI codes from breaking `assert_output --partial` matching
- **Env vars before sourcing**: set all environment overrides before calling `_common_setup`, not after — libs read `${VAR:-default}` at source time
- **`DRY_RUN=true` in merge tests**: asserts no files were created; use `assert_file_not_exists` before calling `write_artifacts()`

## Known Test Behaviors (Bug-Documenting Tests)

`tests/edge/validation_regex.bats` documents that `(never |don.t |do not )` requires trailing spaces — `Never` at end-of-line is not detected. Do not fix this without updating the test.

`tests/edge/corrupt_state.bats` documents that cost files without pipe delimiters are silently treated as $0 spend. Do not fix without updating the test.

`tests/edge/numeric_edge_cases.bats` documents that `bc` produces `.20` not `0.20` for values < 1. Always accept both forms in assertions: `[[ "$x" == ".20" || "$x" == "0.20" ]]`.

## Fixture Maintenance

### `tests/fixtures/findings/`

One JSON file per Phase 1 agent, named to match the agent name exactly (three-way identity: fixture filename = agent name in `run_agent()` = findings file in `.ultrainit/findings/`). Breaking any link breaks mock dispatch routing.

5 of 8 fixtures have fields that violate their corresponding schemas but tests still pass — no runtime schema validation exists in `agent.sh`. Known violations: `patterns.json` (invalid `type` enum), `tooling.json` (missing `purpose`), `structure-scout.json` (invalid role strings, extra fields).

### `tests/fixtures/synthesis/`

`output-docs.json` and `output-tooling.json` must NOT be pre-merged — they test the merge function. `output.json` is independently maintained as the expected post-merge result. When updating either pass fixture, regenerate `output.json`:
```bash
jq -s '.[0] * .[1]' tests/fixtures/synthesis/output-docs.json \
    tests/fixtures/synthesis/output-tooling.json > tests/fixtures/synthesis/output.json
```

`developer-answers.json` lives one level up in `tests/fixtures/` (not in `findings/`) because it is Phase 2 output, not Phase 1. Copy it to `$WORK_DIR/developer-answers.json` (not `$WORK_DIR/findings/`) in synthesis tests.
