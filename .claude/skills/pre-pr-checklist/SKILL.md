---
name: pre-pr-checklist
description: "
  Quality gates to run before opening a pull request for ultrainit. Use
  before open a PR, create a pull request, push this branch, mark as ready
  for review, or merge this. Covers syntax checks, test suite, fixture
  consistency, and commit message format. Do NOT use for release tagging
  — use release-ultrainit for that.
---

## Before You Start

- `CLAUDE.md` — project conventions (commit format, naming, cross-platform constraints)
- `.github/workflows/test.yml` — exactly what CI runs (syntax job + test job)
- `lib/validate.sh` — quality gates applied to generated artifacts
- `tests/fixtures/findings/` — fixture files that must stay in sync with schemas

## Checklist

### 1. Shell syntax check

```bash
make check
```

This runs `bash -n` on all `.sh` files (excluding `test-repos/`) and `jq empty` on all `schemas/*.json`. This is the same syntax job CI runs first. A failure here blocks the test job from running.

### 2. Full test suite

```bash
make test-all
```

Requires Docker. Runs unit, scripts, edge, and integration tests. If Docker is not available locally, the minimum is `make test-unit && make test-scripts && make test-edge`.

**Important**: Integration tests run with `|| true` in CI and show green even when failing. After `make test-integration`, inspect the output explicitly — don't trust the exit code alone.

### 3. Fixture consistency check

```bash
# Spot-check: do all 8 fixture files have valid JSON?
for f in tests/fixtures/findings/*.json; do
    jq empty "$f" && echo "OK: $f" || echo "FAIL: $f"
done

# Verify the merged synthesis fixture is up to date
jq -s '.[0] * .[1]' \
    tests/fixtures/synthesis/output-docs.json \
    tests/fixtures/synthesis/output-tooling.json \
    > /tmp/expected-output.json
diff tests/fixtures/synthesis/output.json /tmp/expected-output.json && echo "output.json in sync" || echo "DIVERGED — re-merge"
```

If `output.json` diverged, re-merge it:
```bash
jq -s '.[0] * .[1]' \
    tests/fixtures/synthesis/output-docs.json \
    tests/fixtures/synthesis/output-tooling.json \
    > tests/fixtures/synthesis/output.json
```

### 4. Commit message format

All commits must follow Conventional Commits:
- `feat:` — new feature
- `fix:` — bug fix
- `test:` — test additions/changes
- `docs:` — documentation only
- `refactor:` — code change without feature/fix
- `chore:` — maintenance (CI, deps, Makefile)

```bash
git log --oneline -10  # check recent messages follow the pattern
```

### 5. No untested code

The project rule from `CLAUDE.md` (developer answers): "Write untested code" is in the never-do list. For any new function in `lib/`, there must be a corresponding test in `tests/unit/`. For changes to `scripts/validate-skill.sh` or `scripts/validate-subagent.sh`, there must be updated tests in `tests/scripts/`.

### 6. Cross-platform safety check

Scan your changes for forbidden patterns:

```bash
# Portable sed check (GNU/BSD incompatible)
grep -n 'sed -i' lib/*.sh scripts/*.sh ultrainit.sh

# gawk-only gensub check
grep -n 'gensub(' lib/*.sh scripts/*.sh

# bash 4+ only features
grep -n 'declare -A\|mapfile\|readarray\|wait -n\|wait -p' lib/*.sh
```

All of these will silently break on macOS (bash 3.2, BSD sed, stock awk).

### 7. No angle brackets in generated skill/subagent descriptions

If you modified `prompts/synthesizer-tooling.md` or `lib/synthesize.sh`, verify `postprocess_descriptions()` is still stripping angle brackets:

```bash
grep -n 'postprocess_descriptions\|[<>]' lib/synthesize.sh | head -20
```

## Verify

```bash
make check && make test-all
```

Both must complete without error before opening the PR.
