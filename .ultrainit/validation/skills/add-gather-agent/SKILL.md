---
name: add-gather-agent
description: "
  Scaffold a new Phase 1 gather agent: prompt in prompts/, schema in schemas/,
  wired into lib/gather.sh, fixture in tests/fixtures/findings/, and
  integration test dispatch entry. Use when asked to add a new gather agent,
  create a new analysis agent, add a Phase 1 agent, or extend what ultrainit
  detects. Do NOT use for Phase 3 research agents (those go in
  lib/research.sh) or for modifying synthesis passes.
---

## Before You Start

Read these files before touching anything:
- `prompts/patterns.md` — anatomy of a gather prompt (evidence requirement, numbered output fields)
- `schemas/tooling.json` — example schema with `additionalProperties: false` and enum fields
- `lib/gather.sh` lines 24-65 — where to add your `run_agent` call in `run_agents_parallel`
- `lib/gather.sh` lines 67-102 — critical-failure gating and `get_failed_agents` check list
- `tests/helpers/mock_claude.bash` — how dispatch mode matches agent names to fixture files
- `tests/unit/agent_run.bats` — the test setup pattern (envelope, dispatch, assertions)

## Steps

### 1. Name and scope the agent

Choose a `kebab-case` name (e.g., `dependency-graph`). Decide:

- **Model tier**: `haiku` for simple file scanning (matches identity, tooling, commands, docs-scanner, security-scan); `sonnet` for reasoning (matches git-forensics, patterns, structure-scout)
- **Tool allowlist**: `Read,Bash(find:*),Bash(cat:*)` for file reading; add `Bash(git:*)` only for git history; add `Glob` for pattern matching
- **Critical agent?** Only add to the critical list if synthesis cannot proceed without this agent's findings

### 2. Write the system prompt

Create `prompts/<agent-name>.md`:

```markdown
You are analyzing a software codebase. Your goal: [one sentence].

For this codebase, determine:
1. [output field 1 — instructions on what to look for and where]
2. [output field 2]
...

For every finding, cite the specific file path(s) where you found evidence.
Do NOT invent patterns. Only report what you can prove exists in the files.

Return results as structured JSON matching the schema provided.
```

The evidence-requirement sentence is **mandatory** in every gather prompt — see `prompts/patterns.md` for the exact phrasing used across agents.

### 3. Write the JSON schema

Create `schemas/<agent-name>.json`. All schemas **must** use `"additionalProperties": false` at every nested object level:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "additionalProperties": false,
  "required": ["findings"],
  "properties": {
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["name", "category"],
        "properties": {
          "name": { "type": "string" },
          "category": { "type": "string", "enum": ["A", "B", "C"] },
          "evidence_files": { "type": "array", "items": { "type": "string" } }
        }
      }
    }
  }
}
```

- Use `"enum"` for all categorical fields — downstream `jq select()` relies on exact string matching
- Use `"type": "array"` (never nullable) for optional collections — consumers use `.field[]?` safely
- Use `"$defs"` for repeated item shapes (see `schemas/commands.json`)
- Validate before wiring: `jq empty schemas/<agent-name>.json`

### 4. Wire into gather.sh

Open `lib/gather.sh`. Find the `run_agents_parallel` call in `gather_evidence()` (lines 24-65). Add your agent as a new argument string:

```bash
run_agents_parallel \
    "run_agent identity ..." \
    ... \
    "run_agent <agent-name> \
        '@${SCRIPT_DIR}/prompts/<agent-name>.md' \
        '${SCRIPT_DIR}/schemas/<agent-name>.json' \
        'Read,Bash(find:*),Bash(cat:*)' \
        haiku gather"
```

**Always use the `@` prefix** for the prompt path — this is required for prompts with shell-special characters (apostrophes, parens, backticks) and prevents ARG_MAX issues on large prompts. Always use `$SCRIPT_DIR` for absolute paths.

Also add `<agent-name>` to the `core_agents` array and the `get_failed_agents` check (lines 67-77). If critical, add to `critical_agents` array too.

### 5. Create the test fixture

Create `tests/fixtures/findings/<agent-name>.json` with realistic data matching your schema:

```json
{
  "findings": [
    {
      "name": "example-finding",
      "category": "A",
      "evidence_files": ["lib/example.sh", "schemas/example.json"]
    }
  ]
}
```

The filename **must exactly match** the agent name passed to `run_agent()`. This is the three-way identity: fixture filename = agent name = findings file name. A mismatch silently breaks mock dispatch routing. This file contains only the `structured_output` value — the mock dispatch wraps it via `make_claude_envelope`.

### 6. Add the dispatch entry to integration tests

In `tests/integration/gather_phase.bats`, find the dispatch setup block and add:

```bash
make_claude_envelope \
    "$(cat "$BATS_TEST_DIRNAME/../fixtures/findings/<agent-name>.json")" "0.15" \
    > "$MOCK_CLAUDE_DISPATCH_DIR/<agent-name>.json"
```

Also update the systemic-failure test that pre-creates exactly 4 of 8 findings — if you add a 9th core agent, the threshold math changes (3+ of 9 now requires updating).

### 7. Add a unit test

Create `tests/unit/<agent-name>_run.bats`:

```bash
setup() {
    load '../helpers/test_helper'
    _common_setup
    load '../helpers/mock_claude'
    setup_mock_claude
}
teardown() { _common_teardown; }

@test "run_agent <agent-name>: writes findings on success" {
    make_claude_envelope \
        "$(cat "$BATS_TEST_DIRNAME/../fixtures/findings/<agent-name>.json")" "0.15" \
        > "$MOCK_CLAUDE_RESPONSE"
    run run_agent "<agent-name>" \
        "@${SCRIPT_DIR}/prompts/<agent-name>.md" \
        "${SCRIPT_DIR}/schemas/<agent-name>.json" \
        "Read,Bash(find:*)" "haiku" "gather"
    assert_success
    assert_file_exists "$WORK_DIR/findings/<agent-name>.json"
}

@test "run_agent <agent-name>: skips when findings exist and FORCE=false" {
    echo '{"findings":[]}' > "$WORK_DIR/findings/<agent-name>.json"
    FORCE=false run run_agent "<agent-name>" "..." "..." "..." "haiku"
    assert_success
    run grep 'CALL:' "$MOCK_CLAUDE_LOG"
    assert_failure  # mock was not called
}
```

## Verify

```bash
# Validate schema is well-formed
jq empty schemas/<agent-name>.json

# Syntax-check gather.sh after wiring
bash -n lib/gather.sh

# Run all tests
make test-unit
make test-integration
make test-all
```

## Common Mistakes

1. **Missing `additionalProperties: false` on nested objects** — this is the single most common schema error. Every `"type": "object"` at every nesting level needs it, or Claude can hallucinate extra fields.

2. **Inline prompt with shell-special characters** — prompts containing apostrophes, parens, backticks, or `$` break parallel temp-script expansion. Always use the `@/absolute/path` form. See PR #2 and `tests/edge/special_characters.bats`.

3. **Wrong fixture filename** — the fixture must be named exactly `<agent-name>.json` where `<agent-name>` matches the first arg to `run_agent()`. A mismatch silently falls through to `MOCK_CLAUDE_RESPONSE`.

4. **Not updating `core_agents` array** — if you add the agent to `run_agents_parallel` but not to `core_agents` (and optionally `critical_agents`) in `lib/gather.sh`, the failure-gating logic ignores it completely.
