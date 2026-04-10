# prompts/ — Agent System Prompts

14 markdown files, each the system prompt for one `claude -p` agent. Files are paired 1:1 with schemas in `schemas/`. The prompt defines task intent; the schema enforces output types.

## File Index

| File | Phase | Model | Purpose |
|---|---|---|---|
| `identity.md` | 1 | haiku | Project name, languages, frameworks, monorepo detection |
| `commands.md` | 1 | haiku | Build, test, lint, format commands from all config files |
| `git-forensics.md` | 1 | sonnet | Hotspots, temporal coupling, bug density, ownership |
| `patterns.md` | 1 | sonnet | Architectural patterns, error handling, naming conventions |
| `tooling.md` | 1 | haiku | Linters, formatters, pre-commit hooks |
| `docs-scanner.md` | 1 | haiku | Existing docs inventory and coverage gaps |
| `security-scan.md` | 1 | haiku | Files needing protection, safe alternatives |
| `structure-scout.md` | 1 | sonnet | Directory map with roles and priority tiers |
| `module-analyzer.md` | 1 (Stage 2) | sonnet | Deep-dive per directory (spawned once per important dir) |
| `domain-researcher.md` | 3 | sonnet | Business domain terminology and framework best practices |
| `mcp-discoverer.md` | 3 | sonnet | MCP server recommendations from registry + GitHub |
| `synthesizer-docs.md` | 4 Pass 1 | sonnet[1m] | Generate CLAUDE.md files from all findings |
| `synthesizer-tooling.md` | 4 Pass 2 | sonnet[1m] | Generate skills, hooks, subagents, MCP config |
| `synthesizer.md` | reference | — | Master/reference prompt covering both passes (not used directly in pipeline) |

## Critical Rules

### Evidence Mandatory

Every gather agent prompt requires file citations for every claim. No assertion without a real file path. This is enforced by explicit instructions: `patterns.md` includes "Do NOT invent patterns. Only report what you can prove exists." Any new gather prompt must include a similar evidence requirement.

### Portability Test (Synthesizers)

Both `synthesizer.md` and `synthesizer-tooling.md` end with a checklist that includes the Portability Test: "Any skill that could be dropped unchanged into an unrelated project has failed." Every skill must contain ≥3 codebase-specific file references to pass. This is the most important quality gate in the entire system.

### Prohibition + Alternative Pairing

Every "Do NOT do X" must be paired with "Do Y instead." `synthesizer.md` explicitly forbids lone prohibitions. This applies to CLAUDE.md content, skills, and subagent instructions. Do not add prohibitions to synthesizer outputs without alternatives.

### Generic Phrase Ban

These phrases are explicitly banned in `synthesizer.md` and must never appear in generated CLAUDE.md or skill content: "best practice", "clean code", "SOLID principles", "maintainable", "readable", "scalable", "well-structured", "production-ready", "industry standard". Delete on sight.

### YAML Angle-Bracket Prohibition

`synthesizer-tooling.md` explicitly forbids `<` and `>` in YAML frontmatter fields. This prohibition is **absent from `synthesizer.md`**, even though it also generates skill YAML. When editing `synthesizer.md`, add: "NEVER use angle brackets (< or >) in YAML frontmatter or description fields — they break YAML parsing."

## Schema Coupling

Prompts describe output field names in prose; schemas enforce types. The two must stay in sync manually — there is no automated cross-validation. When modifying a prompt's output section, always update the paired schema in `schemas/` in the same commit.

`module-analyzer.md` receives the directory path as context injected into the prompt string at call time in `lib/gather.sh`, not via a system prompt variable. If refactoring the invocation, the path must be interpolated before the `claude -p` call.

## Complexity vs Phase

Gather agents: 13–55 lines (narrow, single output type, cost-sensitive — many run in parallel). Synthesizers: 101–295 lines (multi-artifact, quality checklist, embedded template structures). This ratio is intentional. Never add quality checklists to gather agents.

## Known Issue: Three Overlapping Synthesizer Prompts

`synthesizer.md` is the comprehensive reference. The actual pipeline uses `synthesizer-docs.md` (Pass 1) then `synthesizer-tooling.md` (Pass 2). Using `synthesizer.md` as a drop-in replacement for both passes would skip the Pass 1→Pass 2 dependency (Pass 2 needs Pass 1's CLAUDE.md as source of truth). Do not conflate them.
