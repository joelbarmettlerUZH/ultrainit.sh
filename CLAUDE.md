# ultrainit

**A shell-native tool that uses Claude Code itself to deeply analyze any codebase and generate a complete Claude Code configuration — CLAUDE.md, skills, hooks, subagents, commands, and MCP servers.**

No Python. No npm. No dependencies beyond `claude`, `jq`, and standard Unix tools (`git`, `bc`, `mktemp`, `sed`, `awk`, `grep`). Runs on macOS, Linux, and Windows (Git Bash / WSL).

```bash
# One command. Any codebase.
curl -sL https://github.com/joelbarmettlerUZH/ultrainit.sh/releases/latest/download/ultrainit.sh | bash
```

---

## 1. What This Is

ultrainit is a Bash script that orchestrates multiple `claude -p` invocations to build the deepest possible understanding of a codebase, then distills that understanding into Claude Code configuration files.

Each analysis task spawns a Claude Code instance as a subagent. Each subagent gets a focused prompt, a scoped set of tools, and returns structured findings. The orchestrator collects all findings, feeds them through a synthesis agent, and writes the final artifacts.

The result: a `.claude/` directory and `CLAUDE.md` that would take a human engineer days to write by hand.

### How It Works — The Core Loop

```
┌─────────────────────────────────────────────────────────┐
│                    ultrainit.sh                         │
│                   (Bash orchestrator)                    │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  Phase 1: GATHER  (parallel claude -p calls)            │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐   │
│  │ identity │ │ commands │ │  git     │ │ patterns │   │
│  │ agent    │ │ agent    │ │ forensics│ │ agent    │   │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘   │
│       │             │            │             │          │
│       ▼             ▼            ▼             ▼          │
│  ┌──────────────────────────────────────────────────┐    │
│  │            .ultrainit/findings/                  │    │
│  │   identity.json  commands.json  git.json  ...    │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  Phase 2: ASK  (interactive developer questions)        │
│  ┌──────────────────────────────────────────────────┐    │
│  │  Terminal prompts for things code can't answer    │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  Phase 3: RESEARCH  (claude -p with web access)         │
│  ┌──────────┐ ┌──────────┐                              │
│  │ domain   │ │  MCP     │                              │
│  │ research │ │ discovery│                              │
│  └────┬─────┘ └────┬─────┘                              │
│       │             │                                    │
│  Phase 4: SYNTHESIZE  (two 1M context passes)           │
│  ┌──────────────────────────────────────────────────┐    │
│  │  Pass 1: All findings → CLAUDE.md files           │    │
│  │  Pass 2: CLAUDE.md + findings → skills, hooks,    │    │
│  │          subagents, MCP config                     │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  Phase 5: VALIDATE & WRITE                              │
│  ┌──────────────────────────────────────────────────┐    │
│  │  Structural validation → backup existing → write  │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### Why Shell + Claude Code

- **Minimal dependencies.** `claude`, `jq`, and standard Unix tools. The script checks everything at startup.
- **Claude is better at understanding code than any static analysis tool.** Instead of reimplementing tree-sitter parsers and AST walkers, we give Claude the code and let it reason.
- **Claude can search the web.** Domain knowledge, framework best practices, MCP server discovery — Claude already has these capabilities built in.
- **Structured JSON output.** `claude -p --output-format json --json-schema '{...}'` gives us typed, parseable results from every agent call.
- **Resumable by design.** Each agent writes its findings to a file. If the script crashes, rerun and it skips completed phases.
- **Parallelizable.** Background `claude -p` processes run simultaneously. Bash `wait` collects results.

---

## 2. Architecture

### 2.1 File Layout

```
ultrainit/
├── ultrainit.sh                   # Main entry point (CLI, phase orchestration)
├── lib/
│   ├── config.sh                   # Configuration, defaults, dependency checks, budget
│   ├── agent.sh                    # Agent spawning, parallel execution, failure diagnostics
│   ├── gather.sh                   # Phase 1: evidence gathering agents
│   ├── ask.sh                      # Phase 2: interactive questions
│   ├── research.sh                 # Phase 3: web research agents
│   ├── synthesize.sh               # Phase 4: two-pass synthesis
│   ├── validate.sh                 # Phase 5: validation + revision
│   ├── merge.sh                    # Merge/write artifacts to .claude/ config
│   └── utils.sh                    # Logging, progress, JSON helpers, cost reporting
├── schemas/                        # JSON schemas for structured output
│   ├── identity.json
│   ├── commands.json
│   ├── git-forensics.json
│   ├── patterns.json
│   ├── tooling.json
│   ├── docs.json
│   ├── security.json
│   ├── structure-scout.json
│   ├── module-analysis.json
│   ├── domain-research.json
│   ├── mcp-recommendations.json
│   ├── synthesis-docs.json
│   ├── synthesis-tooling.json
│   └── synthesis-output.json
├── prompts/                        # System prompts for each agent
│   ├── identity.md
│   ├── commands.md
│   ├── git-forensics.md
│   ├── patterns.md
│   ├── tooling.md
│   ├── docs-scanner.md
│   ├── security-scan.md
│   ├── structure-scout.md
│   ├── module-analyzer.md
│   ├── domain-researcher.md
│   ├── mcp-discoverer.md
│   ├── synthesizer.md
│   ├── synthesizer-docs.md
│   └── synthesizer-tooling.md
├── scripts/
│   ├── validate-skill.sh           # Skill quality validator
│   └── validate-subagent.sh        # Subagent quality validator
├── docs/
│   ├── logo.png
│   └── diagram.png
├── README.md
├── LICENSE
└── CLAUDE.md                       # We eat our own dogfood
```

### 2.2 The Agent Abstraction

Every analysis task is a call to `claude -p` with:
1. A focused system prompt (from `prompts/`)
2. A JSON schema for structured output (from `schemas/`)
3. Scoped tool permissions (`--allowedTools`)
4. Working directory set to the target project

```bash
# lib/agent.sh

