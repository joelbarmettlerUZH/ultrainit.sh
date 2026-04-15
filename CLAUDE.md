# ultrainit

A shell-native tool that orchestrates multiple `claude -p` subagents to deeply analyze any codebase and generate a complete Claude Code configuration — CLAUDE.md, skills, hooks, subagents, commands, and MCP servers.

## Quick Reference

| Task | Command |
|------|---------|
| Build bundled release artifact | `bash bundle.sh > dist/ultrainit.sh && chmod +x dist/ultrainit.sh` |
| Build Docker test image | `make test-image` |
| Syntax-check all `.sh` files | `make check` |
| Validate all `schemas/*.json` | `for f in schemas/*.json; do jq empty "$f"; done` |
| Run unit tests | `make test-unit` |
| Run script validator tests | `make test-scripts` |
| Run edge-case tests | `make test-edge` |
| Run integration tests | `make test-integration` |
| Run full test suite | `make test-all` |
| Run smoke test (real Claude, costs money) | `bash tests/smoke/run-smoke.sh --source` |
| Run ultrainit against a project | `./ultrainit.sh /path/to/project` |
| Run ultrainit headless | `./ultrainit.sh --non-interactive /path/to/project` |

All `make test-*` targets require Docker and the pre-built `ghcr.io/joelbarmettleruzh/ultrainit-test:latest` image. No real Claude API calls are made in any `make test-*` target.

## Architecture

### Overview

ultrainit is a Bash pipeline orchestrator. It runs five sequential phases: **Gather** (8+ parallel `claude -p` agents analyze the target codebase from different angles), **Ask** (5 interactive developer questions), **Research** (2 web-enabled agents for domain knowledge and MCP discovery), **Synthesize** (2 large-context `claude -p` calls generate all artifacts), and **Validate & Write** (structural quality checks + atomic file writes).

All intermediate state lives in `.ultrainit/` inside the target project. Every phase checks `state.json` for prior completion and skips if already done, making the pipeline fully resumable. Individual agents also skip if their findings file already exists, so partial failures can be retried by re-running. The `--force` flag bypasses both checks.

The tool is designed for quality over speed. A full run intentionally takes 60+ minutes and may cost $30–100 in API budget. This is acceptable; use `claude init` if you need something fast.

### Directory Structure

```
ultrainit/
├── ultrainit.sh                   # Main entry point: CLI parsing, phase orchestration
├── lib/
│   ├── utils.sh                   # Logging, state.json, JSON helpers, cost aggregation, spinner
│   ├── config.sh                  # Dependency checks, work-dir setup, budget arithmetic
│   ├── agent.sh                   # run_agent(), run_agents_parallel(), diagnose_phase_failure()
│   ├── gather.sh                  # Phase 1: 8 parallel gather agents + deep-dive agents
│   ├── ask.sh                     # Phase 2: interactive developer interview
│   ├── research.sh                # Phase 3: domain research + MCP discovery agents
│   ├── synthesize.sh              # Phase 4: two-pass synthesis with retry logic
│   ├── validate.sh                # Phase 5a: artifact quality checks + revision agent
│   └── merge.sh                   # Phase 5b: backup + write artifacts to target project
├── prompts/                       # System prompt markdown files for each agent
├── schemas/                       # JSON schemas for structured claude -p output
├── scripts/
│   ├── validate-skill.sh          # Standalone skill quality validator (Phase 5 + tests)
│   └── validate-subagent.sh       # Standalone subagent quality validator
├── tests/
│   ├── helpers/                   # test_helper.bash + mock_claude.bash
│   ├── fixtures/                  # Realistic JSON + markdown fixtures for all agent types
│   ├── unit/                      # Per-function tests (11 .bats files)
│   ├── integration/               # Phase-level tests (gather, synthesize, resume)
│   ├── scripts/                   # Tests for validate-skill.sh, validate-subagent.sh
│   ├── edge/                      # Budget exhaustion, corrupt state, special chars
│   └── smoke/                     # End-to-end against real Claude (costs money)
├── bundle.sh                      # Bundles all source into a single self-extracting script
├── Dockerfile.test                # Isolated bats-core test image
├── Makefile                       # Build and test targets
└── .github/workflows/             # test.yml, docker-test-image.yml, release.yml
```

### Core Abstraction: The Agent Runner

