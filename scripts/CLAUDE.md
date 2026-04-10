# scripts/ — Standalone Validator Scripts

Two self-contained bash validators run in Phase 5 (`lib/validate.sh`) and tested independently by `tests/scripts/`.

## Files

- `validate-skill.sh` — validates generated Claude Code skill files
- `validate-subagent.sh` — validates generated Claude Code subagent files

## Usage

```bash
bash scripts/validate-skill.sh /path/to/skill-name/SKILL.md
bash scripts/validate-subagent.sh /path/to/agent-name.md
```

Exit code `0` = PASS or NEEDS REVISION (warnings only). Exit code `1` = FAIL (at least one ERROR).

## What Each Validator Checks

### `validate-skill.sh`

1. **File path**: SKILL.md must be inside a named subdirectory; that directory name is the canonical skill name
2. **Frontmatter**: must have `name:` (kebab-case, matches directory name) and `description:` (no angle brackets)
3. **Description**: ≤1024 characters (measured on space-collapsed joined string, not raw lines)
4. **Trigger phrases**: description should contain ≥3 natural-language phrases that activate the skill
5. **Negative scope**: description should contain a "Do NOT use for" boundary clause
6. **File references**: body must contain ≥3 codebase-specific references (backtick-wrapped names or recognized directory prefixes like `src/`, `lib/`, `tests/`). Counted per line, not per occurrence — spread references across 3+ lines
7. **Verification section**: body must contain a verification/testing section
8. **Generic phrases**: body must not contain "best practice", "clean code", etc.

Warnings threshold: >3 warnings = NEEDS REVISION (still exits 1, blocking write).

### `validate-subagent.sh`

1. **Frontmatter**: must have `name:` and `description:` with trigger phrases
2. **Tool scoping**: `tools:` field should match stated purpose (read-only agents should not have Write/Edit)
3. **File references**: ≥3 codebase-specific references (WARNING, not ERROR)
4. **Generic phrases**: same ban as skills

Warnings threshold: >4 warnings = NEEDS REVISION. Note: `validate-subagent.sh` fails on >4 warnings (not >3 like `validate-skill.sh`).

## Design Constraints

**No dependencies beyond POSIX utilities.** Both scripts use only bash builtins, `grep`, `sed`, `awk`, `wc`, `head`, `tail`, `basename`, `dirname`. No `jq`, no `lib/` sourcing. This independence is the key design constraint — do not add external dependencies.

**Full execution always.** Both scripts accumulate `ERRORS` and `WARNINGS` counters and run all checks unconditionally — no early exit on first error. The revision agent needs the full list of issues.

**awk two-pass frontmatter parser.** Both scripts parse the YAML description field (including multi-line folded `>` and literal `|` scalars) with an awk program: `NR==start` strips the field key, `NR>start && /^  /` appends continuation lines, `NR>start { exit }` stops at the next field.

**`grep -c` counts lines, not occurrences.** A single line with three backtick paths counts as 1. Spread file references across at least 3 separate lines in generated skills.

## Critical Gotchas

**Skill name derived from parent directory, not filename.** `validate-skill.sh` uses `basename $(dirname $1)` as the skill name. A `SKILL.md` placed in an arbitrary temp dir will fail kebab-case checks on the temp dir name. Always create a properly-named subdirectory: `mkdir -p skill-name/ && cat > skill-name/SKILL.md`.

**`grep -c` returns exit code 1 when count is 0.** All grep count calls use `|| true` to prevent pipeline exit. If `grep` itself errors (bad regex, missing file), `|| true` swallows the error too. Pattern: `COUNT=$(grep -cE '...' file || true); COUNT=${COUNT:-0}`.

**NEEDS REVISION is human-facing only.** `lib/validate.sh` only counts `ERROR:` lines to decide whether to run the revision agent. `NEEDS REVISION` verdict has no programmatic effect — only `ERRORS > 0` triggers automated revision.

**Failed subagents are not revised.** The revision agent in `lib/validate.sh` only fixes failed *skills* and CLAUDE.md generic phrases. Failed subagents are logged and counted but not fed to the revision agent. A failing subagent must be manually inspected.

**Tool-scope check only works for single-line `tools:` field.** `validate-subagent.sh` uses `grep -m1 '^tools:'` for tool-scope coherence. Multi-line YAML tool lists cause `TOOLS_VAL` to be empty, triggering the "no tools set" warning instead of the "has Write/Edit" branch. Keep `tools:` as a comma-separated single-line value in generated subagent files.
