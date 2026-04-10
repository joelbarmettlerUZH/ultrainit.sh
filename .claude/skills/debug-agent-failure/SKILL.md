---
name: debug-agent-failure
description: "
  Triage a failed ultrainit agent run by reading stderr logs, checking
  findings files, and inspecting budget spend. Use when an agent shows
  failed (exit N) in terminal output, when findings files are missing after
  a run, when the pipeline aborts with a phase failure, or when budget
  exhausted appears. Do NOT use for synthesis failures — those have retry
  logic in lib/synthesize.sh and their own logs.
---

## Before You Start

- `lib/agent.sh` lines 85-130 — error handling, budget enforcement, stderr capture
- `.ultrainit/state.json` — which phases completed (readable with `jq . .ultrainit/state.json`)
- `.ultrainit/logs/` — one `.stderr` file per agent
- `.ultrainit/costs/` — one `.cost` file per agent, format: `phase|agent|cost_usd`
- `.ultrainit/findings/` — structured JSON output from each agent

## Diagnosis Steps

### 1. Identify the failed agent

From terminal output, note the agent name (e.g., `patterns`, `git-forensics`). The error message format is:
```
[ERROR] Agent <name> failed (exit <N>). See .ultrainit/logs/<name>.stderr
```

### 2. Read the stderr log

```bash
cat .ultrainit/logs/<name>.stderr
```

Common error subtypes and what they mean:

| Error | Cause | Fix |
|-------|-------|-----|
| `error_max_budget_usd` | Per-agent budget exhausted | Increase `--budget` or delete `.ultrainit/costs/*.cost` files to reset |
| `error_max_structured_output_retries` | Schema validation loop — agent couldn't produce conforming JSON | Check schema for overly strict enums or missing `additionalProperties: false` |
| `rate_limit_exceeded` | API rate limit hit | Wait and rerun (findings exist for completed agents — only failed ones retry) |
| `authentication_error` | Claude auth expired | Run `claude auth status` and re-authenticate |
| `context_length_exceeded` | Prompt too long for model | Check prompt size; use `--skip-research` to reduce context |

### 3. Check the findings file

```bash
# Does it exist?
ls -la .ultrainit/findings/<name>.json

# Is it valid JSON?
jq empty .ultrainit/findings/<name>.json && echo "valid" || echo "INVALID"

# Check for null content (empty structured output)
jq -r 'if . == null then "NULL OUTPUT" else "ok" end' .ultrainit/findings/<name>.json
```

If the file contains `null`, the agent exited 0 but `claude -p` returned an empty `structured_output`. This usually means the schema had no matching fields.

### 4. Check budget spend

```bash
# Show individual agent costs
for f in .ultrainit/costs/*.cost; do
    echo "$f:"; cat "$f"
done

# Sum total spend
awk -F'|' '{ sum += $3 } END { print sum }' .ultrainit/costs/*.cost
```

Budget check is **optimistic under parallelism** — all agents in a batch check before any write costs. Spend can exceed `TOTAL_BUDGET` by up to N × per-agent share. To reset an individual agent's budget accounting: `rm .ultrainit/costs/<name>.cost`.

### 5. Check phase state

```bash
jq . .ultrainit/state.json
```

Phases marked complete are skipped on rerun. If you want to re-run just one agent without re-running the whole phase: `rm .ultrainit/findings/<name>.json` then rerun.

### 6. Re-run with verbose output

```bash
./ultrainit.sh --force --verbose /path/to/project
```

`--verbose` pipes agent stderr to the terminal in real time. `--force` re-runs all agents even if findings exist.

To re-run only the failed agents (preserving completed ones), do NOT use `--force`. Just rerun without flags — `run_agent` skips existing findings automatically.

### 7. Check authentication

```bash
claude auth status
```

If `loggedIn: false`, re-authenticate. `lib/config.sh` calls this at startup and aborts if not authenticated.

## Common Mistakes

1. **Using `--force` when you only want to retry failures** — `--force` reruns every agent, which costs money. Without `--force`, only agents with missing findings files are retried.

2. **Budget retries are cumulative** — if synthesis retried 3 times and failed, all 3 attempts' costs are in `.cost` files. Raise `--budget` or delete specific `.cost` files before rerunning.

3. **`structure-scout` failure degrades deep-dive quality silently** — if `structure-scout` fails, `run_fallback_module_analyzers()` uses a crude directory scan. Check `logs/structure-scout.stderr` before trusting module findings.

4. **Findings with `null` content pass silently** — `run_agent` in `lib/agent.sh` validates with `jq empty`, but `null` is valid JSON. Use `jq -e . file` (exits 1 on null) to catch empty structured output.