Every interaction with `claude -p` routes through a single function in `lib/agent.sh`: `run_agent <name> <prompt> <schema_file> <allowed_tools> [model] [phase]`. No caller invokes `claude -p` directly.

`run_agent` handles, in order:
1. **Resumability**: if `$WORK_DIR/findings/${name}.json` exists and `FORCE != true`, returns 0 immediately
2. **Budget enforcement**: checks cumulative spend across all `.cost` files via `check_budget()` before spending anything
3. **Prompt routing**: prompts prefixed with `@` are read from a file (required for prompts containing apostrophes, parens, backticks); prompts >100KB are piped via stdin to avoid ARG_MAX limits
4. **Structured output**: passes `--json-schema`, `--output-format json`, `--max-budget-usd`, and `--allowedTools` to every call
5. **Cost recording**: writes `phase|agent|cost` to `$WORK_DIR/costs/${name}.cost` — one file per agent to avoid race conditions during parallel writes
6. **Response validation**: extracts `.structured_output // .result // .` from the JSON envelope and validates with `jq empty` before writing to findings

`run_agents_parallel()` spawns each agent as a child bash process via temp scripts. Each temp script hard-bakes all parent variable values as `export VAR="$VAR"` literals before re-sourcing lib files. This prevents re-sourcing `config.sh` from overwriting already-computed budget values. See `lib/agent.sh:191-211`.

### Phase 4: Two-Pass Synthesis

Synthesis is split into two sequential passes, each calling a 1M-context model (default `sonnet[1m]`):

- **Pass 1 (synthesizer-docs.md)**: receives all Phase 1+3 findings, produces all CLAUDE.md files (root + subdirectory)
- **Pass 2 (synthesizer-tooling.md)**: receives the generated CLAUDE.md from Pass 1 as source of truth, plus filtered tooling-relevant findings; produces skills, hooks, subagents, MCP configs, and settings.json wiring

Pass 2 explicitly uses Pass 1's output as its architecture document. This prevents the failure mode where a single-pass approach produces skills inconsistent with the generated CLAUDE.md. `lib/synthesize.sh:build_tooling_context()` intentionally excludes key_files details, domain terms, and skill_opportunities from module analyses to reduce Pass 2 token count.

Synthesis retries up to `$ULTRAINIT_MAX_RETRIES` (default 3, set to 1 in tests) with 10-second sleeps on transient API errors. If all retries fail, `diagnose_phase_failure()` calls a Haiku agent to interpret stderr logs and suggest fixes.

### Budget Model

Total budget (default $100) is divided across phases: 50% gather, 10% research, 30% synthesis, 10% validation. Within each phase, budget is split equally among planned agents. Each `claude -p` call receives `--max-budget-usd` set to its per-agent share.

Budget tracking uses `bc` for floating-point arithmetic. `check_budget()` aggregates by globbing `$WORK_DIR/costs/*.cost` and summing the third pipe-separated field with `awk`. **Known limitation**: budget checks are optimistic under parallelism — all N agents in a parallel batch check the budget before any of them write their cost file, so spend can exceed the budget by up to N × per-agent share. This is documented and accepted.

### Merge Strategy

`lib/merge.sh` writes artifacts with these rules:
- `CLAUDE.md`: always overwrite (previous version backed up to `$WORK_DIR/backups/`)
- `.claude/settings.json`: deep-merge via `jq -s '.[0] * .[1]'` — hooks are added, existing settings preserved
- `.claude/skills/*`, `.claude/hooks/*`, `.claude/agents/*`: **never overwrite existing files**; skip silently if present

Use `--overwrite` to remove existing config before analysis (backs up first). Without it, ultrainit will not update stale skills even if synthesis improved.

## Patterns and Conventions

### Phase Entry Functions

Each `lib/` file exposes exactly one top-level entry function named after its file: `gather_evidence()`, `ask_developer()`, `run_research()`, `synthesize()`, `validate_artifacts()`, `write_artifacts()`. Every phase entry function begins with:

```bash
if is_phase_complete "phase_name" && [[ "$FORCE" != "true" ]]; then
    return 0
fi
```

See `lib/gather.sh:7`, `lib/synthesize.sh:16`, `lib/ask.sh:28`.

### Global Variables as Configuration

All runtime configuration is in exported SCREAMING_SNAKE_CASE globals set in `lib/config.sh` with `${VAR:-default}` syntax. CLI argument parsing in `ultrainit.sh:80-98` overrides defaults. Environment variables (`ULTRAINIT_MODEL`, `ULTRAINIT_BUDGET`) form a secondary override layer. Local variables within functions are snake_case.

