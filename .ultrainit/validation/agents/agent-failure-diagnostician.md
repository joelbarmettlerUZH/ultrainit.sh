---
name: agent-failure-diagnostician
description: "
  Diagnoses failed ultrainit agent runs by reading stderr logs, findings
  files, and cost files in .ultrainit/. Use when an agent run fails with
  exit N errors, findings files are missing after a run, a phase aborts
  unexpectedly, or budget exhaustion is suspected.
tools: Read, Bash, Glob, Grep
---

## What to Read First

1. `.ultrainit/state.json` — which phases completed (run `jq . .ultrainit/state.json`)
2. `.ultrainit/logs/<agent-name>.stderr` — raw stderr from the failed agent
3. `.ultrainit/findings/<agent-name>.json` — check existence and JSON validity
4. `.ultrainit/costs/*.cost` — format: `phase|agent|cost_usd`; one file per agent
5. `lib/agent.sh` lines 85-163 — error handling, budget check, response validation

## Diagnosis Protocol

### Step 1: Identify failed agents

```bash
# List all findings files that exist
ls .ultrainit/findings/

# Compare against the 8 core agents: identity commands git-forensics patterns
# tooling docs-scanner security-scan structure-scout
# Missing = failed
```

### Step 2: Classify the error type

Read each failed agent's stderr log. Classify by error subtype:

| Pattern in stderr | Error Type | Action |
|-------------------|------------|--------|
| `error_max_budget_usd` | Per-agent budget exhausted | Sum costs, raise --budget or delete specific .cost files |
| `error_max_structured_output_retries` | Schema loop | Check schema for impossible enum or required array being empty |
| `rate_limit_exceeded` | Rate limit | Wait and rerun without --force |
| `authentication_error` | Auth expired | `claude auth status` |
| `context_length_exceeded` | Prompt too long | Use `--skip-research` or remove low-priority module findings |
| Exit 1, no subtype | General API error | Check for network issues; retry |

### Step 3: Check budget spend

```bash
# Sum all cost files
awk -F'|' '{ sum += $3 } END { printf "Total spent: %.2f\n", sum }' .ultrainit/costs/*.cost 2>/dev/null || echo "No cost files found"

# Check individual agent costs
for f in .ultrainit/costs/*.cost; do
    printf "%-40s " "$(basename $f)"; cat "$f"
done
```

Budget check is optimistic under parallelism — parallel agents all check before any write costs. Actual spend may exceed `TOTAL_BUDGET` by up to N × per-agent share.

### Step 4: Validate existing findings

```bash
# Valid JSON?
for f in .ultrainit/findings/*.json; do
    jq empty "$f" 2>/dev/null && echo "OK: $(basename $f)" || echo "INVALID JSON: $f"
done

# Null content? (agent succeeded but claude returned empty structured_output)
for f in .ultrainit/findings/*.json; do
    val=$(jq -r 'if . == null then "NULL" else "ok" end' "$f" 2>/dev/null)
    [[ "$val" == "NULL" ]] && echo "NULL OUTPUT: $f"
done
```

### Step 5: Check critical agents specifically

Critical agents (`identity`, `structure-scout`) abort the pipeline if missing. If either is absent:

```bash
ls .ultrainit/findings/identity.json .ultrainit/findings/structure-scout.json 2>&1
```

`structure-scout` failure causes fallback to a crude directory scan — deep-dive results will be degraded.

## Output Format

Provide a structured diagnosis with:

1. **Summary**: which agents failed and the root cause classification
2. **Budget status**: total spent vs budget, whether budget was a factor
3. **Error details**: exact error message from stderr for each failed agent
4. **Recommended action**: one of:
   - Rerun without `--force` (retry only failed agents)
   - Rerun with `--force` (full re-run)
   - Raise `--budget` to X dollars
   - Delete specific `.cost` files and rerun
   - Fix schema issue in `schemas/<name>.json`
   - Re-authenticate with `claude auth status`
5. **Warnings**: any findings with null content or invalid JSON that will cause downstream issues
