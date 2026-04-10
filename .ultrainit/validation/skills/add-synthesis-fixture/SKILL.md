---
name: add-synthesis-fixture
description: "
  Add or update entries in synthesis fixtures while keeping output-docs.json,
  output-tooling.json, and output.json consistent. Use when extend the
  synthesis schema, add a new artifact type to synthesis, synthesis fixture
  needs updating, or add a new skill entry to test write_artifacts. Do NOT
  use for findings fixtures — use fixture-sync for those.
---

## Before You Start

- `tests/fixtures/synthesis/output-docs.json` — Pass 1 output (CLAUDE.md content)
- `tests/fixtures/synthesis/output-tooling.json` — Pass 2 output (skills, hooks, MCP)
- `tests/fixtures/synthesis/output.json` — derived merged file (DO NOT edit directly)
- `schemas/synthesis-docs.json` and `schemas/synthesis-tooling.json` — the output contracts
- `tests/unit/merge.bats` — tests that read from `output.json` directly

## Critical Rule

`output.json` is a **derived file** — it is the `jq -s '.[0] * .[1]'` merge of `output-docs.json` and `output-tooling.json`. Never edit `output.json` directly. After any change to either pass fixture, always re-merge.

## Steps

### 1. Identify which pass owns the new field

- **Pass 1 (`output-docs.json`)**: CLAUDE.md root content, subdirectory CLAUDE.md files
- **Pass 2 (`output-tooling.json`)**: skills, hooks, subagents, mcp_servers, settings_hooks

### 2. Edit the appropriate pass fixture

Skill entries in `output-tooling.json` must have:
- No angle brackets in description fields
- `name` in kebab-case
- Valid SKILL.md content as a JSON string (use `\n` for newlines)

Example skill entry:

```json
{
  "name": "my-skill",
  "description": "Does something specific to this project. Use when...",
  "content": "---\nname: my-skill\ndescription: >\n  Does something specific. Use when...\n  Do NOT use for...\n---\n\n## Before You Start\n..."
}
```

Hook entries must maintain the 1:1 hooks-to-settings_hooks relationship:

```json
// In hooks[]
{"filename": "check.sh", "event": "PostToolUse", "description": "...", "content": "#!/usr/bin/env bash\n..."}

// Matching entry in settings_hooks[]
{"event": "PostToolUse", "matcher": "Write", "command": ".claude/hooks/check.sh"}
```

### 3. Re-merge output.json

After editing either pass fixture:

```bash
jq -s '.[0] * .[1]' \
    tests/fixtures/synthesis/output-docs.json \
    tests/fixtures/synthesis/output-tooling.json \
    > tests/fixtures/synthesis/output.json
```

### 4. Verify no angle brackets in descriptions

```bash
grep -n '[<>]' tests/fixtures/synthesis/output-tooling.json | head -20
```

Angle brackets in skill/subagent descriptions will cause `validate-skill.sh` to fail, and `postprocess_descriptions()` in `lib/synthesize.sh` will silently replace them at runtime — meaning the fixture diverges from what production produces.

### 5. Update dependent test assertions

Check `tests/unit/merge.bats` and `tests/integration/synthesize_phase.bats` for assertions on skill count, specific field values, or hook count that may need updating.

### 6. Verify the claude_md padding in output-docs.json

The `claude_md` field contains deliberate padding lines to exceed the 100-line minimum for `validate_claude_md` checks. Do NOT trim it:

```bash
echo "$(jq -r '.claude_md' tests/fixtures/synthesis/output-docs.json | wc -l) lines"
# Must be >= 100
```

## Verify

```bash
make test-unit
make test-integration
```

## Common Mistakes

1. **Editing `output.json` directly** — it gets overwritten on the next merge. Always edit the pass fixture and re-merge.

2. **Using `make_claude_envelope` on `output.json`** — unit tests copy `output.json` raw into `$WORK_DIR/synthesis/`; integration tests wrap `output-docs.json` and `output-tooling.json` with `make_claude_envelope`. Using the wrong combination causes silent `null` extractions.