Critical globals: `WORK_DIR`, `TARGET_DIR`, `SCRIPT_DIR`, `FORCE`, `NON_INTERACTIVE`, `VERBOSE`, `DRY_RUN`, `AGENT_MODEL`, `SYNTH_MODEL`, `TOTAL_BUDGET`, `GATHER_BUDGET`, `AGENT_BUDGET`, `AGENT_PHASE`.

### State Management

Phase completion is tracked in `$WORK_DIR/state.json` as `{ "phase_name": "<ISO timestamp>" }`. `mark_phase_complete()` (`lib/utils.sh:26-39`) writes atomically: re-initializes to `{}` if the file is corrupt, validates with `jq empty` before overwriting. Never write to `state.json` directly; always use `mark_phase_complete()` and `is_phase_complete()`.

### Error Tolerance Tiers

Three failure tiers in `lib/gather.sh`:
1. **Critical failure**: if `identity` or `structure-scout` agent is missing, or ≥3 of 8 core agents failed → abort with `diagnose_phase_failure()`
2. **Non-critical failure**: 1–2 individual agent failures → log warning, continue with partial data
3. **Synthesis failure**: retry up to `ULTRAINIT_MAX_RETRIES` times → if exhausted, abort with diagnosis

Validation failures in Phase 5 trigger a targeted revision agent. Only the failing artifacts (skills, CLAUDE.md generic phrases) are revised; passing ones are preserved.

### Prompt Special Characters

Prompts containing shell-special characters (apostrophes, parentheses, backticks, dollar signs) **must** be written to a file and passed as `@/absolute/path` to `run_agent()`. The `@` prefix triggers file-read behavior in `run_agent`. This is mandatory for domain-research, mcp-discovery, and module-analyzer prompts. Inline string prompts with these characters break the parallel temp-script expansion. See PR #2 and `tests/edge/special_characters.bats`.

### Naming Conventions

- **Shell functions**: `snake_case` with semantic prefixes: `log_*`, `run_*`, `is_*`, `mark_*`, `json_*`, `validate_*`, `build_*`, `write_*`, `merge_*`, `check_*`, `compute_*`, `estimate_*`, `setup_*`, `get_*`, `diagnose_*`, `backup_*`. No CamelCase anywhere.
- **Agent names / schema files / prompt files**: `kebab-case` (e.g., `git-forensics.json`, `docs-scanner.md`, `structure-scout.json`). The skill validator enforces kebab-case on skill names.
- **Exported globals**: `SCREAMING_SNAKE_CASE`
- **Commit messages**: Conventional Commits format (`feat:`, `fix:`, `test:`, etc.). See recent history.
- **Branches**: `feat/<description-in-kebab-case>`, `fix/<description-in-kebab-case>`

### JSON Safety

Every `jq` expression on optional fields uses `// empty`, `// []`, or `// {}` fallbacks. Guard all `jq` reads with `2>/dev/null || echo ""`. Never use raw `jq .field` on agent findings without a null guard — agents may return partial or missing fields. See `lib/utils.sh:57`, `lib/synthesize.sh:125`, `lib/merge.sh:195`.

### Cross-Platform Constraints

- Never use `sed -i 'expr' file` — GNU and BSD `sed -i` are mutually incompatible. Use `tmp=$(mktemp); sed 'expr' <"$file" >"$tmp" && mv "$tmp" "$file"` instead.
- Never use `gensub()` in awk — it is gawk-only and silently broken on macOS stock awk. Use `gsub()` (POSIX) for simple replacements.
- Never use `wait -n` or `wait -p` — they require bash 4.3+/5.1+. macOS ships bash 3.2. Use the array-of-PIDs pattern in `run_agents_parallel()`.
- Never use `declare -A` for associative arrays or `mapfile`/`readarray` — bash 3.2 incompatible.
- `bc` can produce `.20` instead of `0.20` for values < 1. Never compare budget strings expecting a leading zero.

## Development Workflow

### Building and Running

```bash
# Run from source against a target project
./ultrainit.sh /path/to/your/project

# Force rerun of all agents
./ultrainit.sh --force /path/to/your/project

# Fresh generation (removes old config, backs up first)
./ultrainit.sh --overwrite /path/to/your/project

# Headless / CI
./ultrainit.sh --non-interactive --skip-research /path/to/your/project

# Build the distributable single-file bundle
bash bundle.sh > dist/ultrainit.sh && chmod +x dist/ultrainit.sh
```