run_agent() {
    local name="$1"           # Agent name (for logging + output file)
    local prompt="$2"         # The task prompt
    local schema_file="$3"    # Path to JSON schema
    local allowed_tools="$4"  # Tool permissions
    local model="${5:-$AGENT_MODEL}" # Model alias
    local output_file="$WORK_DIR/findings/${name}.json"

    # Resumability: skip if findings exist
    if [[ -f "$output_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Skipping $name (findings exist). Use --force to rerun."
        return 0
    fi

    # Budget enforcement
    if ! check_budget 2>/dev/null; then
        log_warn "Skipping $name (budget exhausted)"
        return 1
    fi

    # For large prompts (>100KB), pipe via stdin to avoid arg length limits
    local raw_output
    if [[ ${#prompt} -gt 100000 ]]; then
        raw_output=$(echo "$prompt" | claude -p - ...)
    else
        raw_output=$(claude -p "$prompt" \
            --model "$model" \
            --output-format json \
            --json-schema "$schema" \
            --allowedTools "$allowed_tools" \
            $system_prompt_flag \
            --max-budget-usd "$AGENT_BUDGET" \
            2>>"$WORK_DIR/logs/${name}.stderr")
    fi

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        # claude writes errors to stdout; capture for diagnostics
        if [[ -n "$raw_output" ]]; then
            echo "stdout: $raw_output" >> "$stderr_file"
        fi
        log_error "Agent $name failed (exit $exit_code). See $stderr_file"
        return 1
    fi

    # Extract structured output, validate, track cost
    echo "$raw_output" | jq '.structured_output // .result // .' > "$output_file"
    log_success "Agent $name completed -> $output_file"
}

# Run multiple agents in parallel via temp scripts.
# Each child script explicitly sets all parent variables before sourcing
# libs, so re-sourcing config.sh cannot overwrite computed values.
run_agents_parallel() {
    local pids=()
    local tmp_dir=$(mktemp -d)

    for agent_call in "$@"; do
        local script="$tmp_dir/agent-${idx}.sh"
        cat > "$script" <<AGENT_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

# Propagate parent state explicitly (literal values baked in)
export WORK_DIR="$WORK_DIR"
export SCRIPT_DIR="$SCRIPT_DIR"
export TARGET_DIR="$TARGET_DIR"
export FORCE="$FORCE"
export VERBOSE="$VERBOSE"
export AGENT_MODEL="$AGENT_MODEL"
export AGENT_BUDGET="$AGENT_BUDGET"
export TOTAL_BUDGET="$TOTAL_BUDGET"

source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/agent.sh"
$agent_call
AGENT_SCRIPT
        bash "$script" &
        pids+=($!)
    done

    local failures=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failures=$((failures + 1))
    done
    rm -rf "$tmp_dir"
    return $failures
}

# Collect error logs from failed agents and ask Claude to diagnose.
diagnose_phase_failure() {
    local phase="$1"; shift
    local failed_agents=("$@")

    # Collect last 50 lines of each agent's stderr log
    # Call claude -p with haiku to interpret errors and suggest fixes
    # Falls back to raw log output if Claude itself is broken
}

# Check which agents have missing findings files.
get_failed_agents() {
    # Returns names of agents whose findings files don't exist
}
```

### 2.3 Working Directory

All intermediate state lives in `.ultrainit/` inside the project root:

```
.ultrainit/
├── findings/           # Raw JSON output from each agent
│   ├── identity.json
│   ├── commands.json
│   ├── git-forensics.json
│   ├── patterns.json
│   ├── tooling.json
│   ├── docs-scanner.json
│   ├── security-scan.json
│   ├── structure-scout.json
│   ├── module-src.json          # Deep-dive per directory
│   ├── module-src-routes.json
│   ├── domain-research.json
│   └── mcp-discovery.json
├── developer-answers.json
├── synthesis/          # Synthesis pass outputs
│   ├── output-docs.json         # Pass 1 output
│   ├── output-tooling.json      # Pass 2 output
│   └── output.json              # Merged final output
├── logs/               # stderr from each agent
│   ├── identity.stderr
│   ├── commands.stderr
│   ├── synthesis-docs.stderr
│   └── ...
├── backups/            # Backups of overwritten files
├── cost.log            # Per-agent cost tracking
└── state.json          # Phase completion tracking (for resume)
```

This directory should be added to `.gitignore`. The script handles this automatically.

---

## 3. Phase 1: GATHER — Evidence Collection

Eight parallel agents analyze the codebase from different angles. Each returns structured JSON.

### Agent: identity

**Purpose:** What is this project?

**Prompt:**
```
Analyze this codebase. Determine: the project name, one-line description,
primary languages (with percentages), frameworks and their versions,
whether this is a monorepo (and if so, list packages), the deployment
target if detectable, and any existing AI config files (CLAUDE.md,
.cursorrules, etc).
```

**Tools:** `Read,Bash(find:*),Bash(ls:*),Bash(cat:*),Bash(head:*)`
**Model:** haiku
**Schema:** Returns `{ name, description, languages, frameworks, monorepo, packages, deployment, existing_ai_config }`

### Agent: commands

**Purpose:** What commands does a developer run?

**Prompt:**
```
Find every build, test, lint, format, and typecheck command in this
project. Check: package.json scripts, Makefile/Justfile targets, CI/CD
pipelines (.github/workflows, .gitlab-ci.yml), pyproject.toml scripts,
Cargo.toml, and any task runner configs. For each command, note whether
it is CI-verified (actually runs in a pipeline). Prefer file-scoped
commands over project-wide ones where possible.
```

**Tools:** `Read,Bash(find:*),Bash(cat:*),Bash(grep:*),Bash(jq:*)`
**Model:** haiku
**Schema:** Returns `{ build, test, lint, format, typecheck, other }` — each an array of `{ command, scope, ci_verified, source }`

### Agent: git-forensics

**Purpose:** Where are the hotspots, coupling, and ownership patterns?

**Prompt:**
```
Analyze the git history of this repository. Find:
1. Hotspots: files that change most frequently (top 20)
2. Temporal coupling: files that consistently change together in the
   same commits (top 10 pairs)
3. Bug-fix density: files that appear most in commits containing
   "fix", "bug", "patch", "hotfix" in the message (top 15)
4. Ownership diffusion: files touched by the most distinct authors
5. Recent activity: directories with the most changes in the last 30 days
6. Commit message patterns: conventional commits? ticket references?
7. Branch naming patterns from recent branches
```

**Tools:** `Bash(git:*)`
**Model:** sonnet
**Schema:** Returns structured forensics data

### Agent: patterns

**Purpose:** What architectural patterns and conventions exist?

**Prompt:**
```
Examine this codebase for architectural patterns and conventions. Look for:
1. Design patterns in use (repository, service layer, MVC, etc.)
2. Error handling patterns (custom error classes, error middleware, etc.)
3. Import conventions (barrel exports, path aliases, absolute vs relative)
4. Naming conventions (file naming, variable naming, function naming)
5. State management approach
6. Authentication/authorization patterns
7. Testing patterns (file organization, mocking approach, fixtures)
8. Configuration management (env vars, config files, feature flags)

For each pattern found, cite the specific files that demonstrate it.
Do NOT invent patterns. Only report what you can prove exists.
```

**Tools:** `Read,Bash(find:*),Bash(grep:*),Glob`
**Model:** sonnet
**Schema:** Returns `{ patterns: [{ name, type, evidence_files, description, is_consistent }] }`

### Agent: tooling

**Purpose:** What linters, formatters, and hooks enforce rules?

**Prompt:**
```
Find every code quality tool configured in this project. For each tool:
- What is it? (ESLint, Prettier, ruff, mypy, etc.)
- Where is its config? (file path)
- What rules does it enforce? (summary, not exhaustive)
- Is it enforced in CI? (check CI config)
- Are there pre-commit hooks?

These tools represent rules that should NOT go in CLAUDE.md because they
are already enforced deterministically.
```

**Tools:** `Read,Bash(find:*),Bash(cat:*),Bash(ls:*)`
**Model:** haiku
**Schema:** Returns `{ tools: [{ name, config_path, enforced_in_ci, has_pre_commit }] }`

### Agent: docs-scanner

**Purpose:** What documentation already exists?

**Prompt:**
```
Find and summarize all existing documentation in this repo:
- README.md (main and per-package)
- CONTRIBUTING.md
- Architecture Decision Records (ADRs)
- docs/ directory contents
- API documentation
- Inline documentation patterns
- Existing CLAUDE.md or AI config files (read in full)

For each doc, provide: path, type, and a 2-sentence summary.
Identify which conventions are documented vs undocumented.
```

**Tools:** `Read,Bash(find:*),Bash(head:*),Bash(wc:*)`
**Model:** haiku
**Schema:** Returns `{ documents: [{ path, type, summary }], documented_conventions, undocumented_gaps }`

### Agent: security-scan

**Purpose:** What files need protection?

**Prompt:**
```
Scan for files that should be protected from AI agent modification:
1. Files containing secrets or credentials (.env, *.pem, *.key)
2. Migration files (database schemas that shouldn't be edited directly)
3. Lock files (package-lock.json, Cargo.lock, etc.)
4. Generated files (don't edit source of truth)
5. CI/CD configs (dangerous if modified incorrectly)
6. Security-critical code (auth, crypto, permissions)

For each, explain why it should be protected and what the safe
alternative workflow is.
```

**Tools:** `Read,Bash(find:*),Bash(grep:*),Bash(ls:*)`
**Model:** haiku
**Schema:** Returns `{ protected_files: [{ path_pattern, reason, safe_alternative }] }`

### Agent: module-analyzer (runs per module)

**Purpose:** Deep analysis of each major module/package.

For monorepos or projects with 3+ top-level directories, this agent runs once per module:

**Prompt (per module):**
```
Analyze the module at {module_path}. Determine:
1. Purpose (one sentence)
2. Key entry points
3. Dependencies on other modules in this repo
4. Patterns specific to this module (vs project-wide patterns)
5. Build/test commands specific to this module
6. Any gotchas or non-obvious behaviors
7. Domain terminology used in this module
```

**Tools:** `Read,Bash(find:*),Bash(grep:*),Bash(cat:*)`
**Model:** sonnet
**Schema:** Returns `ModuleAnalysis` per module

### Parallel Execution and Failure Handling

Phase 1 runs in two stages:

**Stage 1:** All 8 core agents run in parallel. After completion, the pipeline checks for failures:
- **Critical agents** (`identity`, `structure-scout`): if either fails, the phase aborts with a Claude-powered diagnosis
- **Systemic failure** (3+ agents failed): aborts with diagnosis
- **1-2 non-critical failures**: warns but continues with partial results
- The phase is only marked complete if the above checks pass

**Stage 2:** Based on the structure scout's map, deep-dive agents spawn for each important directory (parallel batches of 8).

On re-run after a failure, `run_agent` skips agents whose findings files already exist. Only the failed agents are retried.

```bash
# lib/gather.sh — simplified

gather_evidence() {
    if is_phase_complete "gather" && [[ "$FORCE" != "true" ]]; then
        return 0
    fi

    # Stage 1: 8 core agents in parallel
    run_agents_parallel \
        "run_agent identity '...' '$schemas/identity.json' '...' haiku" \
        "run_agent commands '...' '$schemas/commands.json' '...' haiku" \
        "run_agent git-forensics '...' '$schemas/git-forensics.json' '...' sonnet" \
        "run_agent patterns '...' '$schemas/patterns.json' '...' sonnet" \
        "run_agent tooling '...' '$schemas/tooling.json' '...' haiku" \
        "run_agent docs-scanner '...' '$schemas/docs.json' '...' haiku" \
        "run_agent security-scan '...' '$schemas/security.json' '...' haiku" \
        "run_agent structure-scout '...' '$schemas/structure-scout.json' '...' sonnet" \
        || true

    # Check for critical failures before proceeding
    local failed_agents=($(get_failed_agents identity commands git-forensics ...))
    # Abort if identity or structure-scout failed, or if 3+ agents failed
    # Diagnose failures with Claude and exit

    # Stage 2: deep-dive agents per important directory
    run_deep_dive_agents || log_warn "Some deep-dive agents failed (non-fatal)"

    mark_phase_complete "gather"
}
```

---

## 4. Phase 2: ASK — Developer Interview

Interactive terminal questions for knowledge that code analysis can't provide.

Five questions, each using the `ask_question` helper which supports proposed answers (from Phase 1 findings) with Enter-to-accept:

```bash
# lib/ask.sh

ask_developer() {
    # Skip if already complete or non-interactive
    # When piped from curl, reads from /dev/tty instead of stdin

    ask_question purpose "In one sentence, what does this project do?" "$identity_desc"
    ask_question deploy  "How is this deployed?"
    ask_question never_do "What should Claude NEVER do?"
    ask_question mistakes "What trips up new developers on this project?"
    ask_question extra   "Anything else important?"

    echo "$answers" > "$WORK_DIR/developer-answers.json"
    mark_phase_complete "ask"
}
```

---

## 5. Phase 3: RESEARCH — Domain & MCP Discovery

Two agents that use Claude's web search capability.

### Agent: domain-researcher

```bash
run_agent domain-research \
    "The project is: $(jq -r '.project_purpose' "$WORK_DIR/developer-answers.json").
     Tech stack: $(jq -r '.frameworks | map(.name) | join(", ")' "$WORK_DIR/findings/identity.json").

     Research the business domain for:
     1. Industry-specific terminology that maps to code concepts
     2. Common architectural patterns in this domain
     3. Best practices for the detected frameworks (specific versions)
     4. Common pitfalls developers encounter in this domain
     Be concrete and practical." \
    schemas/domain-research.json \
    "Read,WebSearch" \
    sonnet
```

### Agent: mcp-discoverer

```bash
run_agent mcp-discovery \
    "Find MCP servers useful for developing this project.
     Tech stack: ${tech_stack}
     Use the MCP registry API: WebFetch https://registry.modelcontextprotocol.io/v0.1/servers?...
     Always recommend context7 (library docs) and relevant database servers.
     Keep recommendations to 3-8 highly relevant servers." \
    schemas/mcp-recommendations.json \
    "Read,WebSearch,WebFetch" \
    sonnet
```

---

## 6. Phase 4: SYNTHESIZE — The Heavy Thinking

Two focused `claude -p` calls using the 1M context model (default: `sonnet[1m]`). Splitting into two passes lets each focus deeply rather than trying to produce everything at once.

**Pass 1 (Documentation):** Generates root CLAUDE.md and all subdirectory CLAUDE.md files. Receives full findings from all phases plus condensed module analyses.

**Pass 2 (Tooling):** Generates skills, hooks, subagents, MCP server configurations, and settings.json wiring. Receives the generated CLAUDE.md from Pass 1 as source of truth, plus focused findings relevant to tooling.

Each pass includes retry logic (up to 3 attempts) for transient API errors on large-context calls. If synthesis fails after retries, `diagnose_phase_failure` explains the error to the user. On re-run, gather/ask/research phases are skipped (already marked complete).

```bash
# lib/synthesize.sh — simplified

synthesize() {
    # Pass 1: CLAUDE.md files
    build_docs_context "$docs_context"       # all core findings + condensed modules
    run_synthesis_pass "docs" ... || return 1

    # Pass 2: Skills, hooks, subagents
    build_tooling_context "$tooling_context"  # generated CLAUDE.md + tooling findings
    run_synthesis_pass "tooling" ... || return 1

    # Merge both passes into final output.json
    merge_synthesis_passes
    mark_phase_complete "synthesize"
}
```

### The Synthesizer Prompt (`prompts/synthesizer.md`)

This is the most important prompt in the entire system. It must produce:

```markdown
You are an expert at creating Claude Code configurations. You receive
exhaustive analysis of a codebase from multiple specialist agents and
must condense it into optimal Claude Code artifacts.

## Your outputs

1. **CLAUDE.md** (root): Comprehensive (250-400 lines for a real project).
   Every line must trace to evidence from the findings.
   Never duplicate linter rules. Every prohibition must include an alternative.

2. **Sub-directory CLAUDE.md files**: For modules with distinct
   conventions. Focused on what's specific to that directory.

3. **Skills**: One per distinct functional area (e.g., api-development,
   database-migrations, frontend-components). Each must have:
   - YAML frontmatter with name and description (including trigger + negative scope)
   - Codebase-specific file references (>3)
   - A concrete verification step
   - Under 300 lines

4. **Hooks**: Only for detected tooling. Each hook script must:
   - Use set -euo pipefail
   - Read JSON from stdin
   - Handle empty input gracefully
   - Use exit 2 for blocking (security), exit 0 for non-blocking

5. **Subagents**: For complex recurring workflows (code review,
   deployment, etc.). Must have frontmatter with name, description,
   and appropriate tool restrictions.

6. **Commands**: For common developer actions (commit, review, deploy).

7. **MCP config**: Only servers the developer confirmed. Include
   required env vars as comments.

8. **settings.json**: Hook configurations referencing the generated scripts.

## Constraints

- CLAUDE.md: comprehensive (250-400 lines for a real project), no generic phrases
- Skills: codebase-specific, minimum 3 real file references, no generic advice
- Don't include rules that linters/formatters already enforce
- Reference real files in the codebase, not hypothetical paths
- Every "Don't do X" must include "Do Y instead"
```

---

## 7. Phase 5: VALIDATE & WRITE

### Validation

Run the validation scripts on generated skills and subagents:

Validation checks:
- **CLAUDE.md:** minimum length (100+ lines), zero generic phrases, must contain code blocks, prohibitions must include alternatives
- **Skills** (via `scripts/validate-skill.sh`): frontmatter format, minimum 3 codebase file references, verification section, no generic phrases
- **Hooks:** shebang + `set -euo pipefail`, reads JSON from stdin, matching settings.json wiring
- **Subagents** (via `scripts/validate-subagent.sh`): frontmatter, tool scoping, minimum 3 file references

If validation fails, a **revision agent** automatically fixes the failing skills/hooks and re-validates. Only the failed artifacts are revised; passing ones are preserved.

### Write Output

Artifacts are written to disk via `lib/merge.sh` with safe merge behavior (see section 8).

---

## 8. Merge Strategy

```bash
# lib/merge.sh

backup_existing() {
    local backup_dir="$WORK_DIR/backups/$(date -Iseconds)"
    mkdir -p "$backup_dir"

    # Backup files we'll overwrite
    for f in CLAUDE.md; do
        [[ -f "$f" ]] && cp "$f" "$backup_dir/" && log_info "Backed up $f"
    done
    [[ -f .claude/settings.json ]] && cp .claude/settings.json "$backup_dir/"
}

merge_settings() {
    local output="$1"
    local generated
    generated=$(jq '.settings_json' "$output")

    if [[ -f .claude/settings.json ]]; then
        # Deep merge: generated hooks are ADDED, existing hooks preserved
        local existing
        existing=$(cat .claude/settings.json)
        jq -s '.[0] * .[1]' <(echo "$existing") <(echo "$generated") > .claude/settings.json
        log_success "Merged into existing .claude/settings.json"
    else
        mkdir -p .claude
        echo "$generated" > .claude/settings.json
        log_success "Wrote .claude/settings.json"
    fi
}
```

**Rules:**
- `CLAUDE.md`: Always overwrite (backed up)
- `.claude/settings.json`: Deep merge (add hooks, preserve existing)
- `.claude/skills/*`: Only create new skills. Never overwrite existing.
- `.claude/hooks/*`: Only create new hooks. Never overwrite existing.
- `.claude/agents/*`: Only create new agents. Never overwrite existing.

---

## 9. CLI Interface

```bash
# ultrainit.sh

usage() {
    cat <<EOF
ultrainit — Deep codebase analysis for Claude Code configuration

Usage: ultrainit.sh [OPTIONS] [PATH]

Options:
  --non-interactive    Skip developer questions (for CI/headless)
  --force              Rerun all agents (ignore cached findings)
  --overwrite          Remove existing config before analysis (backs up first). Implies --force.
  --model MODEL        Model for synthesis (default: sonnet[1m])
  --budget DOLLARS     Total budget for the entire run (default: 100.00).
                       Automatically divided: 50% gather, 10% research, 30% synthesis, 10% validation.
  --skip-research      Skip web research phase
  --skip-mcp           Skip MCP server discovery only
  --dry-run            Run analysis but don't write files
  --verbose            Show agent stderr in terminal
  -h, --help           Show this help

Examples:
  ultrainit.sh                            # Interactive, current dir
  ultrainit.sh /path/to/project           # Analyze a specific project
  ultrainit.sh --non-interactive          # Headless mode for CI
  ultrainit.sh --overwrite                # Fresh generation, remove old config
  ultrainit.sh --model 'opus[1m]'         # Use Opus 1M for synthesis

Environment:
  ULTRAINIT_MODEL      Default model for gather agents (default: sonnet)
  ULTRAINIT_BUDGET     Total budget in USD (default: 100.00)
EOF
}
```

---

## 10. Cost Model

| Phase | Agents | Model | Estimated Cost |
|---|---|---|---|
| 1: Gather (core) | 4× haiku, 4× sonnet | Mixed | $2–5 |
| 1: Gather (deep-dives) | 30-60× sonnet | sonnet | $20–40 |
| 2: Ask | 0 (no LLM) | — | $0 |
| 3: Research | 2× sonnet | sonnet | $1–3 |
| 4: Synthesize | 2× sonnet[1m] | Heavy | $4–10 |
| 5: Validate/Revise | 0–1× sonnet | sonnet | $0–1 |
| **Total** | | | **$30–60** |

With `--model 'opus[1m]'` for synthesis: $50–100 total.

The total budget (`--budget`, default $100) is automatically divided across phases (50% gather, 10% research, 30% synthesis, 10% validation) and split equally among agents within each phase. `--max-budget-usd` on each `claude -p` call prevents individual agent runaway.

---

## 11. Cross-Platform Compatibility

The script requires bash and the following external tools, all checked at startup with platform-specific install instructions:

| Tool | Purpose |
|------|---------|
| `claude` | All agent calls |
| `jq` | JSON processing throughout |
| `git` | Git forensics agent, history analysis |
| `bc` | Budget arithmetic calculations |
| `mktemp` | Safe temporary file/directory creation |
| `sed` | Text processing in synthesis/validation |
| `awk` | Text processing in config/validation |
| `grep` | Pattern matching throughout |

Additionally:
- `claude auth status` is checked to verify authentication (no API cost)
- On Windows, the script detects if running outside bash (CMD/PowerShell) and warns with instructions to use Git Bash
- Unknown platforms trigger a warning with guidance

For Windows: the script runs in Git Bash (included with Git for Windows) or WSL.

---

## 12. Testing & Quality Measurement

### Built-in Validation

Every run includes automated quality checks (Phase 5):

**CLAUDE.md:** minimum length (100+ lines), zero generic phrases ("best practice", "clean code", etc.), must contain code blocks or command tables, prohibitions must include alternatives.

**Skills** (`scripts/validate-skill.sh`): frontmatter (kebab-case name, description with trigger phrases and negative scope, no angle brackets), body (minimum 3 codebase-specific file references, verification section), no generic programming phrases.

**Hooks:** shebang + `set -euo pipefail`, reads JSON from stdin, matching settings.json wiring.

**Subagents** (`scripts/validate-subagent.sh`): frontmatter (name, description with trigger phrases), tool scoping matches purpose, minimum 3 codebase-specific references.

Failed artifacts are automatically revised and re-validated.

---

## 13. Distribution

### curl-pipe-bash (recommended)

```bash
curl -sL https://github.com/joelbarmettlerUZH/ultrainit.sh/releases/latest/download/ultrainit.sh | bash
```

GitHub Releases contain a bundled single-file `ultrainit.sh` that self-extracts all libs, schemas, prompts, and scripts to a temp directory.

### Clone and run

```bash
git clone https://github.com/joelbarmettlerUZH/ultrainit.sh.git
cd ultrainit.sh
./ultrainit.sh /path/to/your/project
```