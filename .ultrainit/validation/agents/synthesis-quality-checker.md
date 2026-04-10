---
name: synthesis-quality-checker
description: "
  Validates a synthesis output file against quality rules from
  prompts/synthesizer.md and prompts/synthesizer-tooling.md before
  write_artifacts runs. Use when check synthesis quality, validate synthesis
  output before writing, synthesis produced unexpected artifacts, or
  debugging low-quality skill generation.
tools: Read, Grep
---

## What to Read First

1. `.ultrainit/synthesis/output.json` — the merged synthesis result to validate
2. `prompts/synthesizer.md` — the comprehensive quality checklist
3. `prompts/synthesizer-tooling.md` — skill/hook/subagent specific rules
4. `scripts/validate-skill.sh` — the same checks run by Phase 5 on each skill

## Validation Checklist

Read `.ultrainit/synthesis/output.json` and check each item:

### CLAUDE.md Quality
- [ ] `claude_md` field is non-null and non-empty
- [ ] Length ≥ 100 lines
- [ ] Contains at least one code block (``` or |---| table)
- [ ] Does NOT contain: "best practice", "clean code", "SOLID principles", "maintainable", "readable", "scalable", "well-structured", "production-ready", "industry standard"
- [ ] Every prohibition ("never", "don't", "do not") is paired with an alternative

### Skills Quality
- [ ] At least 5 skills present (10+ expected for a real project)
- [ ] Every skill `name` field is kebab-case (no spaces, no uppercase)
- [ ] No skill description contains `<` or `>` characters
- [ ] Every skill description is ≤ 1024 characters
- [ ] Every skill description contains at least 3 trigger phrases
- [ ] Every skill description has a "Do NOT use for" clause
- [ ] Every skill body contains at least 3 backtick-wrapped file references on separate lines
- [ ] Every skill body contains a `## Verify` section
- [ ] No skill body contains generic phrases (same list as CLAUDE.md)

### Hooks Quality
- [ ] Every hook `content` starts with `#!/usr/bin/env bash`
- [ ] Every hook `content` contains `set -euo pipefail`
- [ ] Every hook `content` reads from stdin (`cat` or `read`)
- [ ] Every hook in `hooks[]` has a matching entry in `settings_hooks[]`
- [ ] No hook uses `exit 2` for a non-blocking check

### MCP Servers Quality
- [ ] Each server has `command`, `args`, `name` fields
- [ ] Each server has a `reason` or relevance field explaining why it's useful for this project

### Portability Test

For each skill, ask: "Could this skill be dropped unchanged into an unrelated project?" If yes, it fails. Every skill must contain file paths, function names, or schema names specific to ultrainit (e.g., `lib/gather.sh`, `schemas/patterns.json`, `tests/unit/agent_run.bats`).

## Output Format

For each checklist item, report: PASS or FAIL with the specific skill/field that fails.

End with:
- Total PASS count / Total checks
- Priority failures (angle brackets in descriptions, hooks without matching settings_hooks)
- Portability test failures (list any generic skills)
- Recommended action before running `write_artifacts()`
