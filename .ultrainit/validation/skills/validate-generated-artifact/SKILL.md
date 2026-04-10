---
name: validate-generated-artifact
description: "
  Run validate-skill.sh or validate-subagent.sh on a generated artifact,
  interpret validation errors, and apply targeted fixes. Use when validate
  this skill, skill validation failed, fix validation errors in generated
  output, or check this subagent passes validation. Do NOT use for hooks
  — hooks are validated separately via validate_hook in lib/validate.sh.
---

## Before You Start

- `scripts/validate-skill.sh` — skill validator (checks frontmatter, file refs, descriptions)
- `scripts/validate-subagent.sh` — subagent validator
- `tests/fixtures/skills/valid-skill/SKILL.md` — canonical passing skill example
- `tests/fixtures/subagents/valid-subagent.md` — canonical passing subagent example

## Running the Validators

### Skill validation

```bash
# Skills must be inside a named subdirectory — validator derives name from parent dir
mkdir -p .claude/skills/<skill-name>
cat > .claude/skills/<skill-name>/SKILL.md << 'EOF'
...
EOF

bash scripts/validate-skill.sh .claude/skills/<skill-name>/SKILL.md
```

### Subagent validation

```bash
bash scripts/validate-subagent.sh .claude/agents/<agent-name>.md
```

## Interpreting Output

Output lines are prefixed with `ERROR:`, `WARNING:`, or informational text. Exit code `1` = at least one ERROR.

```
ERROR: frontmatter: name field missing
ERROR: body: fewer than 3 codebase-specific file references found (got 1)
WARNING: description: fewer than 3 trigger phrases detected
VERDICT: FAIL
```

**Errors** block writing. **Warnings** count toward the threshold (>3 warnings in skills, >4 in subagents triggers `NEEDS REVISION`).

## Fixing Common Errors

### "name field missing" or "kebab-case violation"

The `name:` in frontmatter must match the parent directory name exactly and be kebab-case:

```yaml
---
name: my-skill-name   # must match: .claude/skills/my-skill-name/SKILL.md
```

### "fewer than 3 codebase-specific file references"

The counter uses `grep -c` (counts lines, not occurrences). Spread file references across at least 3 **separate lines**:

```markdown
# Wrong — all on one line (counts as 1)
See `lib/agent.sh`, `lib/gather.sh`, `lib/synthesize.sh`

# Correct — separate lines (counts as 3)
- `lib/agent.sh` handles agent spawning
- `lib/gather.sh` wires agents into phases
- `lib/synthesize.sh` builds the synthesis context
```

Recognized formats: backtick-wrapped names (`` `file.sh` ``) and directory prefixes (`lib/`, `tests/`, `schemas/`, `prompts/`, `scripts/`).

### "description contains angle brackets"

Angle brackets break YAML parsing. Replace:
- `Use for <adding endpoints>` → `Use for adding endpoints`
- `(e.g., <name>)` → `(e.g., my-name)`

### "generic phrase detected"

Banned phrases: "best practice", "clean code", "SOLID principles", "maintainable", "readable", "scalable", "well-structured", "production-ready", "industry standard". Remove them without replacement — just describe what the skill actually does.

### "no verification section"

Add a `## Verify` section with concrete commands:

```markdown
## Verify

```bash
make test-unit
bash -n lib/gather.sh
```
```

### "description exceeds 1024 characters"

The validator collapses the description to a single space-joined string before counting. Multi-line YAML folded scalars (`>`) are joined. Trim the description to under 1024 characters in the collapsed form.

## Verify

```bash
bash scripts/validate-skill.sh .claude/skills/<name>/SKILL.md
echo "Exit: $?"
```

Exit 0 with `VERDICT: PASS` means it will be accepted by `lib/validate.sh`.