The bundle self-extracts to a temp directory at runtime. `bundle.sh` embeds all `lib/`, `prompts/`, `schemas/`, and `scripts/` as heredoc blocks with `__EOF_LIB_<name>__` delimiters. The delimiter collision risk is low but real: if any embedded file contains a line that exactly matches the delimiter, the heredoc terminates early. Before releasing, run `grep '__EOF_LIB_' lib/*.sh` to check for conflicts.

### Releasing

Releases are fully automated by `.github/workflows/release.yml`. Every merge to `main` cuts a new GitHub Release with a fresh `vX.Y.Z` tag and an updated `dist/ultrainit.sh` asset. Do **not** create or push tags manually — the workflow owns tagging.

Bump type is chosen per PR via label (set before merging):

| Label | Effect on merge |
|---|---|
| (none) or `release:patch` | Patch bump (e.g. `v1.5.2` → `v1.5.3`) |
| `release:minor` | Minor bump (e.g. `v1.5.2` → `v1.6.0`) |
| `release:major` | Major bump (e.g. `v1.5.2` → `v2.0.0`) |
| `release:skip` | No release published |

For retroactive minor/major bumps (the merged PR was patch-labeled but deserves a minor/major), use the **Run workflow** button on the Actions → Release page and pick the desired bump. This creates an additional tag on top of the already-published patch release — both releases will coexist, with the higher semver becoming "latest."

### Testing

All tests run inside Docker using the pre-built image. No real Claude calls are made.

```bash
make test-image          # Build the test image locally (one-time, or after Dockerfile.test change)
make test-unit           # Tests for lib/ functions
make test-scripts        # Tests for scripts/validate-skill.sh and validate-subagent.sh
make test-edge           # Budget, corrupt state, special chars, numeric edge cases
make test-integration    # Phase-level pipeline tests (gather, synthesize, resume)
make test-all            # All of the above
```

**Smoke tests** make real API calls and cost real money:
```bash
bash tests/smoke/run-smoke.sh --source   # Run from source, ~$2 with haiku
```

Never run smoke tests in CI without explicit intent. They are excluded from `make test-all`.

### Adding a New Gather Agent

1. Write a system prompt in `prompts/<agent-name>.md`
2. Write a JSON schema in `schemas/<agent-name>.json` (must use `additionalProperties: false` at every level)
3. Add the `run_agent` call to `lib/gather.sh` in the Stage 1 parallel block
4. Create a realistic fixture in `tests/fixtures/findings/<agent-name>.json`
5. Add the agent to the critical-failure check in `gather.sh` if it is structurally required
6. Add unit test coverage in a new or existing `tests/unit/*.bats` file

When updating an existing schema, add new fields as **optional** (not in `required`). Update the corresponding fixture in `tests/fixtures/findings/` and run `make test-all` to catch breakage.

## Things to Know

**Re-sourcing `config.sh` in child processes overwrites computed budget values.** `run_agents_parallel()` guards against this by hard-baking all parent variable values as literals in each temp script before re-sourcing. Never add logic to `config.sh` that overwrites a variable if it is already exported.

**Budget is cumulative across retries.** If a synthesis pass fails and retries 3 times, the cost of all failed attempts counts against `TOTAL_BUDGET`. Use `--budget` to set a higher limit when debugging, or delete specific `.cost` files manually to reset individual agent budgets.

**`structure-scout` failure degrades deep-dive quality silently.** If this agent fails, `run_fallback_module_analyzers()` uses a crude top-level directory scan. The fallback misses nested modules. Always check `logs/structure-scout.stderr` before trusting deep-dive results.

**Existing skills/hooks/agents are silently skipped on re-run.** `write_artifacts()` skips any file that already exists in `.claude/`. This is intentional — ultrainit never overwrites user edits. Use `--overwrite` to regenerate from scratch (backs up first).

**Synthesis context can exceed model limits.** `estimate_tokens()` uses a rough bytes/4 heuristic. If synthesis fails with a context-length error, reduce scope with `--skip-research` or selectively delete low-priority module findings from `.ultrainit/findings/` before rerunning.

**Angle brackets in LLM-generated descriptions break YAML frontmatter.** `postprocess_descriptions()` in `lib/synthesize.sh` replaces `<` and `>` with quotes after extraction. If a skill description still contains raw angle brackets after synthesis, `validate-skill.sh` will catch it and the revision agent will fix it.

