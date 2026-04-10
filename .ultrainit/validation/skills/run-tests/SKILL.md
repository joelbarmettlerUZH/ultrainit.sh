---
name: run-tests
description: "
  Run the bats-core test suite for ultrainit inside Docker and interpret
  results. Use when run tests, check tests pass, make test-unit, verify
  nothing broke, or debugging a failing test. Covers all test tiers: unit,
  scripts, edge, integration. Do NOT use for smoke tests — those make real
  API calls and cost real money.
---

## Before You Start

- `Makefile` — all test targets and their Docker invocations
- `tests/helpers/test_helper.bash` — `_common_setup`, `make_claude_envelope`
- `tests/helpers/mock_claude.bash` — `setup_mock_claude`, dispatch mode
- `Dockerfile.test` — the test image (must be built if changed)

## Test Tiers

| Command | What it tests | Speed |
|---------|---------------|-------|
| `make test-unit` | Individual `lib/*.sh` functions | ~30s |
| `make test-scripts` | `scripts/validate-skill.sh`, `scripts/validate-subagent.sh` | ~15s |
| `make test-edge` | Budget exhaustion, corrupt state, special chars, numeric edge cases | ~20s |
| `make test-integration` | Phase-level pipeline (gather, synthesize, resume) | ~60s |
| `make test-all` | All of the above | ~2min |

## Running Tests

### Full suite

```bash
make test-all
```

### Single tier

```bash
make test-unit        # fastest, run after every lib change
make test-scripts     # after changes to scripts/validate-*.sh
make test-edge        # after changes to budget, config, or CLI arg handling
make test-integration # after changes to gather.sh, synthesize.sh, or merge.sh
```

### Single .bats file

The Makefile targets use Docker. To run one file, use the docker command directly:

```bash
docker run --rm \
    -v "$(pwd)":/workspace \
    -w /workspace \
    ghcr.io/joelbarmettleruzh/ultrainit-test:latest \
    bats tests/unit/agent_run.bats
```

### Verbose output

Add `--tap` for TAP format or `--verbose-run` for assertion details:

```bash
docker run --rm -v "$(pwd)":/workspace -w /workspace \
    ghcr.io/joelbarmettleruzh/ultrainit-test:latest \
    bats --verbose-run tests/unit/agent_run.bats
```

## Interpreting Output

- `ok N - test name` = pass
- `not ok N - test name` = fail, followed by assertion details
- `# (from function ... source ... line N)` = exact location of failed assertion

**Integration tests always show green** in CI even when failing — they run with `|| true` in `.github/workflows/test.yml`. After `make test-integration`, read the output explicitly.

## Debugging a Failing Test

### 1. Find the tmpdir

Add `echo "TMPDIR: $TEST_TMPDIR" >&3` inside the failing `@test` body (bats redirects `>&3` to the terminal). Run the test in verbose mode.

### 2. Inspect mock logs

```bash
cat $TEST_TMPDIR/.ultrainit/mock_claude.log  # all mock invocations
```

Look for `CALL:` lines. If the mock was never called when it should have been, check if `setup_mock_claude` was called in `setup()`.

### 3. Check dispatch matching

Dispatch mode matches agent name from the `--json-schema` argument basename (case-insensitive substring). If `docs` matches before `docs-scanner`, rename the dispatch file: longer/more-specific names first alphabetically.

### 4. Verify envelope wrapping

Passing raw fixture JSON where an envelope is expected causes `run_agent` to extract `.structured_output` as `null`, writing `"null"` to the findings file silently:

```bash
# Wrong — raw JSON, no envelope
cat tests/fixtures/findings/identity.json > "$MOCK_CLAUDE_RESPONSE"

# Correct — envelope-wrapped
make_claude_envelope "$(cat tests/fixtures/findings/identity.json)" "0.15" > "$MOCK_CLAUDE_RESPONSE"
```

## Building the Test Image

Only needed when `Dockerfile.test` changes:

```bash
make test-image   # builds locally
```

The CI image is pulled from `ghcr.io/joelbarmettleruzh/ultrainit-test:latest`. If the image doesn't exist yet on a fresh fork, run `make test-image` first.
