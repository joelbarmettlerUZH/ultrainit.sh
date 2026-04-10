# schemas/ — Agent Output Contracts

14 JSON Schema files defining the structured output contract for every `claude -p` agent and synthesis pass. All schemas are validated in CI via `jq empty`.

## File Index

| Schema | Agent | Phase | Key Fields |
|---|---|---|---|
| `identity.json` | identity | 1 | name, description, languages, frameworks, monorepo, packages |
| `commands.json` | commands | 1 | build, test, lint, format, typecheck, other (via $defs) |
| `git-forensics.json` | git-forensics | 1 | hotspots, temporal_coupling, bug_fix_density, ownership_diffusion |
| `patterns.json` | patterns | 1 | patterns[].{name, type, evidence_files, description, is_consistent} |
| `tooling.json` | tooling | 1 | tools[].{name, config_path, enforced_in_ci, has_pre_commit} |
| `docs.json` | docs-scanner | 1 | documents, documented_conventions, undocumented_gaps |
| `security.json` | security-scan | 1 | protected_files[].{path_pattern, reason, safe_alternative} |
| `structure-scout.json` | structure-scout | 1 | directories[].{path, role, priority, should_have_claude_md} |
| `module-analysis.json` | module-analyzer | 1 Stage 2 | module_path, purpose, key_files, patterns, gotchas |
| `domain-research.json` | domain-researcher | 3 | domain_knowledge, framework_practices, common_pitfalls |
| `mcp-recommendations.json` | mcp-discoverer | 3 | servers[].{name, command, args, env, relevance} |
| `synthesis-docs.json` | synthesizer-docs | 4 Pass 1 | claude_md (string), subdirectory_claude_mds[] |
| `synthesis-tooling.json` | synthesizer-tooling | 4 Pass 2 | skills[], hooks[], subagents[], mcp_servers[], settings_hooks[] |
| `synthesis-output.json` | merged output | 4 | merged shape of docs + tooling passes |

## Universal Rules

### `additionalProperties: false` Everywhere

Every schema and every nested object uses `additionalProperties: false`. This is the single most important convention — it prevents Claude from hallucinating fields beyond the declared contract. Never add an object to a schema without this key.

### Enum-Driven Categorical Fields

All categorical distinctions must be enums, never free-form strings:
- `structure-scout.json`: 23-value `role` enum, 3-value `priority` enum (`high`, `medium`, `low`)
- `patterns.json`: 9-value `type` enum  
- `synthesis-tooling.json`: hook events constrained to `[PreToolUse, PostToolUse, Notification, Stop]`

This enables safe downstream filtering with `select(.priority == "high")` without defensive string matching.

### Optional Arrays (Never Nullable)

Fields that only apply conditionally are excluded from `required` but declared as `array` type — never as nullable scalars. Consumers can always use `jq .field[]?` safely. Example: `identity.json.packages` (only for monorepos), `module-analysis.json.commands`.

### Markdown/Bash as Opaque Strings

`synthesis-docs.json` and `synthesis-tooling.json` store full document content (CLAUDE.md text, SKILL.md with YAML frontmatter, bash hook scripts) as plain JSON strings. Schema validation ends at the string boundary. YAML validity, shebang presence, `set -euo pipefail` — all checked externally by `scripts/validate-skill.sh` and `validate.sh`.

## Known Schema Issues

**`synthesis-output.json` is not passed to `claude -p`.** It describes the shape of the `jq -s '.[0] * .[1]'` merged file. If either synthesis pass produces an unexpected top-level key, the merge silently overwrites with the second file's value. Validate the merged output manually if debugging merge issues.

**Enum constraints are guidance, not hard enforcement.** `claude -p` may return values outside declared enums (e.g., `priority: "critical"` instead of `"high"`). Downstream `jq select()` filters silently skip unexpected values. Add explicit validation in `lib/gather.sh` after `structure-scout` output is written if you need strict enforcement.

**`identity.json.packages` has a conditional dependency.** It should only be populated when `monorepo: true`, but the schema cannot express this. Downstream consumers must check `monorepo === true` before iterating `packages`.

**Two MCP schema shapes exist.** `mcp-recommendations.json` includes `relevance` and a nested `configuration` object. `synthesis-tooling.json` flattens `command/args/env` to top level. The synthesizer prompt must reshape MCP data. When debugging MCP config issues, check both schemas side-by-side.

**`developer-answers.json` has no schema.** It is hand-assembled by `lib/ask.sh`. Field names (`project_purpose`, `deployment_target`, `never_do`, `common_mistakes`, `additional_context`) are a de-facto schema. Any change to `ask.sh` output keys requires updating all `jq` expressions in `synthesize.sh`.

**`settings_hooks[]` entries must have matching `hooks[]` entries.** The schema does not enforce this relationship. `validate.sh` checks it after synthesis. If adding a hook to a synthesizer prompt, always generate both the `hooks[]` content entry and the `settings_hooks[]` wiring entry in the same response.

**Module findings file collision.** `module-analysis.json` is reused for all deep-dive agents but output files are named `module-<dirname>.json`. Two directories with the same basename (e.g., `src/api` and `lib/api`) will collide. `lib/gather.sh` should use full-path slugs rather than basename only.
