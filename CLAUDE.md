# ultrainit

**A shell-native tool that uses Claude Code itself to deeply analyze any codebase and generate a complete Claude Code configuration — CLAUDE.md, skills, hooks, subagents, commands, and MCP servers.**

No Python. No npm. No dependencies beyond `claude` and standard Unix tools. Runs on macOS, Linux, and Windows (Git Bash / WSL).

```bash
# One command. Any codebase.
curl -sL https://raw.githubusercontent.com/joelbarmettlerUZH/ultrainit/main/ultrainit.sh | bash
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
│  │ domain   │ │framework │                              │
│  │ research │ │ research │                              │
│  └────┬─────┘ └────┬─────┘                              │
│       │             │                                    │
│  Phase 4: SYNTHESIZE  (one heavy claude -p call)        │
│  ┌──────────────────────────────────────────────────┐    │
│  │  All findings + developer answers + research      │    │
│  │  → condensed into final CLAUDE.md, skills, etc.   │    │
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

- **Zero dependencies.** If you have `claude` installed, you have everything.
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
├── ultrainit.sh                   # Main entry point
├── lib/
│   ├── config.sh                   # Configuration and defaults
│   ├── agent.sh                    # Agent spawning helpers
│   ├── gather.sh                   # Phase 1: evidence gathering agents
│   ├── ask.sh                      # Phase 2: interactive questions
│   ├── research.sh                 # Phase 3: web research agents
│   ├── synthesize.sh               # Phase 4: synthesis agent
│   ├── validate.sh                 # Phase 5: validation + write
│   ├── merge.sh                    # Merge with existing .claude/ config
│   ├── mcp.sh                      # MCP server discovery
│   └── utils.sh                    # Logging, progress, JSON helpers
├── schemas/                        # JSON schemas for structured output
│   ├── identity.json
│   ├── commands.json
│   ├── git-forensics.json
│   ├── patterns.json
│   ├── module-analysis.json
│   ├── domain-research.json
│   ├── mcp-recommendations.json
│   ├── claude-md.json
│   ├── skill.json
│   └── hook.json
├── prompts/                        # System prompts for each agent
│   ├── identity.md
│   ├── commands.md
│   ├── git-forensics.md
│   ├── patterns.md
│   ├── module-analyzer.md
│   ├── domain-researcher.md
│   ├── mcp-discoverer.md
│   ├── synthesizer.md
│   └── reviewer.md
├── templates/                      # Jinja-like templates (envsubst)
│   ├── hook-autoformat.sh.tmpl
│   ├── hook-typecheck.sh.tmpl
│   ├── hook-file-guard.sh.tmpl
│   └── hook-force-push-block.sh.tmpl
├── scripts/
│   ├── validate-skill.sh           # Skill quality validator
│   └── validate-subagent.sh        # Subagent quality validator
├── install.sh                      # Self-installer (curl-pipe-bash)
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
    local model="${5:-sonnet}" # Model alias
    local output_file="$WORK_DIR/findings/${name}.json"

    # Skip if findings already exist (resumability)
    if [[ -f "$output_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Skipping $name (findings exist). Use --force to rerun."
        return 0
    fi

    local schema
    schema=$(cat "$schema_file")

    local system_prompt_file="$SCRIPT_DIR/prompts/${name}.md"
    local system_prompt_flag=""
    if [[ -f "$system_prompt_file" ]]; then
        system_prompt_flag="--append-system-prompt-file $system_prompt_file"
    fi

    log_progress "Running agent: $name (model: $model)"

    claude -p "$prompt" \
        --model "$model" \
        --output-format json \
        --json-schema "$schema" \
        --allowedTools "$allowed_tools" \
        $system_prompt_flag \
        --max-budget-usd "$AGENT_BUDGET" \
        2>>"$WORK_DIR/logs/${name}.stderr" \
        | jq -r '.structured_output // .result' \
        > "$output_file"

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Agent $name failed (exit $exit_code). See $WORK_DIR/logs/${name}.stderr"
        return 1
    fi

    log_success "Agent $name completed → $output_file"
}

# Run multiple agents in parallel
run_agents_parallel() {
    local pids=()
    for agent_call in "$@"; do
        eval "$agent_call" &
        pids+=($!)
    done

    local failures=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failures=$((failures + 1))
    done

    if [[ $failures -gt 0 ]]; then
        log_warn "$failures agent(s) failed. Check logs in $WORK_DIR/logs/"
    fi
    return $failures
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
│   ├── modules/
│   │   ├── src-api.json
│   │   ├── src-web.json
│   │   └── packages-shared.json
│   ├── domain-research.json
│   ├── framework-research.json
│   └── mcp-recommendations.json
├── developer-answers.json
├── synthesis/          # Combined/condensed outputs
│   ├── claude-md.md
│   ├── skills/
│   │   └── *.json
│   ├── hooks/
│   │   └── *.json
│   ├── subagents/
│   │   └── *.json
│   └── mcp-config.json
├── logs/               # stderr from each agent
│   ├── identity.stderr
│   ├── commands.stderr
│   └── ...
├── backups/            # Backups of overwritten files
│   └── 2026-04-04T14:30:00/
│       ├── CLAUDE.md
│       └── .claude/settings.json
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

### Parallel Execution

```bash
# lib/gather.sh

