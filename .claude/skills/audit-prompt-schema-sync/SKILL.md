---
name: audit-prompt-schema-sync
description: "
  Cross-validate that every output field described in prompts/*.md exists
  in the paired schemas/*.json file and vice versa. Use when prompt and
  schema diverged, agent returns unexpected fields, updating an agent output
  contract, adding a new field to an existing agent, or agent findings have
  null values. Do NOT use for synthesis prompts — their schemas store
  content as opaque strings.
---

## Before You Start

- `prompts/` — 14 markdown prompt files; output sections describe field names in prose
- `schemas/` — 14 JSON schema files; `properties` keys are the actual field names
- `schemas/CLAUDE.md` — notes on which schema issues are known (MCP shape mismatch, developer-answers has no schema)

## The Problem

Prompts describe output fields in prose ("For each finding, include: name, category, evidence_files"). Schemas enforce field types. When they drift, the agent either drops fields (prompt describes them but schema doesn't declare them) or returns unexpected fields (schema has them but prompt doesn't describe them). Neither case errors — both silently produce wrong findings.

## Steps

### 1. Extract prompt-described field names

For each gather prompt, find the output contract section. Look for patterns like "For each X, determine: field1, field2" or "Returns: { field1, field2 }":

```bash
# Manually read the output contract in each prompt
grep -n 'determine\|Returns\|output\|For each' prompts/patterns.md | head -20
cat prompts/patterns.md | grep -A20 'output'
```

### 2. Extract schema-declared field names

```bash
# Top-level properties
jq -r '.properties | keys[]' schemas/patterns.json

# Properties of array items
jq -r '.properties.patterns.items.properties | keys[]' schemas/patterns.json
```

### 3. Diff the two sets

For `patterns.md` → `schemas/patterns.json`:

```bash
# Fields in prompt but not schema: agent may emit them, schema drops them
# Fields in schema but not prompt: agent may not populate them, findings are empty

# Example manual diff for patterns agent:
prompt_fields="name type evidence_files description is_consistent"
schema_fields=$(jq -r '.properties.patterns.items.properties | keys[]' schemas/patterns.json)

for f in $prompt_fields; do
    echo "$schema_fields" | grep -q "^$f$" || echo "IN PROMPT, NOT SCHEMA: $f"
done
```

### 4. Fix the drift

Always fix both the prompt and schema in the same commit:

**Adding a missing field to schema**:
```json
// In schemas/patterns.json, add to items.properties:
"new_field": {
  "type": "string",
  "description": "..."
}
// Do NOT add to required[] — add as optional
```

**Removing a field from prompt that schema doesn't support**:
Edit the prose in `prompts/<name>.md` to remove the field description from the output section.

### 5. Update the fixture

After any schema change, update `tests/fixtures/findings/<agent-name>.json` to match. Run `make test-all` to catch breakage.

## Verify

```bash
bash -n lib/gather.sh
jq empty schemas/<agent-name>.json
make test-unit
```

## Common Mistakes

1. **`developer-answers.json` has no schema** — it is hand-assembled by `lib/ask.sh`. Any change to field names requires updating all `jq` expressions in `lib/synthesize.sh` that read from it.

2. **Two MCP schema shapes exist** — `schemas/mcp-recommendations.json` has `relevance` and a nested `configuration` object. `schemas/synthesis-tooling.json` flattens `command/args/env`. The synthesizer must reshape MCP data between passes. When debugging MCP config, check both schemas.
