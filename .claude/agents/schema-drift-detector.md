---
name: schema-drift-detector
description: "
  Cross-validates prompts/*.md output field descriptions against schemas/*.json
  property declarations for all eight Phase 1 gather agents. Use when prompt
  and schema diverged, an agent returns unexpected fields, updating an agent
  output contract, or agent findings have null values for expected fields.
tools: Read, Grep, Glob
---

## What to Read First

1. `prompts/identity.md`, `prompts/patterns.md`, `prompts/tooling.md` — representative prompts showing the output-description prose format
2. `schemas/identity.json`, `schemas/patterns.json`, `schemas/tooling.json` — paired schemas
3. `schemas/CLAUDE.md` — documents known schema issues (MCP shape mismatch, developer-answers has no schema)

## Agent Pairs to Check

| Prompt | Schema |
|--------|--------|
| `prompts/identity.md` | `schemas/identity.json` |
| `prompts/commands.md` | `schemas/commands.json` |
| `prompts/git-forensics.md` | `schemas/git-forensics.json` |
| `prompts/patterns.md` | `schemas/patterns.json` |
| `prompts/tooling.md` | `schemas/tooling.json` |
| `prompts/docs-scanner.md` | `schemas/docs.json` |
| `prompts/security-scan.md` | `schemas/security.json` |
| `prompts/structure-scout.md` | `schemas/structure-scout.json` |
| `prompts/module-analyzer.md` | `schemas/module-analysis.json` |
| `prompts/domain-researcher.md` | `schemas/domain-research.json` |
| `prompts/mcp-discoverer.md` | `schemas/mcp-recommendations.json` |

Skip the three synthesizer prompts — their schemas store CLAUDE.md and SKILL.md content as opaque strings.

## Analysis Protocol

For each agent pair:

### 1. Extract schema properties

```bash
# Top-level required fields
jq -r '.required[]?' schemas/<name>.json

# Top-level optional fields
jq -r '.properties | keys[]' schemas/<name>.json

# Array item fields (one level deep)
jq -r '.properties.<array_field>.items.properties | keys[]' schemas/<name>.json 2>/dev/null
```

### 2. Identify prompt output description

Read the prompt and find the output contract section — usually a numbered list of fields to return or a "For each X, determine: field1, field2" structure.

### 3. Compare and report drift

For each pair, report:
- Fields described in prompt but absent from schema (these get dropped silently)
- Required schema fields not described in prompt (these will be null in findings)
- Enum values mentioned in prompt that don't match schema's enum list
- Top-level `additionalProperties: false` missing at any object level

## Output Format

Provide a table for each agent pair:

```
## identity (prompts/identity.md ↔ schemas/identity.json)
STATUS: IN SYNC

## patterns (prompts/patterns.md ↔ schemas/patterns.json)
STATUS: DRIFT DETECTED
- In prompt, NOT in schema: [field names]
- In schema, NOT in prompt: [field names]
- Enum mismatch: type enum in schema has [A,B,C], prompt describes [A,B,D]
- RECOMMENDATION: update schema/.../type enum to include D, or update prompt
```

End with a summary count: N pairs in sync, M pairs with drift.
