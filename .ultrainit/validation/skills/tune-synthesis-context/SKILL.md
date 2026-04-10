---
name: tune-synthesis-context
description: "
  Reduce or expand what build_docs_context and build_tooling_context include
  when synthesis hits context-length errors or produces low-quality output.
  Use when synthesis failed with context too large, token limit exceeded,
  synthesis is missing expected artifacts, or output quality is degraded.
  Do NOT use for individual gather agent failures — use debug-agent-failure
  for those.
---

## Before You Start

- `lib/synthesize.sh` lines 87-250 — `build_docs_context()` and `build_tooling_context()`
- `.ultrainit/logs/synthesis-docs.stderr` and `.ultrainit/logs/synthesis-tooling.stderr` — raw errors
- `.ultrainit/findings/` — all findings files that get included in context

## Diagnosis

### 1. Check the synthesis log for the error type

```bash
tail -50 .ultrainit/logs/synthesis-docs.stderr
tail -50 .ultrainit/logs/synthesis-tooling.stderr
```

- `context_length_exceeded` → context is too large, reduce it
- Missing artifacts in output → context may be too small (missing findings) or model confused by too much noise

### 2. Estimate context size

`estimate_tokens()` in `lib/synthesize.sh` uses `bytes/4` heuristic. Check actual file sizes:

```bash
# Largest findings files (Pass 1 context)
du -sh .ultrainit/findings/*.json | sort -rh | head -10

# Module analyses are often the largest
du -sh .ultrainit/findings/module-*.json | sort -rh

# Check total bytes of what goes into Pass 1 context
cat .ultrainit/findings/*.json | wc -c
```

## Reducing Context

### Option A: Remove low-priority module analyses

Module analyses for unimportant directories inflate the context significantly. Remove individual low-value findings:

```bash
# List all module findings
ls .ultrainit/findings/module-*.json

# Remove one
rm .ultrainit/findings/module-<unimportant-dir>.json
```

Then re-run synthesis (the phase won't re-gather since gather is marked complete):

```bash
./ultrainit.sh --force /path/to/project
```

### Option B: Edit build_docs_context() to exclude fields

In `lib/synthesize.sh`, find `build_docs_context()` (lines 87-152). The function uses `jq` to extract specific fields. To reduce module analysis size, add field exclusions:

```bash
# Current: includes full module output
jq '. ' "$module_file"

# Reduced: exclude large arrays
jq 'del(.key_files, .domain_terms, .skill_opportunities)' "$module_file"
```

### Option C: Use `--skip-research` to exclude Phase 3 findings

```bash
./ultrainit.sh --skip-research /path/to/project
```

Domain research and MCP discovery findings can add significant tokens with low marginal value.

## Expanding Context (for missing artifacts)

If Pass 2 is producing incomplete output (missing skills or hooks), check what `build_tooling_context()` excludes. Pass 2 intentionally omits `key_files` details, `domain_terms`, and `skill_opportunities` from module analyses to reduce tokens. If these are needed, edit `lib/synthesize.sh` lines 159-250 to include them.

## Re-running Synthesis Only

Delete only synthesis outputs so the pipeline re-synthesizes without re-gathering:

```bash
rm .ultrainit/synthesis/output-docs.json
rm .ultrainit/synthesis/output-tooling.json
rm .ultrainit/synthesis/output.json

# Remove synthesis phase completion marker
jq 'del(.synthesize)' .ultrainit/state.json > /tmp/state.json && mv /tmp/state.json .ultrainit/state.json

# Rerun
./ultrainit.sh /path/to/project
```

## Verify

```bash
# Verify synthesis completed
jq '.synthesize' .ultrainit/state.json

# Check output has expected artifact types
jq 'keys' .ultrainit/synthesis/output.json
jq '.skills | length' .ultrainit/synthesis/output.json
jq '.hooks | length' .ultrainit/synthesis/output.json
```

## Common Mistakes

1. **Budget is cumulative across retries** — each synthesis retry costs money. After 3 retries, budget may be exhausted. Raise `--budget` or delete specific `.cost` files before tuning.

2. **Deleting output files is not enough** — you must also remove the phase completion marker from `state.json`, otherwise the pipeline skips synthesis even after deleting the output files.

3. **`estimate_tokens()` uses `bytes/4`** — dense JSON has more tokens per byte than prose. Actual token count for findings files may be 1.5-2x the estimate.
