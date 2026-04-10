---
name: test-coverage-auditor
description: "
  Audits the bats test suite for coverage gaps: lib functions without tests,
  validate-subagent.sh rules with no test, and integration scenarios missing
  phase coverage. Use when find testing gaps, what is untested, add new
  functionality and need to know what tests to write, or check coverage
  before a PR.
tools: Read, Grep, Glob
---

## What to Read First

1. `lib/agent.sh` — functions: `run_agent`, `run_agents_parallel`, `diagnose_phase_failure`, `get_failed_agents`
2. `lib/config.sh` — functions: `check_budget`, `compute_budgets`, `setup_work_dir`
3. `lib/validate.sh` — functions: `validate_artifacts`, `validate_claude_md`, `run_revision_agent`
4. `tests/unit/` — list all existing .bats files
5. `scripts/validate-subagent.sh` lines 98-170 — all validation rules
6. `tests/scripts/validate_subagent.bats` — existing test coverage

## Coverage Audit Protocol

### 1. Map lib functions to unit tests

For each exported function in `lib/*.sh`:

```bash
# Find all function definitions
grep -n '^[a-z_]*()' lib/agent.sh lib/config.sh lib/validate.sh lib/merge.sh lib/synthesize.sh
```

For each function found, check if a corresponding `@test` exists:

```bash
grep -r 'run_agent\|run_agents_parallel\|check_budget\|validate_claude_md' tests/unit/
```

Report: functions with zero test coverage.

### 2. Audit validate-subagent.sh rule coverage

The `tests/scripts/validate_subagent.bats` file is known to have fewer tests than `validate_skill.bats`. Check specifically for untested rules:

Read `scripts/validate-subagent.sh` lines 98-170 and identify all `ERROR:` and `WARNING:` emit sites. For each, check if `tests/scripts/validate_subagent.bats` has an `assert_output --partial` test for that exact message.

Known gaps (from `tests/scripts/CLAUDE.md`):
- Model field validation
- `bypassPermissions` warning
- Tool-scope mismatch detection (Write/Edit in read-only agent)
- Overlap-with-Explore-agent warning

### 3. Audit integration test phase coverage

```bash
ls tests/integration/
```

Check for:
- Phase 2 (`ask_developer`) — does an integration test exist?
- Phase 3 (`run_research`) — is it covered?
- `write_artifacts` with `DRY_RUN=true` — is dry-run tested at integration level?
- `--overwrite` flag — tested?

### 4. Audit edge case gaps

Existing edge tests (from `tests/edge/`):
- `budget_exhaustion.bats`, `corrupt_state.bats`, `special_characters.bats`
- `numeric_edge_cases.bats`, `validation_regex.bats`, `cli_args.bats`

New edge cases to check for coverage:
- What happens when `structure-scout.json` exists but contains `null`?
- What happens when `state.json` exists but has invalid phase timestamps?
- What happens when `/dev/tty` is unavailable and `ask.sh` is not in non-interactive mode?

## Output Format

Provide three sections:

### Untested lib functions
- Function name, file, line number
- Suggested test file location
- Priority: HIGH (security-critical file) / MEDIUM / LOW

### Untested validator rules
- Rule description, file, line number
- Exact error/warning message to test with `assert_output --partial`

### Integration coverage gaps
- Phase or scenario name
- Existing partial coverage (if any)
- What specifically is missing

End with a prioritized list of the top 5 tests to add.
