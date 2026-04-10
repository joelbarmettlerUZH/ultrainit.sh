# lib/ — Core Orchestration Library

Nine shell modules implementing ultrainit's five-phase pipeline. Each file exposes one top-level entry function. All inter-module communication happens via exported globals and files in `$WORK_DIR`.

## Module Map

| File | Entry Function | Phase | Responsibility |
|---|---|---|---|
| `utils.sh` | (foundation) | all | Logging, `state.json`, JSON helpers, cost reporting, spinner |
| `config.sh` | `setup_work_dir()` | startup | Dependency checks, budget arithmetic, global defaults |
| `agent.sh` | `run_agent()` | all | Agent spawning, parallel execution, failure diagnosis |
| `gather.sh` | `gather_evidence()` | 1 | 8 parallel gather agents + deep-dive agents |
| `ask.sh` | `ask_developer()` | 2 | Interactive developer interview (5 questions) |
| `research.sh` | `run_research()` | 3 | Domain research + MCP discovery |
| `synthesize.sh` | `synthesize()` | 4 | Two-pass synthesis with retry logic |
| `validate.sh` | `validate_artifacts()` | 5a | Quality checks + revision agent |
| `merge.sh` | `write_artifacts()` | 5b | Backup + atomic file writes |

## Sourcing Order

All tests and `ultrainit.sh` source libs in this exact order:
```
utils.sh → config.sh → agent.sh → gather.sh → ask.sh → research.sh → synthesize.sh → validate.sh → merge.sh
```
`utils.sh` must come first (logging). `config.sh` requires utils logging. `agent.sh` requires both. Phase modules can reference any earlier module's functions. **Never source a single lib in isolation** — `synthesize.sh` sets `shopt -s nullglob` globally at source time, which affects glob patterns in other modules.

## Key Patterns

### Resumable Phase Guard

Every phase entry function begins with this exact pattern (`gather.sh:7`, `synthesize.sh:16`, `ask.sh:28`):

```bash
if is_phase_complete "phase_name" && [[ "$FORCE" != "true" ]]; then
    log_info "Phase already complete. Use --force to rerun."
    return 0
fi
```

`is_phase_complete` reads `$WORK_DIR/state.json`. `mark_phase_complete` writes to it atomically via a jq pipeline that re-initializes to `{}` on corruption. Never write to `state.json` directly.

### Agent Invocation

All `claude -p` calls route through `run_agent()` in `agent.sh`. The signature:

```bash
run_agent <name> <prompt> <schema_file> <allowed_tools> [model] [phase]
```

- `name`: used as the findings filename, log filename, cost filename, and mock dispatch key
- `prompt`: if prefixed with `@`, treated as a file path and read before calling claude
- `schema_file`: absolute path to `$SCRIPT_DIR/schemas/<name>.json`
- `allowed_tools`: comma-separated list passed directly to `--allowedTools`

Prompts with shell-special characters (apostrophes, parens, backticks, `$`) **must** use the `@file` form. Inline prompts with these characters break parallel temp-script expansion. Always use absolute paths with `@`.

### Parallel Execution

`run_agents_parallel()` receives agent invocation strings, writes each to a temp bash script, and spawns them with `bash script &`. Each temp script hard-bakes current variable values as `export VAR="$VAR"` literals **before** sourcing lib files. This prevents re-sourcing `config.sh` from overwriting already-computed `AGENT_BUDGET`. After all agents complete, failures are counted; temp dir is `rm -rf`'d.

### Budget Tracking

- Each agent writes `phase|agent|cost` to `$WORK_DIR/costs/${name}.cost` — one file per agent to avoid race conditions
- `check_budget()` aggregates with `awk -F'|' '{ sum += $3 }'` across all `.cost` files
- Budget arithmetic uses `bc` with `scale=2` — result may be `.20` not `0.20` for values < 1
- Budget check is optimistic under parallelism: all agents in a batch check before any write costs

### Failure Diagnosis

`diagnose_phase_failure()` collects the last 50 lines of each failed agent's stderr log and makes a low-cost Haiku call to interpret errors. Falls back to printing raw logs if Claude is unavailable. Always surfaces the `error_max_structured_output_retries` and `error_max_budget_usd` subtypes specifically.

### Synthesis Context Building

`build_docs_context()` assembles all Phase 1+3 findings for Pass 1. `build_tooling_context()` assembles a reduced context for Pass 2 — it intentionally excludes `key_files` details, `domain_terms`, and `skill_opportunities` from module analyses to reduce token count. Pass 2 receives the Pass 1 CLAUDE.md output as its primary architecture reference.

`estimate_tokens()` uses `bytes/4` heuristic. Actual token count for dense JSON may be higher. If synthesis fails with a context-length error, check `logs/synthesis-docs.stderr` and consider removing low-priority module findings from `.ultrainit/findings/`.

### Merge Safety

`merge_settings()` uses `jq -s '.[0] * .[1]'` (deep merge). `write_artifacts()` checks file existence before every skill/hook/subagent write and silently skips existing files. `backup_existing()` copies `CLAUDE.md` and `.claude/settings.json` to a timestamped dir under `$WORK_DIR/backups/` before any overwrites.

## Critical Gotchas

**`config.sh` recomputes budgets when re-sourced.** Parallel child scripts use literal-baked values precisely to avoid this. Never add logic to `config.sh` that overwrites a variable that may already be exported.

**`postprocess_descriptions()` strips angle brackets from skill descriptions.** This runs in `synthesize.sh` after extraction. If a skill still has angle brackets after synthesis, `validate-skill.sh` catches it and the revision agent fixes it. Never add angle brackets to prompt examples for skill descriptions.

**`ask.sh` reads from `/dev/tty`.** In Docker or CI, `/dev/tty` may not exist. Always pass `--non-interactive` in headless environments — don't rely on the auto-detection fallback.

**`sed -i` is not portable.** GNU and BSD `sed -i` have mutually incompatible syntax. Use `tmp=$(mktemp); sed 'expr' <"$file" >"$tmp" && mv "$tmp" "$file"` for portable in-place edits. See `utils.sh` for the portable `iso_date()` pattern.

**`gensub()` in awk is gawk-only.** macOS stock awk and mawk do not have it. Use `gsub()` (POSIX) for simple replacements. The Dockerfile installs gawk, but `check_dependencies()` only checks that `awk` exists, not that it is gawk.

**Budget retries consume additional budget.** If synthesis retries 3 times and fails, all attempt costs accumulate in `.cost` files. Use `--budget` to raise the limit when debugging retries, or delete specific `.cost` files to reset individual agent budgets.