gather_evidence() {
    log_phase "Phase 1: Gathering evidence"

    run_agents_parallel \
        'run_agent identity "..." schemas/identity.json "Read,Bash(find:*),Bash(ls:*),Bash(cat:*),Bash(head:*)" haiku' \
        'run_agent commands "..." schemas/commands.json "Read,Bash(find:*),Bash(cat:*),Bash(grep:*),Bash(jq:*)" haiku' \
        'run_agent git-forensics "..." schemas/git-forensics.json "Bash(git:*)" sonnet' \
        'run_agent patterns "..." schemas/patterns.json "Read,Bash(find:*),Bash(grep:*),Glob" sonnet' \
        'run_agent tooling "..." schemas/tooling.json "Read,Bash(find:*),Bash(cat:*),Bash(ls:*)" haiku' \
        'run_agent docs-scanner "..." schemas/docs.json "Read,Bash(find:*),Bash(head:*),Bash(wc:*)" haiku' \
        'run_agent security-scan "..." schemas/security.json "Read,Bash(find:*),Bash(grep:*),Bash(ls:*)" haiku'

    # Then run module analyzers (parallel, one per detected module)
    local modules
    modules=$(jq -r '.packages[]?.path // empty' "$WORK_DIR/findings/identity.json" 2>/dev/null)
    if [[ -z "$modules" ]]; then
        modules=$(find . -maxdepth 1 -type d -not -name '.*' -not -name node_modules | tail -n +2)
    fi

    local module_calls=()
    for mod in $modules; do
        local safe_name
        safe_name=$(echo "$mod" | tr '/' '-' | tr '.' '_')
        module_calls+=("run_agent module-${safe_name} \"Analyze module at ${mod}\" schemas/module-analysis.json \"Read,Bash(find:*),Bash(grep:*),Bash(cat:*)\" sonnet")
    done

    if [[ ${#module_calls[@]} -gt 0 ]]; then
        run_agents_parallel "${module_calls[@]}"
    fi

    mark_phase_complete "gather"
}
```

---

## 4. Phase 2: ASK — Developer Interview

Interactive terminal questions for knowledge that code analysis can't provide.

```bash
# lib/ask.sh

ask_developer() {
    log_phase "Phase 2: Developer interview"

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        log_info "Non-interactive mode. Skipping developer questions."
        echo '{}' > "$WORK_DIR/developer-answers.json"
        mark_phase_complete "ask"
        return
    fi

    local answers="{}"

    echo ""
    echo "━━━ I have a few questions that code analysis can't answer ━━━"
    echo ""

    # Question 1: Project purpose
    local identity_desc
    identity_desc=$(jq -r '.description // empty' "$WORK_DIR/findings/identity.json" 2>/dev/null)
    echo "I detected this project might be: ${identity_desc:-'(unknown)'}"
    read -rp "What is the primary purpose of this project? (Enter to accept, or type your own): " purpose
    purpose="${purpose:-$identity_desc}"
    answers=$(echo "$answers" | jq --arg v "$purpose" '.project_purpose = $v')

    # Question 2: Deployment target
    read -rp "Where is this deployed? (e.g., Vercel, AWS, self-hosted Docker): " deploy
    answers=$(echo "$answers" | jq --arg v "$deploy" '.deployment_target = $v')

    # Question 3: External services
    read -rp "External services/APIs this integrates with? (comma-separated, or Enter to skip): " services
    answers=$(echo "$answers" | jq --arg v "$services" '.external_services = $v')

    # Question 4: What Claude should NEVER do
    echo ""
    echo "What should Claude NEVER do in this codebase?"
    echo "(e.g., 'never modify migrations directly', 'never bypass auth')"
    read -rp "> " never_do
    answers=$(echo "$answers" | jq --arg v "$never_do" '.never_do = $v')

    # Question 5: Common mistakes
    read -rp "Common mistakes new developers make? (or Enter to skip): " mistakes
    answers=$(echo "$answers" | jq --arg v "$mistakes" '.common_mistakes = $v')

    # Question 6: Anything else
    read -rp "Anything else Claude should know about this project? (or Enter to skip): " extra
    answers=$(echo "$answers" | jq --arg v "$extra" '.additional_context = $v')

    echo "$answers" > "$WORK_DIR/developer-answers.json"
    log_success "Developer answers saved"
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
    "This project uses these dependencies and services:
     $(jq -r '.frameworks | map(.name) | join(", ")' "$WORK_DIR/findings/identity.json")
     External services: $(jq -r '.external_services' "$WORK_DIR/developer-answers.json")

     Search the MCP server registry at https://registry.modelcontextprotocol.io
     and find MCP servers that would be useful for developing this project.
     For each recommended server: provide the npm/pip package name, what it does,
     and how to configure it in .claude/mcp.json.
     Only recommend servers that are directly relevant to the detected stack." \
    schemas/mcp-recommendations.json \
    "Read,WebSearch,Bash(curl:*)" \
    sonnet
```

---

## 6. Phase 4: SYNTHESIZE — The Heavy Thinking

One large `claude -p` call with the `opus` or `sonnet` model that receives ALL findings and produces the final artifacts.

```bash
# lib/synthesize.sh

synthesize() {
    log_phase "Phase 4: Synthesis (this is the expensive step)"

    # Concatenate all findings into one context document
    local context=""
    context+="=== PROJECT IDENTITY ===\n$(cat "$WORK_DIR/findings/identity.json")\n\n"
    context+="=== COMMANDS ===\n$(cat "$WORK_DIR/findings/commands.json")\n\n"
    context+="=== GIT FORENSICS ===\n$(cat "$WORK_DIR/findings/git-forensics.json")\n\n"
    context+="=== PATTERNS ===\n$(cat "$WORK_DIR/findings/patterns.json")\n\n"
    context+="=== TOOLING ===\n$(cat "$WORK_DIR/findings/tooling.json")\n\n"
    context+="=== DOCUMENTATION ===\n$(cat "$WORK_DIR/findings/docs-scanner.json")\n\n"
    context+="=== SECURITY ===\n$(cat "$WORK_DIR/findings/security-scan.json")\n\n"

    # Module analyses
    for f in "$WORK_DIR/findings/module-"*.json; do
        [[ -f "$f" ]] && context+="=== MODULE: $(basename "$f" .json) ===\n$(cat "$f")\n\n"
    done

    # Developer answers
    context+="=== DEVELOPER ANSWERS ===\n$(cat "$WORK_DIR/developer-answers.json")\n\n"

    # Research (if available)
    [[ -f "$WORK_DIR/findings/domain-research.json" ]] && \
        context+="=== DOMAIN RESEARCH ===\n$(cat "$WORK_DIR/findings/domain-research.json")\n\n"
    [[ -f "$WORK_DIR/findings/mcp-discovery.json" ]] && \
        context+="=== MCP RECOMMENDATIONS ===\n$(cat "$WORK_DIR/findings/mcp-discovery.json")\n\n"

    # Write context to a temp file (too large for inline prompt)
    echo -e "$context" > "$WORK_DIR/synthesis-context.txt"

    # The synthesis prompt
    cat "$WORK_DIR/synthesis-context.txt" | claude -p \
        --model "${SYNTH_MODEL:-sonnet}" \
        --output-format json \
        --json-schema "$(cat schemas/synthesis-output.json)" \
        --allowedTools "Read" \
        --append-system-prompt-file prompts/synthesizer.md \
        --max-budget-usd "$SYNTH_BUDGET" \
        2>>"$WORK_DIR/logs/synthesis.stderr" \
        | jq -r '.structured_output // .result' \
        > "$WORK_DIR/synthesis/output.json"

    log_success "Synthesis complete"
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

1. **CLAUDE.md** (root): Under 150 lines. Only rules that apply to >30%
   of sessions. Every line must trace to evidence from the findings.
   Follow the WHAT/WHY/HOW framework. Never duplicate linter rules.
   Every prohibition must include an alternative.

2. **Sub-directory CLAUDE.md files**: Only for modules with distinct
   conventions. Under 60 lines each.

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

- CLAUDE.md: <150 lines, <100 instructions, <2000 tokens
- Skills: <300 lines each, codebase-specific, no generic advice
- Don't include rules that linters/formatters already enforce
- Reference real files in the codebase, not hypothetical paths
- Every "Don't do X" must include "Do Y instead"
```

---

## 7. Phase 5: VALIDATE & WRITE

### Validation

Run the validation scripts on generated skills and subagents:

```bash
validate_artifacts() {
    log_phase "Phase 5a: Validating artifacts"

    local errors=0

    # Validate each generated skill
    local skills
    skills=$(jq -r '.skills[]?.name // empty' "$WORK_DIR/synthesis/output.json")
    for skill_name in $skills; do
        local skill_dir="$WORK_DIR/synthesis/skills/$skill_name"
        mkdir -p "$skill_dir"
        jq -r ".skills[] | select(.name == \"$skill_name\") | .content" \
            "$WORK_DIR/synthesis/output.json" > "$skill_dir/SKILL.md"

        if ! bash "$SCRIPT_DIR/scripts/validate-skill.sh" "$skill_dir/SKILL.md"; then
            errors=$((errors + 1))
        fi
    done

    # Validate CLAUDE.md quality
    local claude_md_lines
    claude_md_lines=$(jq -r '.claude_md' "$WORK_DIR/synthesis/output.json" | wc -l)
    if [[ $claude_md_lines -gt 150 ]]; then
        log_warn "CLAUDE.md is $claude_md_lines lines (target: <150). Requesting condensation."
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        log_warn "$errors validation issues. Running revision agent..."
        run_revision_agent
    fi
}
```

### Revision Agent

If validation fails, a reviewer agent fixes the issues:

```bash
run_revision_agent() {
    local issues
    issues=$(cat "$WORK_DIR/logs/validation-issues.txt")

    cat "$WORK_DIR/synthesis/output.json" | claude -p \
        --model sonnet \
        --output-format json \
        --json-schema "$(cat schemas/synthesis-output.json)" \
        --append-system-prompt "These artifacts failed validation with these issues:
$issues

Fix all issues and return the corrected artifacts. Do NOT change
anything that passed validation." \
        --allowedTools "Read" \
        > "$WORK_DIR/synthesis/output-revised.json"

    mv "$WORK_DIR/synthesis/output-revised.json" "$WORK_DIR/synthesis/output.json"
}
```

### Write Output

```bash
write_artifacts() {
    log_phase "Phase 5b: Writing artifacts"

    local output
    output="$WORK_DIR/synthesis/output.json"

    # Backup existing files
    backup_existing

    # Write CLAUDE.md
    jq -r '.claude_md' "$output" > CLAUDE.md
    log_success "Wrote CLAUDE.md ($(wc -l < CLAUDE.md) lines)"

    # Write sub-directory CLAUDE.md files
    jq -r '.subdirectory_claude_mds | to_entries[]? | "\(.key)\t\(.value)"' "$output" | \
    while IFS=$'\t' read -r path content; do
        mkdir -p "$(dirname "$path")"
        echo "$content" > "$path/CLAUDE.md"
        log_success "Wrote $path/CLAUDE.md"
    done

    # Write skills
    jq -r '.skills[]?.name // empty' "$output" | while read -r name; do
        local dir=".claude/skills/$name"
        mkdir -p "$dir"
        jq -r ".skills[] | select(.name == \"$name\") | .content" "$output" > "$dir/SKILL.md"
        log_success "Wrote $dir/SKILL.md"
    done

    # Write hooks
    jq -r '.hooks[]?.filename // empty' "$output" | while read -r filename; do
        mkdir -p ".claude/hooks"
        jq -r ".hooks[] | select(.filename == \"$filename\") | .content" "$output" > ".claude/hooks/$filename"
        chmod +x ".claude/hooks/$filename"
        log_success "Wrote .claude/hooks/$filename"
    done

    # Write subagents
    jq -r '.subagents[]?.name // empty' "$output" | while read -r name; do
        mkdir -p ".claude/agents"
        jq -r ".subagents[] | select(.name == \"$name\") | .content" "$output" > ".claude/agents/${name}.md"
        log_success "Wrote .claude/agents/${name}.md"
    done

    # Write/merge settings.json
    merge_settings "$output"

    # Write MCP config
    if jq -e '.mcp_config' "$output" > /dev/null 2>&1; then
        merge_mcp_config "$output"
    fi

    # Add .ultrainit/ to .gitignore
    if ! grep -q '.ultrainit' .gitignore 2>/dev/null; then
        echo '.ultrainit/' >> .gitignore
    fi

    log_success "All artifacts written!"
    print_summary
}
```

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
  --model MODEL        Model for synthesis (default: sonnet)
  --budget DOLLARS     Max USD per agent call (default: 5.00)
  --synth-budget USD   Max USD for synthesis step (default: 20.00)
  --skip-research      Skip web research phase
  --skip-mcp           Skip MCP server discovery
  --dry-run            Run analysis but don't write files
  --verbose            Show agent stderr in terminal
  -h, --help           Show this help

Examples:
  ultrainit.sh                       # Interactive analysis of current dir
  ultrainit.sh /path/to/project      # Analyze a specific project
  ultrainit.sh --non-interactive     # Headless mode for CI
  ultrainit.sh --force --model opus  # Full rerun with Opus synthesis

Environment:
  ULTRATHINK_MODEL     Default model for agents (default: sonnet)
  ULTRATHINK_BUDGET    Default per-agent budget (default: 5.00)
EOF
}
```

---

## 10. Cost Model

| Phase | Agents | Model | Estimated Cost |
|---|---|---|---|
| 1: Gather | 4× haiku, 3× sonnet | Mixed | $2–8 |
| 2: Ask | 0 (no LLM) | — | $0 |
| 3: Research | 2× sonnet | sonnet | $1–4 |
| 4: Synthesize | 1× sonnet/opus | Heavy | $3–15 |
| 5: Validate/Revise | 0–1× sonnet | sonnet | $0–5 |
| **Total** | | | **$6–32** |

With `--model opus` for synthesis: $15–50 total.

The `--max-budget-usd` flag on each `claude -p` call prevents runaway spending.

---

## 11. Cross-Platform Compatibility

The script uses only POSIX-compatible constructs plus:
- `jq` (required — we check and provide install instructions)
- `claude` CLI (required)
- `date -Iseconds` (GNU coreutils or macOS `gdate`)

```bash
# lib/config.sh

check_dependencies() {
    if ! command -v claude &>/dev/null; then
        echo "ERROR: claude CLI not found. Install: https://code.claude.com/docs/en/quickstart" >&2
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq not found." >&2
        echo "  macOS:   brew install jq" >&2
        echo "  Linux:   sudo apt install jq" >&2
        echo "  Windows: choco install jq (in Git Bash)" >&2
        exit 1
    fi

    # Check claude auth
    if ! claude -p "echo ok" --bare --allowedTools "" --max-budget-usd 0.01 &>/dev/null 2>&1; then
        echo "ERROR: claude CLI not authenticated. Run: claude auth" >&2
        exit 1
    fi
}
```

For Windows: the script runs in Git Bash or WSL. Both provide the standard Unix tools we need.

---

## 12. Testing & Quality Measurement

### How We Test

| What | How |
|---|---|
| Individual agents produce valid JSON | Run each agent on fixture repos, validate output against schema with `jq` |
| Synthesis produces valid artifacts | Run full pipeline on fixtures, validate with `validate-skill.sh` and `validate-subagent.sh` |
| CLAUDE.md quality | Automated checks: line count, instruction count, linter-rule duplication, stale paths, generic phrases |
| Generated hooks work | Execute each hook with mock JSON stdin, check exit codes |
| Cross-platform | Test on macOS (zsh), Linux (bash), Windows (Git Bash) |
| Resume works | Kill script mid-run, rerun, verify it skips completed phases |

### Fixture Codebases

Four small but complete repos in `tests/fixtures/`:
- `nextjs-app/` — Next.js + TypeScript + Prisma
- `python-fastapi/` — FastAPI + SQLAlchemy + pytest
- `monorepo-turbo/` — Turborepo with 3 packages
- `rust-cli/` — Rust CLI with Cargo + GitHub Actions

Each has real git history (50+ commits) with realistic hotspot patterns.

### Quality Criteria

Every generated CLAUDE.md is checked against:

```bash
# Automated quality gate
check_claude_md_quality() {
    local file="$1"
    local errors=0

    local lines=$(wc -l < "$file")
    [[ $lines -gt 150 ]] && echo "FAIL: $lines lines (max 150)" && errors=$((errors+1))

    local generic=$(grep -ciE '(best practice|clean code|solid principle|maintainable|readable)' "$file")
    [[ $generic -gt 2 ]] && echo "FAIL: $generic generic phrases (max 2)" && errors=$((errors+1))

    local has_commands=$(grep -c '```' "$file")
    [[ $has_commands -lt 2 ]] && echo "FAIL: No command blocks found" && errors=$((errors+1))

    local dont_without_instead=$(grep -c "Don't\|Do not\|Never" "$file")
    local with_instead=$(grep -c "instead\|Use .* instead\|prefer" "$file")
    # Rough check: more prohibitions than alternatives is a smell

    return $errors
}
```

Skills are validated with `scripts/validate-skill.sh`. Subagents with `scripts/validate-subagent.sh`.

### Manual Eval Protocol

For each fixture codebase:
1. Run `ultrainit.sh` to generate config
2. Start an interactive `claude` session in the fixture project
3. Give Claude 5 standard tasks and score 0–5 on convention adherence
4. Compare scores WITH vs WITHOUT ultrainit-generated config

---

## 13. Distribution

### Option A: curl-pipe-bash (recommended for quick use)

```bash
curl -sL https://raw.githubusercontent.com/user/ultrainit/main/install.sh | bash
```

The installer clones the repo to `~/.ultrainit/` and adds `ultrainit` to PATH.

### Option B: Clone and run

```bash
git clone https://github.com/user/ultrainit.git
cd ultrainit
./ultrainit.sh /path/to/your/project
```

### Option C: Claude Code plugin

Package as a Claude Code plugin so it appears as `/ultrainit` in interactive sessions:

```
.claude/plugins/ultrainit/
├── plugin.json
├── skills/
│   └── ultrainit/SKILL.md
└── commands/
    └── ultrainit.md
```

---

## 14. Implementation Roadmap

### Week 1: Foundation

- [ ] `ultrainit.sh` — CLI skeleton with arg parsing, logging, progress
- [ ] `lib/config.sh` — Dependency checks, defaults, platform detection
- [ ] `lib/agent.sh` — `run_agent` and `run_agents_parallel` functions
- [ ] `lib/utils.sh` — Logging, JSON helpers, phase tracking
- [ ] `schemas/` — All JSON schemas for structured output
- [ ] `prompts/` — All agent system prompts
- [ ] Phase 1 (gather) with all 8 agents working end-to-end
- [ ] Phase 2 (ask) interactive questions
- [ ] Test on one fixture codebase

**Exit criteria:** Running `ultrainit.sh` on a real project produces `.ultrainit/findings/` with valid JSON from each agent.

### Week 2: Synthesis & Output

- [ ] `prompts/synthesizer.md` — The synthesis mega-prompt
- [ ] `schemas/synthesis-output.json` — Full output schema
- [ ] Phase 4 (synthesize) working end-to-end
- [ ] Phase 5 (validate & write) with quality checks
- [ ] `lib/merge.sh` — Merge with existing `.claude/` config
- [ ] `scripts/validate-skill.sh` + `validate-subagent.sh` integrated
- [ ] Test on all 4 fixture codebases

**Exit criteria:** Full pipeline produces valid CLAUDE.md + skills + hooks that pass quality checks.

### Week 3: Research, MCP & Polish

- [ ] Phase 3 (research) — Domain and framework research agents
- [ ] `lib/mcp.sh` — MCP server discovery via Claude web search
- [ ] Resume from crash (phase tracking)
- [ ] `--dry-run` mode
- [ ] Cross-platform testing (macOS, Linux, Git Bash)
- [ ] `install.sh` — curl-pipe-bash installer
- [ ] README with examples and screenshots
- [ ] Manual eval on diverse real-world repos
- [ ] Claude Code plugin packaging

**Exit criteria:** Published to GitHub. `curl | bash` installation works. All fixture repos produce high-quality output.