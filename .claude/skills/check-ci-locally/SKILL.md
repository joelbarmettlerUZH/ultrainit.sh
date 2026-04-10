---
name: check-ci-locally
description: "
  Run the same checks that CI runs locally before pushing: bash -n on all
  .sh files and jq empty on all schemas/*.json. Use before push to main,
  push to remote, verify CI will pass, or pre-flight check. Do NOT use as
  a substitute for make test-all — this covers syntax only, not functional
  correctness.
---

## Before You Start

- `.github/workflows/test.yml` — the `syntax` job (runs before `test` job)
- `Makefile` — `check` target (mirrors what CI does)

## Steps

### Run the check

```bash
make check
```

This runs:
1. `bash -n` on all `.sh` files (excluding `./test-repos/*`)
2. `jq empty` on all `schemas/*.json`

Equivalent manual commands:

```bash
# Shell syntax check
find . -name '*.sh' -not -path './test-repos/*' | xargs bash -n

# Schema JSON validity
for f in schemas/*.json; do
    jq empty "$f" && echo "OK: $f" || echo "FAIL: $f"
done
```

### Interpret failures

**bash -n failure**:
```
./lib/agent.sh: line 42: unexpected end of file
```
Means a syntax error at line 42 of `lib/agent.sh`. `bash -n` checks syntax only — it does not execute the script, so functions and variables are not evaluated.

**jq empty failure**:
```
jq: error: schemas/identity.json: Invalid numeric literal
```
Means `schemas/identity.json` is not valid JSON. Use `python3 -m json.tool schemas/identity.json` for a more informative error with line numbers.

### Additional check: bundle.sh delimiter conflicts

If you changed any file in `lib/`, `prompts/`, `scripts/`, or added new files:

```bash
grep '__EOF_LIB_' lib/*.sh scripts/*.sh prompts/*.md 2>/dev/null
```

Any match means a file contains the exact heredoc delimiter used by `bundle.sh`, which will cause the bundle to self-truncate silently.

## Verify

```bash
make check
echo "Exit code: $?"
```

Exit 0 = CI syntax job will pass. Then run `make test-all` for the full picture.