**`ask.sh` reads from `/dev/tty`, not stdin.** In containers or CI where `/dev/tty` is unavailable, it falls back to `NON_INTERACTIVE` mode. Always pass `--non-interactive` for CI/Docker environments rather than relying on auto-detection.

**Integration tests silently pass CI even when they fail.** `tests/integration/` runs with `|| true` and `if: always()` in `.github/workflows/test.yml`. A green CI check does NOT guarantee integration tests passed. Check the raw step output explicitly.

**The prohibition detection regex requires a trailing space.** `validate_claude_md` searches for `(never |don.t |do not )` with trailing spaces. `Never` or `Don't` at end-of-line is not matched. This is a documented bug in `tests/edge/validation_regex.bats`. Fix requires updating both the regex and the test.

**`jq -r '.missing_key'` returns the string `"null"`, not empty.** `wc -l` counts it as 1 line. Validation code uses `// empty` to get empty string instead. Always use `jq -e` and check exit code, or use `// empty`, when checking for missing keys.

## Security-Critical Areas

| File/Pattern | Risk | Safe Alternative |
|---|---|---|
| `lib/config.sh` | Auth check, dependency verification, budget arithmetic — bugs can bypass auth or blow budget | Add test in `tests/unit/config_budget.bats`, run `make test-unit` before merging |
| `lib/agent.sh` | Budget enforcement, cost tracking, API response validation, agent spawning | Add test in `tests/unit/agent_run.bats` or `agent_helpers.bats` before merging |
| `lib/validate.sh` | Quality gates on all generated artifacts — weakening degrades output silently | Add regression test in `tests/unit/validate_claude_md.bats` or `validate_hook.bats` |
| `scripts/validate-skill.sh` | Enforces skill quality rules used in Phase 5 | Update `tests/scripts/validate_skill.bats` alongside any rule changes |
| `schemas/*.json` | Schema changes break structured output parsing for dependent agents — silently produces empty findings | Add fields as optional; update `tests/fixtures/findings/` fixture; run `make test-all` |
| `.github/workflows/*.yml` | CI/CD pipeline — incorrect edits break releases, test runs, or Docker image publishing | Test in a feature branch first |
| `bundle.sh` | Release bundling — errors ship a broken release artifact on every merge to main | Run `make test-all` and `bash -n dist/ultrainit.sh` locally before merging; use `release:skip` label to block a release |
| `Dockerfile.test` | Changes affect all CI test runs and the published GHCR image | Build locally with `make test-image` before committing |
| `tests/fixtures/**/*.json` | Test correctness depends on fixture accuracy — hand-crafted wrong values cause tests to pass against a fantasy | Capture real `claude -p --output-format json` output to update; never hand-craft values |
| `.gitignore` | Removing `.ultrainit/` would commit intermediate findings including sensitive developer answers | Append with `echo 'pattern' >> .gitignore`; never rewrite |

## Domain Terminology

| Term | Meaning in This Codebase |
|---|---|
| **agent** | A single `claude -p` subprocess invocation, given a focused prompt, JSON schema, and tool allowlist |
| **findings** | The structured JSON output an agent writes to `.ultrainit/findings/{name}.json` |
| **phase** | One of five pipeline stages: Gather, Ask, Research, Synthesize, Validate/Write |
| **work dir** | `.ultrainit/` inside the target project — all intermediate state |
| **synthesis pass** | One of two large-context `claude -p` calls (Pass 1: docs, Pass 2: tooling) |
| **envelope** | The `{is_error, total_cost_usd, structured_output}` JSON wrapper that `claude -p --output-format json` returns |
| **mock dispatch** | Test mode where the mock `claude` binary serves per-agent response files keyed by agent name |
| **critical agent** | An agent whose failure aborts the pipeline (`identity`, `structure-scout`) |
| **revision agent** | A Phase 5 `claude -p` call that fixes failing artifacts without re-synthesizing from scratch |
| **deep-dive agent** | A per-directory `module-analyzer` agent spawned based on `structure-scout` output |
| **bundled** | The single self-extracting `dist/ultrainit.sh` produced by `bundle.sh` for curl-pipe-bash distribution |
| **safe-name** | A directory path converted to a slug for use as a filename: `sed` strips `/`, `.`, spaces, parens; falls back to `root` |

