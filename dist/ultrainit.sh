#!/usr/bin/env bash
set -euo pipefail
#
# ultrainit — Deep codebase analysis for Claude Code configuration
# This is a bundled, self-contained version.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/joelbarmettlerUZH/ultrainit/main/ultrainit.sh | bash
#   # or with options:
#   bash <(curl -sL https://raw.githubusercontent.com/joelbarmettlerUZH/ultrainit/main/ultrainit.sh) --non-interactive /path/to/project
#

BUNDLE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ultrainit.XXXXXX")
trap 'rm -rf "$BUNDLE_DIR"' EXIT

mkdir -p "$BUNDLE_DIR"/{lib,prompts,schemas,scripts}

# ── Extract embedded files ──────────────────────────────────────
cat > "$BUNDLE_DIR/lib/agent.sh" <<'__EOF_LIB_agent__'
#!/usr/bin/env bash
# lib/agent.sh — Agent spawning helpers

# ── Cost tracking ───────────────────────────────────────────────

# Append a cost entry to the cost log
record_cost() {
    local phase="$1"
    local agent="$2"
    local cost="$3"
    local cost_file="$WORK_DIR/cost.log"
    echo "$phase|$agent|$cost" >> "$cost_file"
}

# ── Agent runner ────────────────────────────────────────────────

# Run a single claude -p agent with structured JSON output.
#
# Usage: run_agent <name> <prompt> <schema_file> <allowed_tools> [model]
#
# - Writes JSON output to $WORK_DIR/findings/<name>.json
# - Skips if findings already exist (unless FORCE=true)
# - Logs stderr to $WORK_DIR/logs/<name>.stderr
run_agent() {
    local name="$1"
    local prompt="$2"
    local schema_file="$3"
    local allowed_tools="$4"
    local model="${5:-$AGENT_MODEL}"
    local output_file="$WORK_DIR/findings/${name}.json"

    # Resumability: skip if findings exist
    if [[ -f "$output_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Skipping $name (findings exist). Use --force to rerun."
        return 0
    fi

    if [[ ! -f "$schema_file" ]]; then
        log_error "Schema file not found: $schema_file"
        return 1
    fi

    local schema
    schema=$(cat "$schema_file")

    # Build system prompt flag if a prompt file exists
    local system_prompt_flag=""
    local system_prompt_file="$SCRIPT_DIR/prompts/${name}.md"
    if [[ -f "$system_prompt_file" ]]; then
        system_prompt_flag="--append-system-prompt-file $system_prompt_file"
    fi

    log_progress "Running agent: $name (model: $model)"

    local stderr_file="$WORK_DIR/logs/${name}.stderr"

    # For large prompts, pipe via stdin to avoid "argument list too long"
    local raw_output
    local prompt_len=${#prompt}

    if [[ $prompt_len -gt 100000 ]]; then
        raw_output=$(echo "$prompt" | claude -p - \
            --model "$model" \
            --output-format json \
            --json-schema "$schema" \
            --allowedTools "$allowed_tools" \
            $system_prompt_flag \
            --max-budget-usd "$AGENT_BUDGET" \
            2>>"$stderr_file")
    else
        raw_output=$(claude -p "$prompt" \
            --model "$model" \
            --output-format json \
            --json-schema "$schema" \
            --allowedTools "$allowed_tools" \
            $system_prompt_flag \
            --max-budget-usd "$AGENT_BUDGET" \
            2>>"$stderr_file")
    fi

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_error "Agent $name failed (exit $exit_code). See $stderr_file"
        if [[ "$VERBOSE" == "true" ]]; then
            cat "$stderr_file" >&2
        fi
        return 1
    fi

    # Check for API-level errors in the response envelope
    local is_error
    is_error=$(echo "$raw_output" | jq -r '.is_error // false' 2>/dev/null)
    if [[ "$is_error" == "true" ]]; then
        log_error "Agent $name returned an error: $(echo "$raw_output" | jq -r '.result // "unknown"')"
        echo "$raw_output" >> "$stderr_file"
        return 1
    fi

    # Track cost
    local cost
    cost=$(echo "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)
    record_cost "gather" "$name" "$cost"

    # Extract structured output from claude response
    # With --json-schema, output is in .structured_output; without, in .result
    echo "$raw_output" | jq '.structured_output // .result // .' > "$output_file" 2>/dev/null

    # Validate we got valid JSON (structured_output should be an object, not a string)
    if ! jq -e 'type == "object" or type == "array"' "$output_file" >/dev/null 2>&1; then
        log_error "Agent $name did not produce structured JSON output. See $stderr_file"
        echo "Raw output: $raw_output" >> "$stderr_file"
        rm -f "$output_file"
        return 1
    fi

    log_success "Agent $name completed -> $output_file"
    return 0
}

# ── Parallel execution ──────────────────────────────────────────

# Run multiple agent calls in parallel.
#
# Each argument is a string containing a full run_agent invocation.
# We write each to a temp script to avoid eval quoting issues with
# special characters (parentheses, spaces, etc.) in paths or descriptions.
#
# Returns the number of failures (0 = all succeeded).
run_agents_parallel() {
    local pids=()
    local names=()
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ultrainit-agents.XXXXXX")

    local idx=0
    for agent_call in "$@"; do
        # Extract agent name (first arg after run_agent)
        local agent_name
        agent_name=$(echo "$agent_call" | sed -E "s/run_agent ([^ ]+).*/\1/")
        names+=("$agent_name")

        # Write the call to a temp script to avoid eval quoting issues
        local script="$tmp_dir/agent-${idx}.sh"
        cat > "$script" <<AGENT_SCRIPT
#!/usr/bin/env bash
$agent_call
AGENT_SCRIPT

        bash "$script" &
        pids+=($!)
        idx=$((idx + 1))
    done

    local failures=0
    local i=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failures=$((failures + 1))
            log_warn "Agent ${names[$i]} failed"
        fi
        i=$((i + 1))
    done

    rm -rf "$tmp_dir"

    if [[ $failures -gt 0 ]]; then
        log_warn "$failures agent(s) failed. Check logs in $WORK_DIR/logs/"
    fi
    return $failures
}

__EOF_LIB_agent__

cat > "$BUNDLE_DIR/lib/ask.sh" <<'__EOF_LIB_ask__'
#!/usr/bin/env bash
# lib/ask.sh — Phase 2: Interactive developer questions

ask_developer() {
    log_phase "Phase 2: Developer interview"

    if is_phase_complete "ask" && [[ "$FORCE" != "true" ]]; then
        log_info "Phase 2 already complete. Use --force to rerun."
        return 0
    fi

    local answers_file="$WORK_DIR/developer-answers.json"

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        log_info "Non-interactive mode. Skipping developer questions."
        echo '{}' > "$answers_file"
        mark_phase_complete "ask"
        return 0
    fi

    local answers="{}"

    echo ""
    echo "━━━ I have a few questions that code analysis can't answer ━━━"
    echo ""

    # Question 1: Project purpose
    local identity_desc=""
    if [[ -f "$WORK_DIR/findings/identity.json" ]]; then
        identity_desc=$(jq -r '.description // empty' "$WORK_DIR/findings/identity.json" 2>/dev/null)
    fi

    if [[ -n "$identity_desc" ]]; then
        echo "I detected this project might be: ${identity_desc}"
        read -rp "What is the primary purpose of this project? (Enter to accept, or type your own): " purpose
        purpose="${purpose:-$identity_desc}"
    else
        read -rp "What is the primary purpose of this project? " purpose
    fi
    answers=$(echo "$answers" | jq --arg v "$purpose" '.project_purpose = $v')

    # Question 2: Deployment target
    echo ""
    read -rp "Where is this deployed? (e.g., Vercel, AWS, self-hosted Docker, or Enter to skip): " deploy
    answers=$(echo "$answers" | jq --arg v "$deploy" '.deployment_target = $v')

    # Question 3: External services
    echo ""
    read -rp "External services/APIs this integrates with? (comma-separated, or Enter to skip): " services
    answers=$(echo "$answers" | jq --arg v "$services" '.external_services = $v')

    # Question 4: What Claude should NEVER do
    echo ""
    echo "What should Claude NEVER do in this codebase?"
    echo "(e.g., 'never modify migrations directly', 'never bypass auth')"
    read -rp "> " never_do
    answers=$(echo "$answers" | jq --arg v "$never_do" '.never_do = $v')

    # Question 5: Common mistakes
    echo ""
    read -rp "Common mistakes new developers make? (or Enter to skip): " mistakes
    answers=$(echo "$answers" | jq --arg v "$mistakes" '.common_mistakes = $v')

    # Question 6: Anything else
    echo ""
    read -rp "Anything else Claude should know about this project? (or Enter to skip): " extra
    answers=$(echo "$answers" | jq --arg v "$extra" '.additional_context = $v')

    echo ""
    echo "$answers" > "$answers_file"
    log_success "Developer answers saved"
    mark_phase_complete "ask"
}

__EOF_LIB_ask__

cat > "$BUNDLE_DIR/lib/config.sh" <<'__EOF_LIB_config__'
#!/usr/bin/env bash
# lib/config.sh — Dependency checks, defaults, platform detection

# ── Defaults (overridable via env or CLI flags) ─────────────────

FORCE="${FORCE:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_RESEARCH="${SKIP_RESEARCH:-false}"
SKIP_MCP="${SKIP_MCP:-false}"
OVERWRITE="${OVERWRITE:-false}"

AGENT_MODEL="${ULTRAINIT_MODEL:-sonnet}"
AGENT_BUDGET="${ULTRAINIT_BUDGET:-5.00}"
SYNTH_MODEL="${SYNTH_MODEL:-sonnet[1m]}"
SYNTH_BUDGET="${SYNTH_BUDGET:-20.00}"

# ── Platform detection ──────────────────────────────────────────

detect_platform() {
    case "$(uname -s)" in
        Darwin)  PLATFORM="macos" ;;
        Linux)   PLATFORM="linux" ;;
        MINGW*|MSYS*|CYGWIN*)  PLATFORM="windows" ;;
        *)       PLATFORM="unknown" ;;
    esac
    export PLATFORM
}

# ── Dependency checks ──────────────────────────────────────────

check_dependencies() {
    local missing=0

    if ! command -v claude &>/dev/null; then
        log_error "claude CLI not found. Install: https://docs.anthropic.com/en/docs/claude-code/overview"
        missing=1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq not found."
        case "$PLATFORM" in
            macos)   log_error "  Install: brew install jq" ;;
            linux)   log_error "  Install: sudo apt install jq  (or your package manager)" ;;
            windows) log_error "  Install: choco install jq  (in Git Bash)" ;;
        esac
        missing=1
    fi

    if [[ $missing -ne 0 ]]; then
        exit 1
    fi
}

# ── Working directory setup ─────────────────────────────────────

setup_work_dir() {
    local target_dir="$1"
    WORK_DIR="${target_dir}/.ultrainit"
    export WORK_DIR

    mkdir -p "$WORK_DIR"/{findings/modules,synthesis/skills,synthesis/hooks,synthesis/subagents,logs,backups}

    # Add .ultrainit/ to .gitignore if not present
    if [[ -f "${target_dir}/.gitignore" ]]; then
        if ! grep -q '\.ultrainit' "${target_dir}/.gitignore" 2>/dev/null; then
            echo '.ultrainit/' >> "${target_dir}/.gitignore"
        fi
    else
        echo '.ultrainit/' > "${target_dir}/.gitignore"
    fi

    # Initialize state file if missing
    if [[ ! -f "$WORK_DIR/state.json" ]]; then
        echo '{}' > "$WORK_DIR/state.json"
    fi
}

__EOF_LIB_config__

cat > "$BUNDLE_DIR/lib/gather.sh" <<'__EOF_LIB_gather__'
#!/usr/bin/env bash
# lib/gather.sh — Phase 1: Evidence gathering agents

gather_evidence() {
    log_phase "Phase 1: Gathering evidence"

    if is_phase_complete "gather" && [[ "$FORCE" != "true" ]]; then
        log_info "Phase 1 already complete. Use --force to rerun."
        return 0
    fi

    local schemas="$SCRIPT_DIR/schemas"

    # ── Stage 1: Core agents + structure scout in parallel ──────

    log_progress "Stage 1: Core analysis + structure mapping..."

    # Allow some agent failures without aborting (|| true prevents set -e from killing us)
    run_agents_parallel \
        "run_agent identity \
            'Analyze this codebase. Determine the project identity: name, description, languages, frameworks, monorepo structure, deployment target, and existing AI config files.' \
            '$schemas/identity.json' \
            'Read,Bash(find:*),Bash(ls:*),Bash(cat:*),Bash(head:*)' \
            haiku" \
        "run_agent commands \
            'Find every build, test, lint, format, and typecheck command in this project. Check package.json, Makefile, CI pipelines, pyproject.toml, Cargo.toml, and task runners. Note which are CI-verified.' \
            '$schemas/commands.json' \
            'Read,Bash(find:*),Bash(cat:*),Bash(grep:*),Bash(jq:*)' \
            haiku" \
        "run_agent git-forensics \
            'Analyze the git history of this repository. Find hotspots, temporal coupling, bug-fix density, ownership diffusion, recent activity, commit patterns, and branch naming patterns.' \
            '$schemas/git-forensics.json' \
            'Bash(git:*)' \
            sonnet" \
        "run_agent patterns \
            'Examine this codebase for architectural patterns and conventions. Look for design patterns, error handling, import conventions, naming conventions, state management, auth patterns, testing patterns, and configuration management. Cite specific files as evidence.' \
            '$schemas/patterns.json' \
            'Read,Bash(find:*),Bash(grep:*),Glob' \
            sonnet" \
        "run_agent tooling \
            'Find every code quality tool configured in this project (linters, formatters, type checkers, pre-commit hooks). For each: name, config path, what it enforces, whether it runs in CI, and key rules.' \
            '$schemas/tooling.json' \
            'Read,Bash(find:*),Bash(cat:*),Bash(ls:*)' \
            haiku" \
        "run_agent docs-scanner \
            'Find and summarize all existing documentation in this repo: READMEs, CONTRIBUTING, ADRs, docs directories, API docs, AI config files. Identify documented conventions and undocumented gaps.' \
            '$schemas/docs.json' \
            'Read,Bash(find:*),Bash(head:*),Bash(wc:*)' \
            haiku" \
        "run_agent security-scan \
            'Scan for files that should be protected from AI agent modification: secrets, migrations, lock files, generated files, CI configs, and security-critical code.' \
            '$schemas/security.json' \
            'Read,Bash(find:*),Bash(grep:*),Bash(ls:*)' \
            haiku" \
        "run_agent structure-scout \
            'Map the directory structure of this project. Identify EVERY directory that deserves deep analysis — dig at least 3 levels deep. Classify each by role and priority. Be thorough: a typical full-stack app has 15-30 directories worth analyzing.' \
            '$schemas/structure-scout.json' \
            'Bash(find:*),Bash(ls:*),Bash(wc:*),Read' \
            sonnet" \
        || log_warn "Some Stage 1 agents failed (non-fatal)"

    # ── Stage 2: Deep-dive agents per directory of interest ─────

    run_deep_dive_agents \
        || log_warn "Some Stage 2 agents failed (non-fatal)"

    mark_phase_complete "gather"
    return 0
}

# Use the structure scout output to spawn deep-dive agents for each important directory.
run_deep_dive_agents() {
    local scout_file="$WORK_DIR/findings/structure-scout.json"

    if [[ ! -f "$scout_file" ]]; then
        log_warn "Structure scout findings not available. Falling back to top-level directory scan."
        run_fallback_module_analyzers
        return $?
    fi

    # Extract high and medium priority directories
    local dirs_json
    dirs_json=$(jq '[.directories[] | select(.priority == "high" or .priority == "medium")]' "$scout_file" 2>/dev/null)

    local dir_count
    dir_count=$(echo "$dirs_json" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$dir_count" -eq 0 ]]; then
        log_warn "Structure scout found no directories to analyze."
        return 0
    fi

    log_progress "Stage 2: Deep-diving into $dir_count directories..."

    local schemas="$SCRIPT_DIR/schemas"
    local module_calls=()

    for i in $(seq 0 $((dir_count - 1))); do
        local dir_path
        dir_path=$(echo "$dirs_json" | jq -r ".[$i].path")
        local dir_role
        dir_role=$(echo "$dirs_json" | jq -r ".[$i].role")
        local dir_desc
        dir_desc=$(echo "$dirs_json" | jq -r ".[$i].description")

        # Create a safe agent name from the path
        local safe_name
        safe_name=$(echo "$dir_path" | sed 's|/|-|g; s|\.|-|g; s|[()]||g; s|^-||; s|-$||')

        # Skip if already analyzed
        if [[ -f "$WORK_DIR/findings/module-${safe_name}.json" ]] && [[ "$FORCE" != "true" ]]; then
            log_info "Skipping module-${safe_name} (findings exist)"
            continue
        fi

        module_calls+=("run_agent module-${safe_name} \
            'Deeply analyze the directory at ${dir_path}/ in this project. This directory is classified as: ${dir_role}. Brief context: ${dir_desc}. Produce an exhaustive analysis covering: architecture and internal organization, key files (read at least 5-10 files), coding patterns with examples, conventions, dependencies, gotchas, and skill opportunities. Be thorough — read actual source files, not just directory listings.' \
            '$schemas/module-analysis.json' \
            'Read,Bash(find:*),Bash(grep:*),Bash(cat:*),Bash(wc:*),Bash(ls:*),Glob' \
            sonnet")
    done

    if [[ ${#module_calls[@]} -eq 0 ]]; then
        log_info "All module analyses already cached."
        return 0
    fi

    # Run in parallel batches to avoid overwhelming the system
    # Batch size of 8 — enough parallelism without hitting rate limits
    local batch_size=8
    local total=${#module_calls[@]}
    local batch_num=0

    for ((start=0; start<total; start+=batch_size)); do
        batch_num=$((batch_num + 1))
        local end=$((start + batch_size))
        if [[ $end -gt $total ]]; then
            end=$total
        fi

        local batch=("${module_calls[@]:$start:$((end-start))}")

        if [[ $total -gt $batch_size ]]; then
            log_progress "Running deep-dive batch $batch_num (dirs $((start+1))-$end of $total)..."
        fi

        run_agents_parallel "${batch[@]}" \
            || log_warn "Some agents in batch $batch_num failed (non-fatal)"
    done
}

# Fallback: if structure scout fails, use simple top-level directory detection
run_fallback_module_analyzers() {
    local schemas="$SCRIPT_DIR/schemas"
    local modules=()

    local dir_count
    dir_count=$(find "$TARGET_DIR" -maxdepth 1 -type d \
        -not -name '.*' \
        -not -name 'node_modules' \
        -not -name 'vendor' \
        -not -name '__pycache__' \
        -not -name 'target' \
        -not -name 'dist' \
        -not -name 'build' \
        -not -name 'out' \
        -not -name '.ultrainit' \
        | tail -n +2 | wc -l)

    if [[ "$dir_count" -lt 2 ]]; then
        log_info "No modules detected for analysis."
        return 0
    fi

    while IFS= read -r dir; do
        modules+=("$dir")
    done < <(find "$TARGET_DIR" -maxdepth 1 -type d \
        -not -name '.*' \
        -not -name 'node_modules' \
        -not -name 'vendor' \
        -not -name '__pycache__' \
        -not -name 'target' \
        -not -name 'dist' \
        -not -name 'build' \
        -not -name 'out' \
        -not -name '.ultrainit' \
        | tail -n +2)

    log_progress "Fallback: Running module analysis for ${#modules[@]} top-level directories..."

    local module_calls=()
    for mod in "${modules[@]}"; do
        local rel_name
        rel_name=$(basename "$mod")
        local safe_name
        safe_name=$(echo "$rel_name" | sed 's|/|-|g; s|\.|-|g')

        module_calls+=("run_agent module-${safe_name} \
            'Deeply analyze the directory at ${rel_name}/ in this project. Produce an exhaustive analysis covering: architecture, key files, patterns, conventions, dependencies, gotchas, and skill opportunities.' \
            '$schemas/module-analysis.json' \
            'Read,Bash(find:*),Bash(grep:*),Bash(cat:*),Bash(wc:*),Bash(ls:*),Glob' \
            sonnet")
    done

    run_agents_parallel "${module_calls[@]}"
}

__EOF_LIB_gather__

cat > "$BUNDLE_DIR/lib/merge.sh" <<'__EOF_LIB_merge__'
#!/usr/bin/env bash
# lib/merge.sh — Phase 5b: Write and merge artifacts into the project

write_artifacts() {
    log_phase "Phase 5b: Writing artifacts"

    local output="$WORK_DIR/synthesis/output.json"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry run — not writing files. Output is in: $output"
        print_summary "$output"
        return 0
    fi

    # ── Backup existing files ───────────────────────────────────
    backup_existing

    # ── Write CLAUDE.md ─────────────────────────────────────────
    jq -r '.claude_md' "$output" > CLAUDE.md
    local lines
    lines=$(wc -l < CLAUDE.md)
    log_success "Wrote CLAUDE.md ($lines lines)"

    # ── Write subdirectory CLAUDE.md files ──────────────────────
    local sub_count
    sub_count=$(jq '.subdirectory_claude_mds // [] | length' "$output")
    for i in $(seq 0 $((sub_count - 1))); do
        local sub_path
        sub_path=$(jq -r ".subdirectory_claude_mds[$i].path" "$output")
        local sub_content
        sub_content=$(jq -r ".subdirectory_claude_mds[$i].content" "$output")

        mkdir -p "$sub_path"
        echo "$sub_content" > "$sub_path/CLAUDE.md"
        log_success "Wrote $sub_path/CLAUDE.md"
    done

    # ── Write skills ────────────────────────────────────────────
    local skill_count
    skill_count=$(jq '.skills // [] | length' "$output")
    for i in $(seq 0 $((skill_count - 1))); do
        local name
        name=$(jq -r ".skills[$i].name" "$output")

        # Don't overwrite existing skills
        if [[ -f ".claude/skills/$name/SKILL.md" ]]; then
            log_info "Skipping existing skill: $name"
            continue
        fi

        mkdir -p ".claude/skills/$name"
        jq -r ".skills[$i].content" "$output" > ".claude/skills/$name/SKILL.md"
        log_success "Wrote .claude/skills/$name/SKILL.md"
    done

    # ── Write hooks ─────────────────────────────────────────────
    local hook_count
    hook_count=$(jq '.hooks // [] | length' "$output")
    for i in $(seq 0 $((hook_count - 1))); do
        local filename
        filename=$(jq -r ".hooks[$i].filename" "$output")

        # Don't overwrite existing hooks
        if [[ -f ".claude/hooks/$filename" ]]; then
            log_info "Skipping existing hook: $filename"
            continue
        fi

        mkdir -p ".claude/hooks"
        jq -r ".hooks[$i].content" "$output" > ".claude/hooks/$filename"
        chmod +x ".claude/hooks/$filename"
        log_success "Wrote .claude/hooks/$filename"
    done

    # ── Write subagents ─────────────────────────────────────────
    local agent_count
    agent_count=$(jq '.subagents // [] | length' "$output")
    for i in $(seq 0 $((agent_count - 1))); do
        local name
        name=$(jq -r ".subagents[$i].name" "$output")

        if [[ -f ".claude/agents/${name}.md" ]]; then
            log_info "Skipping existing agent: $name"
            continue
        fi

        mkdir -p ".claude/agents"
        jq -r ".subagents[$i].content" "$output" > ".claude/agents/${name}.md"
        log_success "Wrote .claude/agents/${name}.md"
    done

    # ── Write/merge MCP config ─────────────────────────────────
    write_mcp_config "$output"

    # ── Merge settings.json (hooks wiring) ──────────────────────
    merge_settings "$output"

    # ── Print summary ───────────────────────────────────────────
    print_summary "$output"
}

# ── Backup ──────────────────────────────────────────────────────

backup_existing() {
    local backup_dir="$WORK_DIR/backups/$(iso_date)"
    local backed_up=0

    # Back up root CLAUDE.md and settings
    for f in CLAUDE.md .claude/settings.json .claude/mcp.json; do
        if [[ -f "$f" ]]; then
            mkdir -p "$backup_dir/$(dirname "$f")"
            cp "$f" "$backup_dir/$f"
            backed_up=$((backed_up + 1))
        fi
    done

    # Back up subdirectory CLAUDE.md files
    while IFS= read -r f; do
        mkdir -p "$backup_dir/$(dirname "$f")"
        cp "$f" "$backup_dir/$f"
        backed_up=$((backed_up + 1))
    done < <(find . -name "CLAUDE.md" -not -path './.ultrainit/*' -not -path './node_modules/*' 2>/dev/null)

    # Back up skills, agents, hooks
    for dir in .claude/skills .claude/agents .claude/hooks; do
        if [[ -d "$dir" ]]; then
            mkdir -p "$backup_dir/$dir"
            cp -r "$dir"/* "$backup_dir/$dir/" 2>/dev/null || true
            backed_up=$((backed_up + 1))
        fi
    done

    if [[ $backed_up -gt 0 ]]; then
        log_info "Backed up $backed_up existing item(s) to $backup_dir"
    fi
}

# ── Overwrite (remove existing config before analysis) ──────────

# Backs up and removes all Claude Code configuration so analysis agents
# see the raw codebase without being influenced by existing config.
overwrite_existing() {
    log_progress "Overwrite mode: backing up and removing existing Claude Code config..."

    # Back up first
    backup_existing

    # Remove all CLAUDE.md files
    find . -name "CLAUDE.md" \
        -not -path './.ultrainit/*' \
        -not -path './node_modules/*' \
        -not -path './vendor/*' \
        -delete 2>/dev/null
    local removed_claude
    removed_claude=$(find . -name "CLAUDE.md" -not -path './.ultrainit/*' 2>/dev/null | wc -l)

    # Remove .claude/ skills, agents, hooks (but preserve mcp.json and settings.json user config)
    rm -rf .claude/skills .claude/agents .claude/hooks

    # Remove settings.json hooks (keep other settings)
    if [[ -f .claude/settings.json ]]; then
        local tmp
        tmp=$(jq 'del(.hooks)' .claude/settings.json 2>/dev/null)
        if [[ -n "$tmp" ]]; then
            echo "$tmp" > .claude/settings.json
        fi
    fi

    log_success "Existing config removed (backed up to .ultrainit/backups/)"
}

# ── Settings merge ──────────────────────────────────────────────

merge_settings() {
    local output="$1"

    local hook_count
    hook_count=$(jq '.settings_hooks // [] | length' "$output")
    if [[ "$hook_count" -eq 0 ]]; then
        return 0
    fi

    # Build the hooks section for settings.json
    local hooks_json='{"hooks":{}}'

    for i in $(seq 0 $((hook_count - 1))); do
        local event
        event=$(jq -r ".settings_hooks[$i].event" "$output")
        local command
        command=$(jq -r ".settings_hooks[$i].command" "$output")
        local matcher
        matcher=$(jq -r ".settings_hooks[$i].matcher // empty" "$output")

        local hook_entry
        if [[ -n "$matcher" ]]; then
            hook_entry=$(jq -n --arg cmd "$command" --arg m "$matcher" \
                '{"matcher": $m, "hooks": [{"type": "command", "command": $cmd}]}')
        else
            hook_entry=$(jq -n --arg cmd "$command" \
                '{"hooks": [{"type": "command", "command": $cmd}]}')
        fi

        hooks_json=$(echo "$hooks_json" | jq --arg event "$event" --argjson entry "$hook_entry" \
            '.hooks[$event] = (.hooks[$event] // []) + [$entry]')
    done

    mkdir -p .claude
    if [[ -f .claude/settings.json ]]; then
        # Deep merge: add new hooks, preserve existing
        local existing
        existing=$(cat .claude/settings.json)
        jq -s '.[0] * .[1]' <(echo "$existing") <(echo "$hooks_json") > .claude/settings.json
        log_success "Merged hooks into existing .claude/settings.json"
    else
        echo "$hooks_json" | jq '.' > .claude/settings.json
        log_success "Wrote .claude/settings.json"
    fi
}

# ── MCP config ──────────────────────────────────────────────────

write_mcp_config() {
    local output="$1"

    local mcp_count
    mcp_count=$(jq '.mcp_servers // [] | length' "$output")
    if [[ "$mcp_count" -eq 0 ]]; then
        return 0
    fi

    # Build mcpServers object for .claude/mcp.json
    local mcp_json='{"mcpServers":{}}'

    for i in $(seq 0 $((mcp_count - 1))); do
        local name
        name=$(jq -r ".mcp_servers[$i].name" "$output")
        local command
        command=$(jq -r ".mcp_servers[$i].command" "$output")
        local args
        args=$(jq ".mcp_servers[$i].args" "$output")
        local env
        env=$(jq ".mcp_servers[$i].env // {}" "$output")

        local server_entry
        server_entry=$(jq -n --arg cmd "$command" --argjson args "$args" --argjson env "$env" \
            '{command: $cmd, args: $args, env: $env}')

        mcp_json=$(echo "$mcp_json" | jq --arg name "$name" --argjson entry "$server_entry" \
            '.mcpServers[$name] = $entry')
    done

    mkdir -p .claude
    if [[ -f .claude/mcp.json ]]; then
        # Merge: add new servers, preserve existing
        local existing
        existing=$(cat .claude/mcp.json)
        jq -s '.[0] * .[1]' <(echo "$existing") <(echo "$mcp_json") > .claude/mcp.json
        log_success "Merged $mcp_count MCP server(s) into existing .claude/mcp.json"
    else
        echo "$mcp_json" | jq '.' > .claude/mcp.json
        log_success "Wrote .claude/mcp.json ($mcp_count server(s))"
    fi
}

# ── Summary ─────────────────────────────────────────────────────

print_summary() {
    local output="$1"

    echo ""
    echo -e "${BOLD}Generated artifacts:${RESET}"

    # CLAUDE.md
    local lines
    lines=$(jq -r '.claude_md' "$output" | wc -l)
    echo -e "  ${GREEN}✓${RESET} CLAUDE.md ($lines lines)"

    # Subdirectory CLAUDE.md
    local sub_count
    sub_count=$(jq '.subdirectory_claude_mds // [] | length' "$output")
    if [[ $sub_count -gt 0 ]]; then
        for i in $(seq 0 $((sub_count - 1))); do
            local p
            p=$(jq -r ".subdirectory_claude_mds[$i].path" "$output")
            echo -e "  ${GREEN}✓${RESET} $p/CLAUDE.md"
        done
    fi

    # Skills
    local skill_count
    skill_count=$(jq '.skills // [] | length' "$output")
    if [[ $skill_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${RESET} $skill_count skill(s):"
        for i in $(seq 0 $((skill_count - 1))); do
            local n
            n=$(jq -r ".skills[$i].name" "$output")
            echo -e "      .claude/skills/$n/SKILL.md"
        done
    fi

    # Hooks
    local hook_count
    hook_count=$(jq '.hooks // [] | length' "$output")
    if [[ $hook_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${RESET} $hook_count hook(s):"
        for i in $(seq 0 $((hook_count - 1))); do
            local n
            n=$(jq -r ".hooks[$i].filename" "$output")
            echo -e "      .claude/hooks/$n"
        done
    fi

    # Subagents
    local agent_count
    agent_count=$(jq '.subagents // [] | length' "$output")
    if [[ $agent_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${RESET} $agent_count subagent(s)"
    fi

    # MCP servers
    local mcp_count
    mcp_count=$(jq '.mcp_servers // [] | length' "$output")
    if [[ $mcp_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${RESET} $mcp_count MCP server(s) in .claude/mcp.json"
    fi

    echo ""
}

__EOF_LIB_merge__

cat > "$BUNDLE_DIR/lib/research.sh" <<'__EOF_LIB_research__'
#!/usr/bin/env bash
# lib/research.sh — Phase 3: Domain research and MCP discovery

run_research() {
    log_phase "Phase 3: Research"

    if is_phase_complete "research" && [[ "$FORCE" != "true" ]]; then
        log_info "Phase 3 already complete. Use --force to rerun."
        return 0
    fi

    local schemas="$SCRIPT_DIR/schemas"

    # Build context from Phase 1 findings for the research agents
    local identity_file="$WORK_DIR/findings/identity.json"
    local answers_file="$WORK_DIR/developer-answers.json"

    # Extract key info for research prompts
    local project_purpose=""
    local tech_stack=""
    local external_services=""
    local deployment_target=""

    if [[ -f "$answers_file" ]]; then
        project_purpose=$(jq -r '.project_purpose // empty' "$answers_file" 2>/dev/null)
        external_services=$(jq -r '.external_services // empty' "$answers_file" 2>/dev/null)
        deployment_target=$(jq -r '.deployment_target // empty' "$answers_file" 2>/dev/null)
    fi

    if [[ -f "$identity_file" ]]; then
        tech_stack=$(jq -r '[.frameworks[]?.name] | join(", ")' "$identity_file" 2>/dev/null)
        local languages
        languages=$(jq -r '[.languages[]?.name] | join(", ")' "$identity_file" 2>/dev/null)
        local project_name
        project_name=$(jq -r '.name // empty' "$identity_file" 2>/dev/null)
        local project_desc
        project_desc=$(jq -r '.description // empty' "$identity_file" 2>/dev/null)

        # Use identity description if developer didn't provide one
        project_purpose="${project_purpose:-$project_desc}"
    fi

    if [[ -z "$tech_stack" ]]; then
        log_warn "No tech stack detected. Skipping research phase."
        mark_phase_complete "research"
        return 0
    fi

    log_info "Tech stack: $tech_stack"
    log_info "Project purpose: ${project_purpose:-(unknown)}"

    # ── Run research agents in parallel ─────────────────────────

    local research_calls=()

    # Domain researcher
    research_calls+=("run_agent domain-research \
        'Research the domain and tech stack for this project.
Project: ${project_name:-unknown} — ${project_purpose:-unknown purpose}
Languages: ${languages:-unknown}
Tech stack: ${tech_stack}
Deployment: ${deployment_target:-unknown}
External services: ${external_services:-none mentioned}

Research:
1. Domain-specific terminology and concepts that map to code patterns
2. Best practices for the specific framework VERSIONS detected (not generic advice)
3. Common pitfalls developers encounter with this exact tech stack combination
4. Architectural patterns common in this type of application

Focus on version-specific, non-obvious information. Skip anything generic.' \
        '$schemas/domain-research.json' \
        'Read,WebSearch,WebFetch' \
        sonnet")

    # MCP discoverer (skip if --skip-mcp)
    if [[ "$SKIP_MCP" != "true" ]]; then
        research_calls+=("run_agent mcp-discovery \
            'Find MCP servers useful for developing this project.
Project: ${project_name:-unknown}
Tech stack: ${tech_stack}
Languages: ${languages:-unknown}
External services: ${external_services:-none mentioned}
Deployment: ${deployment_target:-unknown}

Search for MCP servers on npm, PyPI, and GitHub that are directly relevant to this tech stack.
For database servers: look for the specific databases this project uses.
For framework docs: look for servers providing documentation for the detected frameworks.
Only recommend servers that are actively maintained and directly useful.' \
            '$schemas/mcp-recommendations.json' \
            'Read,WebSearch,WebFetch,Bash(curl:*)' \
            sonnet")
    fi

    if [[ ${#research_calls[@]} -gt 0 ]]; then
        run_agents_parallel "${research_calls[@]}" \
            || log_warn "Some research agents failed (non-fatal)"
    fi

    mark_phase_complete "research"
    return 0
}

__EOF_LIB_research__

cat > "$BUNDLE_DIR/lib/synthesize.sh" <<'__EOF_LIB_synthesize__'
#!/usr/bin/env bash
# lib/synthesize.sh — Phase 4: Two-pass synthesis

synthesize() {
    log_phase "Phase 4: Synthesis"

    if is_phase_complete "synthesize" && [[ "$FORCE" != "true" ]]; then
        log_info "Phase 4 already complete. Use --force to rerun."
        return 0
    fi

    log_progress "Building context from all findings..."

    # ── Collect all findings into one context document ──────────

    local context_file="$WORK_DIR/synthesis-context.txt"
    build_context "$context_file"

    local context_size
    context_size=$(wc -c < "$context_file" | tr -d ' ')
    log_info "Context assembled: ${context_size} bytes"

    # ── Pass 1: CLAUDE.md files ─────────────────────────────────

    log_progress "Pass 1/2: Generating CLAUDE.md files (model: $SYNTH_MODEL)..."

    run_synthesis_pass \
        "docs" \
        "$SCRIPT_DIR/schemas/synthesis-docs.json" \
        "$SCRIPT_DIR/prompts/synthesizer-docs.md" \
        "$context_file" \
        "Generate comprehensive CLAUDE.md files for this codebase." \
        || return 1

    # ── Pass 2: Skills, hooks, subagents ────────────────────────

    log_progress "Pass 2/2: Generating skills, hooks, and subagents (model: $SYNTH_MODEL)..."

    run_synthesis_pass \
        "tooling" \
        "$SCRIPT_DIR/schemas/synthesis-tooling.json" \
        "$SCRIPT_DIR/prompts/synthesizer-tooling.md" \
        "$context_file" \
        "Generate skills, hooks, subagents, and MCP server recommendations for this codebase." \
        || return 1

    # ── Merge both passes into final output ─────────────────────

    merge_synthesis_passes

    mark_phase_complete "synthesize"
}

# ── Build context from all findings ─────────────────────────────

build_context() {
    local context_file="$1"
    : > "$context_file"

    # Core findings
    local -A finding_labels=(
        [identity]="PROJECT IDENTITY"
        [commands]="COMMANDS"
        [git-forensics]="GIT FORENSICS"
        [patterns]="PATTERNS"
        [tooling]="TOOLING"
        [docs-scanner]="DOCUMENTATION"
        [security-scan]="SECURITY"
        [structure-scout]="DIRECTORY STRUCTURE"
    )

    for key in identity commands git-forensics patterns tooling docs-scanner security-scan structure-scout; do
        local f="$WORK_DIR/findings/${key}.json"
        if [[ -f "$f" ]]; then
            echo "=== ${finding_labels[$key]} ===" >> "$context_file"
            cat "$f" >> "$context_file"
            echo -e "\n" >> "$context_file"
        fi
    done

    # Module analyses
    for f in "$WORK_DIR/findings/module-"*.json; do
        if [[ -f "$f" ]]; then
            local mod_name
            mod_name=$(basename "$f" .json | sed 's/^module-//')
            echo "=== MODULE: $mod_name ===" >> "$context_file"
            cat "$f" >> "$context_file"
            echo -e "\n" >> "$context_file"
        fi
    done

    # Developer answers
    if [[ -f "$WORK_DIR/developer-answers.json" ]]; then
        echo "=== DEVELOPER ANSWERS ===" >> "$context_file"
        cat "$WORK_DIR/developer-answers.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi

    # Research findings
    for key in domain-research mcp-discovery; do
        local f="$WORK_DIR/findings/${key}.json"
        if [[ -f "$f" ]]; then
            echo "=== $(echo "$key" | tr '[:lower:]-' '[:upper:] ') ===" >> "$context_file"
            cat "$f" >> "$context_file"
            echo -e "\n" >> "$context_file"
        fi
    done
}

# ── Run a single synthesis pass ─────────────────────────────────

run_synthesis_pass() {
    local pass_name="$1"
    local schema_file="$2"
    local prompt_file_path="$3"
    local context_file="$4"
    local instruction="$5"

    local schema
    schema=$(cat "$schema_file")

    # Build the prompt file
    local prompt_file="$WORK_DIR/synthesis-prompt-${pass_name}.txt"
    cat > "$prompt_file" <<PROMPT_HEADER
${instruction}

Analyze the following codebase findings:

PROMPT_HEADER
    cat "$context_file" >> "$prompt_file"
    cat >> "$prompt_file" <<'PROMPT_FOOTER'

Based on ALL of the above findings, generate the requested artifacts.
Every rule must trace to evidence above. No generic advice. No duplication of linter rules. Be comprehensive and thorough.
PROMPT_FOOTER

    local stderr_file="$WORK_DIR/logs/synthesis-${pass_name}.stderr"
    : > "$stderr_file"

    local raw_output
    raw_output=$(cat "$prompt_file" | claude -p - \
        --model "$SYNTH_MODEL" \
        --output-format json \
        --json-schema "$schema" \
        --allowedTools "Read" \
        --append-system-prompt-file "$prompt_file_path" \
        --max-budget-usd "$SYNTH_BUDGET" \
        2>>"$stderr_file")

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_error "Synthesis pass '$pass_name' failed (exit $exit_code). See $stderr_file"
        return 1
    fi

    local is_error
    is_error=$(echo "$raw_output" | jq -r '.is_error // false' 2>/dev/null)
    if [[ "$is_error" == "true" ]]; then
        log_error "Synthesis pass '$pass_name' returned an error"
        return 1
    fi

    # Extract structured output
    echo "$raw_output" | jq '.structured_output // .result // .' \
        > "$WORK_DIR/synthesis/output-${pass_name}.json" 2>/dev/null

    if ! jq -e 'type == "object"' "$WORK_DIR/synthesis/output-${pass_name}.json" >/dev/null 2>&1; then
        log_error "Synthesis pass '$pass_name' did not produce structured output"
        echo "Raw: $raw_output" >> "$stderr_file"
        return 1
    fi

    # Track cost
    local cost
    cost=$(echo "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)
    record_cost "synthesize" "pass-${pass_name}" "$cost"

    log_success "Pass '$pass_name' complete (cost: \$$cost)"
    return 0
}

# ── Merge both passes into unified output.json ──────────────────

merge_synthesis_passes() {
    local docs="$WORK_DIR/synthesis/output-docs.json"
    local tooling="$WORK_DIR/synthesis/output-tooling.json"

    # Merge into the format expected by validate + write phases
    jq -s '.[0] * .[1]' "$docs" "$tooling" > "$WORK_DIR/synthesis/output.json"

    # Post-process: strip angle brackets from descriptions
    postprocess_descriptions "$WORK_DIR/synthesis/output.json"

    log_success "Synthesis passes merged"
}

# ── Post-processing ─────────────────────────────────────────────

# Strip angle brackets from skill and subagent YAML description fields.
postprocess_descriptions() {
    local output_file="$1"
    local tmp_file="${output_file}.tmp"
    local fixed=0

    local skill_count
    skill_count=$(jq '.skills // [] | length' "$output_file")

    for i in $(seq 0 $((skill_count - 1))); do
        local content
        content=$(jq -r ".skills[$i].content" "$output_file")

        if echo "$content" | awk '/^description:/,/^[a-z]/' | grep -q '[<>]'; then
            local new_content
            new_content=$(echo "$content" | awk '
                /^description:/ { in_desc=1 }
                in_desc && /^[a-z]/ && !/^description:/ { in_desc=0 }
                in_desc { gsub(/</, "\""); gsub(/>/, "\"") }
                { print }
            ')
            jq --arg idx "$i" --arg val "$new_content" \
                '.skills[$idx | tonumber].content = $val' "$output_file" > "$tmp_file" \
                && mv "$tmp_file" "$output_file"
            fixed=$((fixed + 1))
        fi
    done

    local agent_count
    agent_count=$(jq '.subagents // [] | length' "$output_file")

    for i in $(seq 0 $((agent_count - 1))); do
        local content
        content=$(jq -r ".subagents[$i].content" "$output_file")

        if echo "$content" | awk '/^description:/,/^[a-z]/' | grep -q '[<>]'; then
            local new_content
            new_content=$(echo "$content" | awk '
                /^description:/ { in_desc=1 }
                in_desc && /^[a-z]/ && !/^description:/ { in_desc=0 }
                in_desc { gsub(/</, "\""); gsub(/>/, "\"") }
                { print }
            ')
            jq --arg idx "$i" --arg val "$new_content" \
                '.subagents[$idx | tonumber].content = $val' "$output_file" > "$tmp_file" \
                && mv "$tmp_file" "$output_file"
            fixed=$((fixed + 1))
        fi
    done

    if [[ $fixed -gt 0 ]]; then
        log_info "Post-processed $fixed description(s) to remove angle brackets"
    fi
}

__EOF_LIB_synthesize__

cat > "$BUNDLE_DIR/lib/utils.sh" <<'__EOF_LIB_utils__'
#!/usr/bin/env bash
# lib/utils.sh — Logging, JSON helpers, phase tracking

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' RESET=''
fi

log_info()     { echo -e "${BLUE}[info]${RESET}    $*"; }
log_success()  { echo -e "${GREEN}[ok]${RESET}      $*"; }
log_warn()     { echo -e "${YELLOW}[warn]${RESET}    $*"; }
log_error()    { echo -e "${RED}[error]${RESET}   $*" >&2; }
log_phase()    { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}\n"; }
log_progress() { echo -e "${CYAN}[...]${RESET}    $*"; }

# ── Phase tracking ──────────────────────────────────────────────

mark_phase_complete() {
    local phase="$1"
    local state_file="$WORK_DIR/state.json"

    if [[ ! -f "$state_file" ]]; then
        echo '{}' > "$state_file"
    fi

    local tmp
    tmp=$(jq --arg p "$phase" --arg t "$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)" \
        '.[$p] = $t' "$state_file")
    echo "$tmp" > "$state_file"
}

is_phase_complete() {
    local phase="$1"
    local state_file="$WORK_DIR/state.json"

    [[ -f "$state_file" ]] && jq -e --arg p "$phase" '.[$p] // empty' "$state_file" >/dev/null 2>&1
}

# ── JSON helpers ────────────────────────────────────────────────

# Read a key from a JSON file, returning empty string on failure
json_get() {
    local file="$1"
    local key="$2"
    jq -r "$key // empty" "$file" 2>/dev/null || echo ""
}

# Merge two JSON objects (stdin + file), stdout
json_merge() {
    local file="$1"
    jq -s '.[0] * .[1]' - "$file"
}

# ── Progress display ────────────────────────────────────────────

# Show a spinner while a PID is running
spin() {
    local pid="$1"
    local label="${2:-Working}"
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    # Only show spinner in interactive terminals
    if [[ ! -t 1 ]]; then
        wait "$pid" 2>/dev/null
        return $?
    fi

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${CYAN}%s${RESET} %s " "${chars:i%${#chars}:1}" "$label"
        i=$((i + 1))
        sleep 0.1
    done
    printf "\r"

    wait "$pid" 2>/dev/null
    return $?
}

# ── Misc ────────────────────────────────────────────────────────

# Portable date -Iseconds (works on macOS with coreutils or fallback)
iso_date() {
    date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z
}

# ── Cost reporting ──────────────────────────────────────────────

print_cost_summary() {
    local cost_file="$WORK_DIR/cost.log"
    if [[ ! -f "$cost_file" ]]; then
        return 0
    fi

    echo -e "\n${BOLD}Cost breakdown:${RESET}"

    local total=0
    local phase_totals=()
    local current_phase=""
    local phase_sum=0

    while IFS='|' read -r phase agent cost; do
        [[ -z "$cost" || "$cost" == "0" || "$cost" == "null" ]] && continue

        if [[ "$phase" != "$current_phase" ]]; then
            if [[ -n "$current_phase" ]]; then
                printf "  %-12s \$%.4f\n" "$current_phase:" "$phase_sum"
            fi
            current_phase="$phase"
            phase_sum=0
        fi
        phase_sum=$(echo "$phase_sum + $cost" | bc 2>/dev/null || echo "$phase_sum")
        total=$(echo "$total + $cost" | bc 2>/dev/null || echo "$total")
    done < <(sort "$cost_file")

    # Print last phase
    if [[ -n "$current_phase" ]]; then
        printf "  %-12s \$%.4f\n" "$current_phase:" "$phase_sum"
    fi

    echo -e "  ${BOLD}────────────────────${RESET}"
    printf "  ${BOLD}%-12s \$%.4f${RESET}\n" "Total:" "$total"
}

__EOF_LIB_utils__

cat > "$BUNDLE_DIR/lib/validate.sh" <<'__EOF_LIB_validate__'
#!/usr/bin/env bash
# lib/validate.sh — Phase 5a: Validate generated artifacts

validate_artifacts() {
    log_phase "Phase 5a: Validating artifacts"

    local output="$WORK_DIR/synthesis/output.json"
    local issues_file="$WORK_DIR/logs/validation-issues.txt"
    : > "$issues_file"
    local errors=0

    # ── Validate CLAUDE.md ──────────────────────────────────────

    validate_claude_md "$output" "$issues_file"
    errors=$((errors + $?))

    # ── Validate skills (write to temp files, run validator) ────

    local skill_count
    skill_count=$(jq '.skills // [] | length' "$output")
    log_info "Skills generated: $skill_count"

    if [[ $skill_count -lt 5 ]]; then
        echo "Only $skill_count skills generated (expected 10+). Major workflows likely missing." >> "$issues_file"
        log_warn "Only $skill_count skills generated (expected 10+)"
        errors=$((errors + 1))
    fi

    for i in $(seq 0 $((skill_count - 1))); do
        local skill_name
        skill_name=$(jq -r ".skills[$i].name" "$output")

        # Write skill to temp dir for validation
        local tmp_skill_dir="$WORK_DIR/validation/skills/$skill_name"
        mkdir -p "$tmp_skill_dir"
        jq -r ".skills[$i].content" "$output" > "$tmp_skill_dir/SKILL.md"

        # Run structural validator
        local skill_result
        if skill_result=$(bash "$SCRIPT_DIR/scripts/validate-skill.sh" "$tmp_skill_dir/SKILL.md" 2>&1); then
            log_success "Skill $skill_name: PASS"
        else
            local skill_errors
            skill_errors=$(echo "$skill_result" | grep -c '^ERROR:' || true)
            local skill_warnings
            skill_warnings=$(echo "$skill_result" | grep -c '^WARNING:' || true)

            if [[ $skill_errors -gt 0 ]]; then
                echo "Skill $skill_name: $skill_errors error(s)" >> "$issues_file"
                echo "$skill_result" | grep '^ERROR:' >> "$issues_file"
                log_warn "Skill $skill_name: FAIL ($skill_errors errors, $skill_warnings warnings)"
                errors=$((errors + skill_errors))
            else
                log_info "Skill $skill_name: $skill_warnings warning(s)"
            fi
        fi
    done

    # ── Validate hooks ──────────────────────────────────────────

    local hook_count
    hook_count=$(jq '.hooks // [] | length' "$output")
    log_info "Hooks generated: $hook_count"

    for i in $(seq 0 $((hook_count - 1))); do
        validate_hook "$output" "$i" "$issues_file"
        errors=$((errors + $?))
    done

    # ── Validate subagents ──────────────────────────────────────

    local agent_count
    agent_count=$(jq '.subagents // [] | length' "$output")
    if [[ $agent_count -gt 0 ]]; then
        log_info "Subagents generated: $agent_count"

        for i in $(seq 0 $((agent_count - 1))); do
            local agent_name
            agent_name=$(jq -r ".subagents[$i].name" "$output")

            # Write agent to temp file for validation
            mkdir -p "$WORK_DIR/validation/agents"
            jq -r ".subagents[$i].content" "$output" > "$WORK_DIR/validation/agents/${agent_name}.md"

            local agent_result
            if agent_result=$(bash "$SCRIPT_DIR/scripts/validate-subagent.sh" "$WORK_DIR/validation/agents/${agent_name}.md" 2>&1); then
                log_success "Subagent $agent_name: PASS"
            else
                local agent_errors
                agent_errors=$(echo "$agent_result" | grep -c '^ERROR:' || true)
                if [[ $agent_errors -gt 0 ]]; then
                    echo "Subagent $agent_name: $agent_errors error(s)" >> "$issues_file"
                    echo "$agent_result" | grep '^ERROR:' >> "$issues_file"
                    log_warn "Subagent $agent_name: FAIL ($agent_errors errors)"
                    errors=$((errors + agent_errors))
                else
                    local agent_warnings
                    agent_warnings=$(echo "$agent_result" | grep -c '^WARNING:' || true)
                    log_info "Subagent $agent_name: $agent_warnings warning(s)"
                fi
            fi
        done
    fi

    # ── Validate hook wiring ────────────────────────────────────

    validate_hook_wiring "$output" "$issues_file"
    errors=$((errors + $?))

    # ── Summary ─────────────────────────────────────────────────

    if [[ $errors -gt 0 ]]; then
        log_warn "$errors validation issue(s) found"
        run_revision_agent "$issues_file"
        return $?
    fi

    log_success "All artifacts passed validation"
    return 0
}

# ── CLAUDE.md validation ────────────────────────────────────────

validate_claude_md() {
    local output="$1"
    local issues_file="$2"
    local err=0

    local claude_md
    claude_md=$(jq -r '.claude_md' "$output")

    # Line count (informational, no hard limit)
    local lines
    lines=$(echo "$claude_md" | wc -l)
    if [[ $lines -lt 50 ]]; then
        echo "CLAUDE.md is only $lines lines — likely too thin. Should be 100+ lines for a real project." >> "$issues_file"
        log_warn "CLAUDE.md is only $lines lines (expected 100+)"
        err=$((err + 1))
    else
        log_success "CLAUDE.md: $lines lines"
    fi

    # Generic phrases
    local generic_count
    generic_count=$(echo "$claude_md" | grep -ciE '(best practice|clean code|solid principle|maintainable|readable|scalable|well-structured|production.ready|industry standard)' || true)
    if [[ $generic_count -gt 0 ]]; then
        echo "CLAUDE.md contains $generic_count generic phrases (must be 0)" >> "$issues_file"
        log_warn "CLAUDE.md contains $generic_count generic phrase(s)"
        err=$((err + 1))
    fi

    # Command blocks or tables (must have at least one)
    local has_commands
    has_commands=$(echo "$claude_md" | grep -cE '(```|^\|.*\|.*\|)' || true)
    if [[ $has_commands -lt 1 ]]; then
        echo "CLAUDE.md has no code blocks or command tables" >> "$issues_file"
        log_warn "CLAUDE.md has no code blocks or command tables"
        err=$((err + 1))
    fi

    # Prohibitions without alternatives
    local prohibitions
    prohibitions=$(echo "$claude_md" | grep -ciE '(never |don.t |do not )' || true)
    local alternatives
    alternatives=$(echo "$claude_md" | grep -ciE '(instead|use .* instead|prefer |create new)' || true)
    if [[ $prohibitions -gt 0 ]] && [[ $alternatives -eq 0 ]]; then
        echo "CLAUDE.md has $prohibitions prohibitions but no alternatives" >> "$issues_file"
        log_warn "CLAUDE.md has prohibitions without alternatives"
        err=$((err + 1))
    fi

    return $err
}

# ── Hook validation ─────────────────────────────────────────────

validate_hook() {
    local output="$1"
    local index="$2"
    local issues_file="$3"
    local err=0

    local hook_name
    hook_name=$(jq -r ".hooks[$index].filename" "$output")
    local hook_content
    hook_content=$(jq -r ".hooks[$index].content" "$output")

    # Shebang
    if ! echo "$hook_content" | head -1 | grep -q '^#!/'; then
        echo "Hook $hook_name: missing shebang" >> "$issues_file"
        log_warn "Hook $hook_name: missing shebang"
        err=$((err + 1))
    fi

    # set -euo pipefail
    if ! echo "$hook_content" | grep -q 'set -euo pipefail'; then
        echo "Hook $hook_name: missing 'set -euo pipefail'" >> "$issues_file"
        log_warn "Hook $hook_name: missing set -euo pipefail"
        err=$((err + 1))
    fi

    # Reads from stdin
    if ! echo "$hook_content" | grep -qE '(cat$|cat\)|read |stdin)'; then
        echo "Hook $hook_name: doesn't appear to read JSON from stdin" >> "$issues_file"
        log_warn "Hook $hook_name: may not read stdin"
        err=$((err + 1))
    fi

    # Blocking hooks must have actionable error messages
    if echo "$hook_content" | grep -q 'exit 2'; then
        if ! echo "$hook_content" | grep -qE '(echo|>&2)'; then
            echo "Hook $hook_name: exit 2 (blocking) without error message" >> "$issues_file"
            log_warn "Hook $hook_name: blocks without error message"
            err=$((err + 1))
        fi
    fi

    if [[ $err -eq 0 ]]; then
        log_success "Hook $hook_name: PASS"
    fi

    return $err
}

# ── Hook wiring validation ──────────────────────────────────────

validate_hook_wiring() {
    local output="$1"
    local issues_file="$2"
    local err=0

    local hook_count
    hook_count=$(jq '.hooks // [] | length' "$output")
    local wiring_count
    wiring_count=$(jq '.settings_hooks // [] | length' "$output")

    if [[ $hook_count -gt 0 ]] && [[ $wiring_count -eq 0 ]]; then
        echo "Generated $hook_count hook(s) but no settings_hooks wiring" >> "$issues_file"
        log_warn "$hook_count hook(s) generated but no settings_hooks wiring"
        err=$((err + 1))
    fi

    return $err
}

# ── Revision agent ──────────────────────────────────────────────

run_revision_agent() {
    local issues_file="$1"
    local issues
    issues=$(cat "$issues_file")

    log_progress "Running revision agent to fix issues..."

    local schema
    schema=$(cat "$SCRIPT_DIR/schemas/synthesis-output.json")

    local stderr_file="$WORK_DIR/logs/revision.stderr"

    # Build revision prompt as a file (output.json can be very large)
    local revision_prompt_file="$WORK_DIR/revision-prompt.txt"
    cat > "$revision_prompt_file" <<REVISION_HEADER
These generated Claude Code artifacts have validation issues. Fix ONLY the issues listed below. Do NOT change anything that passed validation.

ISSUES:
$issues

CURRENT ARTIFACTS:
REVISION_HEADER
    cat "$WORK_DIR/synthesis/output.json" >> "$revision_prompt_file"
    cat >> "$revision_prompt_file" <<'REVISION_FOOTER'

Fix all issues and return the corrected artifacts. Key rules:
- CLAUDE.md must contain ZERO generic phrases (best practice, clean code, SOLID, maintainable, readable, scalable, well-structured, production-ready, industry standard)
- Every prohibition must include an alternative
- Skill descriptions must NOT contain XML angle brackets (< or >) — use quotes or parentheses instead
- Skills must have ≥3 codebase-specific file references, kebab-case name, description with trigger phrases + negative scope
- Hooks must have shebang + set -euo pipefail, read stdin, and print actionable errors on exit 2
- Every hook script must have a matching settings_hooks entry
REVISION_FOOTER

    local raw_output
    raw_output=$(cat "$revision_prompt_file" | claude -p - \
        --model sonnet \
        --output-format json \
        --json-schema "$schema" \
        --allowedTools "Read" \
        --max-budget-usd "$AGENT_BUDGET" \
        2>>"$stderr_file")

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_warn "Revision agent failed (exit $exit_code). Proceeding with original artifacts."
        return 0
    fi

    # Track cost
    local rev_cost
    rev_cost=$(echo "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)
    record_cost "validate" "revision" "$rev_cost"

    local is_error
    is_error=$(echo "$raw_output" | jq -r '.is_error // false' 2>/dev/null)
    if [[ "$is_error" == "true" ]]; then
        log_warn "Revision agent returned an error. Proceeding with original artifacts."
        return 0
    fi

    # Extract and validate revised output
    local revised
    revised=$(echo "$raw_output" | jq '.structured_output // .result // .')

    if echo "$revised" | jq -e 'type == "object" and .claude_md' >/dev/null 2>&1; then
        echo "$revised" > "$WORK_DIR/synthesis/output.json"
        log_success "Artifacts revised successfully"
    else
        log_warn "Revision produced invalid output. Proceeding with original artifacts."
    fi

    return 0
}

__EOF_LIB_validate__

cat > "$BUNDLE_DIR/prompts/commands.md" <<'__EOF_PROMPT_commands__'
You are an expert at discovering build, test, and development commands in codebases.

Find every build, test, lint, format, and typecheck command in this project. Check ALL of these sources:

- **package.json** `scripts` section (and nested workspace package.json files)
- **Makefile** / **Justfile** targets
- **CI/CD pipelines**: `.github/workflows/*.yml`, `.gitlab-ci.yml`, `.circleci/config.yml`, `Jenkinsfile`, `bitbucket-pipelines.yml`
- **pyproject.toml** `[tool.poetry.scripts]`, `[project.scripts]`, or tox/nox config
- **Cargo.toml** — `cargo test`, `cargo build`, `cargo clippy`, `cargo fmt`
- **Taskfile.yml** (go-task)
- **docker-compose.yml** — service commands
- **Pre-commit hooks** — `.pre-commit-config.yaml`, `.husky/`

For each command found:
- **command**: the exact shell command to run
- **scope**: "project-wide" or a specific path/file scope (prefer file-scoped commands when available, e.g. `pytest tests/unit/` rather than just `pytest`)
- **ci_verified**: true if this command actually runs in a CI pipeline (check the CI config files)
- **source**: which file you found it in

Categorize each command as: build, test, lint, format, typecheck, or other.

__EOF_PROMPT_commands__

cat > "$BUNDLE_DIR/prompts/docs-scanner.md" <<'__EOF_PROMPT_docs-scanner__'
You are a documentation analyst. Find and summarize ALL existing documentation in this repository.

Scan for:

1. **README files** — README.md at root and in subdirectories/packages
2. **CONTRIBUTING.md** — contribution guidelines
3. **Architecture Decision Records (ADRs)** — docs/adr/, docs/decisions/, etc.
4. **docs/ directory** — any documentation directory contents
5. **API documentation** — OpenAPI/Swagger specs, GraphQL schemas, API docs
6. **Inline documentation patterns** — JSDoc, docstrings, rustdoc, godoc usage
7. **Existing AI config** — CLAUDE.md, .cursorrules, .cursor/, .aider*, .github/copilot* (read these in FULL)
8. **Changelogs** — CHANGELOG.md, HISTORY.md
9. **Wiki references** — links to external wikis or documentation sites

For each document:
- **path**: file path
- **type**: readme, contributing, adr, api_docs, architecture, ai_config, other
- **summary**: 2-sentence summary of its content

Then identify:
- **documented_conventions**: things that ARE documented (coding standards, PR process, etc.)
- **undocumented_gaps**: important conventions you can infer from the code but are NOT documented anywhere

__EOF_PROMPT_docs-scanner__

cat > "$BUNDLE_DIR/prompts/domain-researcher.md" <<'__EOF_PROMPT_domain-researcher__'
You are a domain research specialist. You receive information about a project's tech stack, purpose, and frameworks, and you research current best practices, common pitfalls, and domain-specific knowledge that would help an AI assistant work effectively in this codebase.

## Your Research Goals

1. **Domain Knowledge**: Research the business domain this project operates in. What terminology do practitioners use? What concepts map to code patterns? For example, if this is a healthcare app, terms like "HIPAA compliance", "HL7 FHIR", or "patient encounter" have specific technical meanings.

2. **Framework Best Practices**: For each detected framework AND its specific version, research:
   - Version-specific features and patterns (e.g., Svelte 5 runes vs Svelte 4 stores)
   - Migration patterns if the version is recent
   - Known issues or deprecations in that version
   - Recommended patterns from official docs

3. **Common Pitfalls**: What mistakes do developers commonly make with this tech stack combination? Focus on:
   - Version-specific gotchas
   - Cross-framework interaction issues (e.g., SvelteKit + FastAPI CORS)
   - Performance traps
   - Security anti-patterns

4. **Architectural Patterns**: What architectural patterns are commonly used for this type of application? Are the patterns found in the codebase standard or unusual?

## Research Approach

- Use web search to find current, version-specific information
- Focus on official documentation, not blog posts
- Prioritize information that would help an AI assistant make better decisions
- Everything must be relevant to THIS specific tech stack and versions — no generic advice

## What NOT to Do

- Don't research generic programming concepts
- Don't provide information the AI model already knows from training
- Focus on what's changed recently, what's version-specific, and what's non-obvious

__EOF_PROMPT_domain-researcher__

cat > "$BUNDLE_DIR/prompts/git-forensics.md" <<'__EOF_PROMPT_git-forensics__'
You are a git history analyst. Use ONLY git commands to analyze the repository history. Do not read file contents — only use `git log`, `git shortlog`, `git diff`, `git branch`, and similar git commands.

Analyze the git history to find:

1. **Hotspots** (top 20): Files that change most frequently. Use `git log --pretty=format: --name-only | sort | uniq -c | sort -rn | head -20`

2. **Temporal coupling** (top 10 pairs): Files that consistently change together in the same commits. Analyze co-occurrence in commits.

3. **Bug-fix density** (top 15): Files that appear most in commits containing "fix", "bug", "patch", "hotfix" in the message. Use `git log --grep` variants.

4. **Ownership diffusion**: Files touched by the most distinct authors. Use `git shortlog` or `git log --format='%aN' -- <file>`.

5. **Recent activity**: Directories with the most changes in the last 30 days. Use `git log --since="30 days ago"`.

6. **Commit message patterns**: Are conventional commits used (feat:, fix:, chore:, etc.)? Are ticket numbers referenced (JIRA-123, #456, etc.)? Provide 5 example recent commit messages.

7. **Branch naming patterns**: List patterns from recent branches using `git branch -r` or `git branch -a`.

If the repository has no history or very few commits, return empty arrays and note the limited history.

__EOF_PROMPT_git-forensics__

cat > "$BUNDLE_DIR/prompts/identity.md" <<'__EOF_PROMPT_identity__'
You are an expert codebase analyst. Your job is to determine the identity of this project.

Analyze the codebase in the current directory. Determine:

1. **Project name** — from package.json, Cargo.toml, pyproject.toml, go.mod, or directory name
2. **One-line description** — what this project does
3. **Primary languages** — with approximate percentage of codebase each represents. Count by file count or line count.
4. **Frameworks and versions** — detect from dependency files (package.json, requirements.txt, Cargo.toml, etc.)
5. **Monorepo detection** — is this a monorepo? Check for workspaces config, lerna.json, turbo.json, pnpm-workspace.yaml, nx.json. If yes, list all packages with their paths.
6. **Deployment target** — look for Dockerfile, vercel.json, netlify.toml, serverless.yml, fly.toml, render.yaml, AWS CDK/SAM files, k8s manifests
7. **Existing AI config** — check for CLAUDE.md, .cursorrules, .cursor/rules, .github/copilot, .aider, any AI-related config files

Be precise. Only report what you can verify from the files. If something is unclear, say so.

__EOF_PROMPT_identity__

cat > "$BUNDLE_DIR/prompts/mcp-discoverer.md" <<'__EOF_PROMPT_mcp-discoverer__'
You are an MCP (Model Context Protocol) server specialist. You research and recommend MCP servers that would be useful for developing a specific project.

## What Are MCP Servers?

MCP servers provide Claude Code with access to external tools and data sources — databases, APIs, documentation, browser automation, etc. They run as local processes and communicate via the MCP protocol.

## How to Find Servers

Search these registries in order:

### 1. Official MCP Registry (primary source)
Fetch: `https://registry.modelcontextprotocol.io/v0.1/servers?limit=96&search={query}&version=latest`
Request with `Accept: application/json`. This returns JSON with server metadata including package names, descriptions, and configuration.

Search for each detected technology: database names, framework names, cloud providers, etc.

### 2. GitHub MCP Organization
Fetch: `https://github.com/mcp?page=1&search={query}`
Request with `Accept: application/json`. This returns repositories from the official MCP GitHub organization.

Good searches: database names (postgres, mongodb, redis), tool names (playwright, puppeteer), service names (github, slack).

### 3. Web Search (supplementary)
Search for: "MCP server {technology}" or "modelcontextprotocol server {technology}".

## What to Recommend

Only recommend servers that are DIRECTLY relevant to the detected tech stack:

**Database servers** — if the project uses PostgreSQL, MongoDB, SQLite, Redis, etc., recommend the corresponding MCP server for read-only database access during development.

**Framework documentation servers** — `context7` (fetches up-to-date docs for any library) is almost always useful. Also look for framework-specific servers.

**API testing servers** — if the project exposes REST APIs.

**Browser automation** — `playwright` MCP for frontend projects that need UI debugging.

**Cloud/infrastructure** — if the project deploys to specific cloud providers.

## What NOT to Recommend

- Generic utility servers unrelated to the project's stack
- Servers from abandoned/unmaintained repos
- Servers requiring complex setup the developer won't have
- More than 8-10 servers (diminishing returns)

## Always Consider

- **context7** — up-to-date library documentation lookup. Useful for almost every project.
- **playwright** — if there's any frontend or browser-based testing
- Database servers matching the project's actual database

## Output Requirements

For each recommended server provide the exact `command` and `args` needed to run it via `npx`, `uvx`, or direct binary. Include any required environment variables with placeholder values.

__EOF_PROMPT_mcp-discoverer__

cat > "$BUNDLE_DIR/prompts/module-analyzer.md" <<'__EOF_PROMPT_module-analyzer__'
You are a deep codebase analyst. You are given a specific directory within a larger project. Your job is to produce an exhaustive analysis that another agent can use to generate Claude Code configuration (CLAUDE.md, skills, hooks, etc.).

Be THOROUGH. Read actual files. Don't guess from filenames alone — open files and understand patterns.

## What to Analyze

### 1. Purpose and Architecture
- What does this module/directory do? Why does it exist?
- How is it organized internally? What's the philosophy behind the structure?
- What are the subdirectories and what does each contain?
- How does data flow through this module? What are entry points and outputs?

### 2. Key Files
Identify the most important files a developer needs to know about. For each:
- What does it do?
- Why is it important?
- Is it critical (breaks everything if wrong), important (core patterns), or reference (good examples)?

Read at least 5-10 files to understand real patterns. Don't just list filenames.

### 3. Patterns
What architectural and coding patterns are used? For each pattern:
- Name it concretely (e.g., "Repository singleton with module-level instance", not "Repository pattern")
- Describe HOW to follow it (what to create, where to put it, how to wire it up)
- Cite 2-3 example files that demonstrate it

### 4. Conventions
- File naming: kebab-case? PascalCase? snake_case? How are files organized?
- Import style: absolute? relative? path aliases? ordering?
- Error handling: custom exceptions? error middleware? Result types? HTTP error patterns?
- Any other conventions specific to this area

### 5. Dependencies
- What other parts of the repo does this module import from?
- What key external libraries does it use and for what purpose?

### 6. Gotchas
What would trip up a developer unfamiliar with this code? For each gotcha:
- Describe the issue concretely
- Explain what to do instead

### 7. Skill Opportunities
Identify multi-step workflows that developers perform in this module that would benefit from being encoded as a Claude Code skill. For each:
- Name it (kebab-case, like "add-api-endpoint" or "create-database-migration")
- Describe what the skill would help with
- List the high-level steps in the workflow

Think about: scaffolding new entities, debugging common issues, performing migrations, adding new features that require touching multiple files, etc.

## Important
- READ actual source files, don't just look at directory listings
- Count and report real file numbers, don't estimate
- Reference specific file paths in your findings
- Be concrete, not abstract — "uses FastAPI Depends() for auth injection" not "uses dependency injection"

__EOF_PROMPT_module-analyzer__

cat > "$BUNDLE_DIR/prompts/patterns.md" <<'__EOF_PROMPT_patterns__'
You are a software architect analyzing codebase patterns and conventions.

Examine this codebase for architectural patterns and conventions. For EACH pattern you find, you MUST cite specific files as evidence. Do NOT invent patterns — only report what you can prove exists.

Look for:

1. **Architecture patterns**: Repository pattern, service layer, MVC/MVVM, hexagonal, clean architecture, CQRS, event-driven, etc. Which files implement each layer?

2. **Error handling**: Custom error classes, error middleware, Result types, try/catch conventions, error boundary patterns. Show the actual error classes/handlers.

3. **Import conventions**: Barrel exports (index.ts re-exports), path aliases (@/, ~/), absolute vs relative imports, import ordering conventions.

4. **Naming conventions**: File naming (kebab-case, PascalCase, snake_case), variable/function naming, class naming, constant naming. Check for consistency.

5. **State management**: Redux, Zustand, Context API, MobX, Vuex, Pinia, or backend equivalents. How is state organized?

6. **Authentication/authorization**: Auth middleware, JWT handling, session management, RBAC, permission checks. Where does auth live?

7. **Testing patterns**: Test file organization (co-located vs separate directory), mocking approach (jest.mock, dependency injection, test doubles), fixture patterns, test naming.

8. **Configuration**: Env vars (.env files), config modules, feature flags, secrets management approach.

For each pattern, report whether it is applied consistently or if there are inconsistencies.

__EOF_PROMPT_patterns__

cat > "$BUNDLE_DIR/prompts/security-scan.md" <<'__EOF_PROMPT_security-scan__'
You are a security-focused code analyst. Scan for files that should be PROTECTED from AI agent modification.

Find and categorize:

1. **Secrets and credentials**: .env files, *.pem, *.key, *.cert, credentials.json, service account files. Check .gitignore for patterns that suggest secret files exist.

2. **Migration files**: Database migration files (alembic, knex, prisma, django, ActiveRecord, flyway, etc.). These have strict ordering and should not be edited directly.

3. **Lock files**: package-lock.json, yarn.lock, pnpm-lock.yaml, Cargo.lock, poetry.lock, Pipfile.lock, go.sum, Gemfile.lock. These are generated and should never be hand-edited.

4. **Generated files**: Protobuf outputs, GraphQL codegen, OpenAPI client generation, compiled assets, auto-generated type declarations. Look for codegen configs and their output directories.

5. **CI/CD configs**: .github/workflows/, .gitlab-ci.yml, Jenkinsfile, deployment scripts. Dangerous if modified incorrectly.

6. **Security-critical code**: Authentication modules, cryptographic implementations, permission/RBAC logic, rate limiting, input validation/sanitization, CORS config. These need careful human review.

For each protected file/pattern:
- **path_pattern**: exact path or glob pattern
- **reason**: why it should be protected
- **safe_alternative**: what to do instead (e.g., "run `npx prisma migrate dev` to create new migrations")

__EOF_PROMPT_security-scan__

cat > "$BUNDLE_DIR/prompts/structure-scout.md" <<'__EOF_PROMPT_structure-scout__'
You are a codebase cartographer. Your job is to map the directory structure of this project and identify every directory that deserves deep analysis.

You are NOT doing deep analysis yourself — you are creating a map for other agents who will do the deep dives. Your job is to be thorough in identifying what's important.

## What to Do

1. Start by understanding the project type: monorepo? full-stack app? library? CLI tool?

2. Map the directory structure at least 3 levels deep. Use `find` and `ls` to understand the tree.

3. For EVERY significant directory, determine:
   - Its role (frontend, backend, tests, config, etc.)
   - Its priority (high for core business logic, medium for supporting code, low for config/assets)
   - Whether it should have its own CLAUDE.md (does it have distinct conventions?)

4. Be generous with what you mark as "high priority" — err on the side of including too many directories rather than too few. Deep directories matter too (e.g., `src/lib/components` is separate from `src/lib/stores`).

## What to Include

- ALL source code directories (frontend components, backend routers, models, services, utils)
- Test directories (unit, integration, e2e)
- Configuration and infrastructure (CI/CD, Docker, scripts)
- Documentation directories
- Type/schema directories
- Shared libraries

## What to Exclude

- `node_modules/`, `vendor/`, `__pycache__/`, `.git/`
- Build output (`dist/`, `build/`, `.next/`, `target/`)
- Hidden directories EXCEPT `.github/` and `.claude/`

## Be Thorough

A project like a full-stack web app should typically have 15-30 directories worth analyzing. A monorepo might have 50+. Don't stop at top-level directories — dig into `src/`, `backend/`, `packages/` etc. to find the important subdirectories.

__EOF_PROMPT_structure-scout__

cat > "$BUNDLE_DIR/prompts/synthesizer-docs.md" <<'__EOF_PROMPT_synthesizer-docs__'
You are an expert at writing Claude Code CLAUDE.md files. You receive exhaustive codebase analysis and must produce comprehensive, deeply-structured CLAUDE.md files.

This is Pass 1 of 2. You produce ONLY the documentation artifacts: root CLAUDE.md and subdirectory CLAUDE.md files. Skills, hooks, and agents are handled in Pass 2 by another agent.

## Core Principles

1. **Evidence over opinion.** Every line must trace to the findings.
2. **Dense, not brief.** Be as long as needed — a 300-line CLAUDE.md is fine if every line is load-bearing. Never artificially truncate.
3. **Don't duplicate tooling.** If a linter/formatter enforces it, don't put it in CLAUDE.md.
4. **Point, don't paste.** Reference real files rather than embedding code.
5. **Alternatives, not just prohibitions.** "Use Y instead of X", never just "Don't use X."

## Root CLAUDE.md Structure

```markdown
# {Project Name}

{One-line description.}

## Quick Reference

| Task | Command |
|------|---------|
{Every build/test/lint/format/typecheck command. Prefer CI-verified ones.}

## Architecture

### Overview
{2-3 paragraphs: major subsystems, how they communicate, deployment model.}

### Directory Structure
```
{Actual tree, 2-3 levels deep for important areas.}
```

### {Subsystem 1 — e.g., "Backend Architecture"}
{Deep dive: layers, patterns, data flow, philosophy. Reference key files.}

### {Subsystem 2 — e.g., "Frontend Architecture"}
{Same depth.}

### Key Abstractions
{The unique abstractions: base classes, patterns, design decisions.
 Each one: what it is, where it lives, how to use it, example file.}

## Patterns and Conventions

### {Pattern 1}
{Concrete description. How to follow it. Canonical example file.
 Include the registration/wiring steps people forget.}

### {Pattern 2}
{Same depth.}

### Naming Conventions
{Only what ISN'T enforced by tooling.}

### Import Conventions
{Only if non-standard.}

## Development Workflow

### Building and Running
### Testing
### Tooling

## Things to Know

{Critical gotchas. Each: what happens, why, what to do instead.}

## Security-Critical Areas

{Files needing human review. Auth flows. Crypto.}

## Domain Terminology

{Project-specific terms and their codebase meaning.}
```

### Quality Rules

- **Architecture section must be the longest section.** This is what makes it valuable.
- **Every convention references a real file.** "See `path/to/example.ts`"
- **No dangling facts.** Every statement in a section that gives it context.
- **Zero generic phrases.** Delete: "best practice", "clean code", "SOLID", "maintainable", "readable", "scalable", "well-structured", "production-ready", "industry standard".
- **Developer "never do" answers are mandatory.**

## Subdirectory CLAUDE.md Files

Generate for directories with distinct conventions. Each should be:
- **Self-contained** — developer working there shouldn't need root CLAUDE.md
- **References key files within that directory**
- **Documents module-specific patterns, commands, gotchas**

Aim for **5-15** subdirectory CLAUDE.md files for a substantial project.

Create one when:
- 3+ patterns differ from root
- Different language/framework
- Own build/test commands
- 10+ source files with distinct conventions

__EOF_PROMPT_synthesizer-docs__

cat > "$BUNDLE_DIR/prompts/synthesizer.md" <<'__EOF_PROMPT_synthesizer__'
You are an expert at creating Claude Code configurations. You receive exhaustive codebase analysis from multiple specialist agents and must produce a complete, production-grade Claude Code configuration.

Your input is a context document containing findings from: identity analysis, command discovery, git forensics, pattern detection, tooling analysis, documentation scanning, security scanning, structure mapping, deep directory analysis, developer answers, and optionally domain research.

## Core Principles

1. **Evidence over opinion.** Every line must trace to the findings. If you can't cite where you found it, delete it.

2. **Dense, not brief.** Your output should be as long as it needs to be. A 300-line CLAUDE.md that's load-bearing in every line is better than an 80-line one that's missing critical context. Don't artificially truncate — but don't pad either. Every line must earn its place.

3. **Don't duplicate tooling.** If a linter/formatter/hook enforces a rule, don't put it in CLAUDE.md. Check the TOOLING findings.

4. **Point, don't paste.** Reference real files rather than embedding code that goes stale. "See `src/middleware/auth.ts` for the pattern" beats a 20-line code block.

5. **Alternatives, not just prohibitions.** "Use Y instead of X", never just "Don't use X."

6. **The Portability Test.** Every skill and subagent must FAIL: "Could you drop this into an unrelated project and have it work unchanged?" If yes, it's generic.

---

## Output 1: Root CLAUDE.md

The most important artifact. Claude Code reads this at the start of every conversation. It should be comprehensive, deeply structured, and information-rich. Think of it as the senior engineer's brain dump — everything someone needs to know to work effectively in this codebase.

### Structure

```markdown
# {Project Name}

{One-line description. What this project IS, not what it aspires to be.}

## Quick Reference

| Task | Command |
|------|---------|
{Every build/test/lint/format/typecheck command from the commands findings.
 Prefer CI-verified commands. Include scope-specific variants.}

## Architecture

{This is THE most important section. It should be extensive and detailed.}

### Overview
{2-3 paragraphs explaining the high-level architecture: what the major
 subsystems are, how they communicate, what the deployment model is.
 Draw from identity, structure-scout, and module analysis findings.}

### Directory Structure
{A tree showing the project structure with one-line descriptions for each
 directory. Go 2-3 levels deep for important areas. This is the map
 engineers use to navigate the codebase.}

```
{actual directory tree}
```

### {Subsystem 1 — e.g., "Backend Architecture"}
{Deep dive into how this subsystem works. Layers, patterns, data flow.
 Reference key files. Explain the philosophy: why is it organized this way?}

### {Subsystem 2 — e.g., "Frontend Architecture"}
{Same depth for other major subsystems.}

### Key Abstractions
{The abstractions that make this codebase unique. Base classes, patterns,
 design decisions. Reference the files that implement them.}

## Patterns and Conventions

{NOT generic advice. Only patterns SPECIFIC to this codebase that a
 developer would get wrong without this guidance.}

### {Pattern Category 1 — e.g., "Data Model Pattern"}
{Describe the pattern concretely. How to follow it. Where to see examples.
 Include the registration/wiring steps people forget.}

### {Pattern Category 2 — e.g., "API Endpoint Pattern"}
{Same depth.}

### Naming Conventions
{File naming, class naming, function naming — only what ISN'T enforced by tooling.}

### Import Conventions
{Path aliases, ordering rules, absolute vs relative — only if non-standard.}

## Development Workflow

### Building and Running
{How to start the dev environment. Docker? Local? Both?}

### Testing
{Test framework, how tests are organized, how to run subsets.}

### Tooling
{What linters/formatters are configured. What hooks enforce automatically
 vs what must be run manually.}

## Things to Know

{Critical gotchas, non-obvious behaviors, common mistakes.
 Each entry: what happens, why, what to do instead.
 Draw from git-forensics bug_fix_density, module gotchas,
 developer "never_do" and "common_mistakes" answers.}

## Security-Critical Areas

{Files that need human review. Auth flows. Crypto.
 Draw from security-scan findings.}

## Domain Terminology

{Project-specific terms and what they mean in this codebase.
 Draw from module domain_terms.}
```

### Quality Rules

- **Architecture section must be extensive.** This is what makes the CLAUDE.md valuable. A shallow directory listing is useless — explain the layers, the data flow, the philosophy.
- **Every convention must reference a real file.** "See `path/to/example.ts` for the pattern."
- **No dangling facts.** Every statement should be in a section that gives it context. Don't randomly drop "Call Users.get_user_by_id() directly" without explaining the singleton repository pattern first.
- **Zero generic phrases.** Delete on sight: "best practice", "clean code", "SOLID principles", "maintainable", "readable", "scalable".
- **Developer answers are mandatory.** If they said "never X" or mentioned common mistakes, these MUST appear.

---

## Output 2: Subdirectory CLAUDE.md Files

Generate CLAUDE.md files for directories that have distinct conventions, patterns, or workflows that differ from the root. The structure-scout findings indicate which directories warrant their own CLAUDE.md (should_have_claude_md: true), but use your judgment based on the module analysis too.

**Generate one when:**
- A directory uses a different language or framework
- A directory has 3+ patterns that differ from the project root
- A directory has its own build/test commands
- A directory is large enough (10+ source files) and has distinct conventions

**Each subdirectory CLAUDE.md should:**
- Be self-contained — a developer working in that directory shouldn't need to flip back to root
- Reference key files within that directory
- Document patterns specific to that area
- Include module-specific commands and workflows
- List gotchas specific to that area

Aim for 5-15 subdirectory CLAUDE.md files for a project the size of a full-stack web app.

---

## Output 3: Skills

Skills are the workhorses of a Claude Code configuration. They encode multi-step, codebase-specific workflows. A well-configured project should have **10-30 skills** covering all major areas of development.

### Skill Categories to Consider

For each category below, look at the findings and create skills where the evidence supports them:

**Scaffolding Skills** (one per entity type):
- Adding a new API endpoint/route
- Creating a new database model/migration
- Adding a new frontend page/component
- Creating a new service/repository
- Adding a new test suite
- Setting up a new module/package (monorepos)

**Workflow Skills**:
- Code review (pre-PR checklist specific to this codebase)
- Running and debugging tests
- Lint and format workflow
- Branch management / PR preparation
- Deployment procedures

**Debugging Skills**:
- Debugging the backend (specific tools, log locations, common failures)
- Debugging the frontend (specific dev tools, state inspection)
- Debugging database issues (migration problems, query patterns)
- Debugging infrastructure (Docker, services, networking)

**Reference Skills** (encode domain knowledge):
- Framework-specific patterns (e.g., "how we use FastAPI", "our Svelte patterns")
- Event/messaging system reference (if applicable)
- Auth/permissions reference
- Configuration system reference
- State management reference

**Documentation Skills**:
- Update documentation
- Create Architecture Decision Records
- Document a feature

**Audit/Meta Skills**:
- Audit the CLAUDE.md for this project
- Review/create skills

### Skill Structure

Example skill frontmatter (adapt to each skill):

```yaml
---
name: add-api-endpoint
description: >
  Add a new FastAPI route handler to an existing Open WebUI router module.
  Use when user says "add an endpoint", "create a new route", "new API method",
  or "add a REST handler". Do NOT use for creating entirely new router files
  or for Socket.IO event handlers.
---
```

**Description rules:**
- ≥3 trigger phrases in natural language engineers would say
- ≥1 "Do NOT use for" boundary
- Under 1024 characters
- **NEVER use angle brackets (< or >) anywhere in the description field.** They break YAML parsing. Use quotes or parentheses instead. Wrong: "Use when user says <trigger>". Right: "Use when user says 'add endpoint'".

**Body rules:**
- Start with "## Before You Start" — point to 1-2 exemplar files
- Each step references real paths and commands
- End with "## Verify" — exact commands to validate
- Include "## Common Mistakes" — 2-4 real pitfalls from the findings
- ≥3 codebase-specific file references (hard minimum)
- Dense and detailed — a skill can be 100-500+ lines if the workflow is complex

### How Many Skills?

Look at the module analysis `skill_opportunities` field — each deep-dive agent identifies potential skills. Additionally, every major pattern, workflow, and entity type should have a skill if the creation process involves 3+ steps.

**Target: 10-30 skills** for a project of moderate complexity. This is not padding — each skill should encode a real workflow. If the codebase only has 5 distinct workflows, generate 5 skills.

---

## Output 4: Hooks

Hooks enforce rules deterministically. Only generate hooks for tooling that was ACTUALLY DETECTED.

| Event | Matcher | Use For |
|-------|---------|---------|
| PreToolUse | Write/Edit | Block writes to protected files (migrations, locks, secrets, generated files) |
| PostToolUse | Write/Edit | Run formatter on changed files (only if formatter is installed) |
| Stop | — | Run lint/typecheck as final check before completing |

**Hook script requirements:**
- `#!/usr/bin/env bash` + `set -euo pipefail`
- Read JSON from stdin
- Handle empty/irrelevant input (exit 0 early)
- Blocking hooks (exit 2) print actionable error message to stderr
- Every hook MUST have a matching `settings_hooks` entry

---

## Output 5: Subagents

Subagents run in isolated contexts with restricted tools. Create subagents for:
- **Review agents** (read-only tools) — code review, security review, architecture review
- **Analysis agents** — impact analysis, test gap analysis, dependency analysis
- **Documentation agents** — doc sync, doc generation

Each subagent's system prompt must:
- Tell the agent what to read first (orientation)
- Reference real file paths and patterns from this codebase (≥3)
- Specify what output format to return
- Use principle of least privilege for tools

Target: 3-8 subagents for a project of moderate complexity.

---

## Output 6: MCP Servers

Only recommend servers directly relevant to the detected tech stack. Each needs a clear reason tied to this project.

---

## Output 7: Settings Hooks

Wire every generated hook script. Each entry needs: event, matcher (for Pre/PostToolUse), command.

---

## Final Quality Checklist

Before returning:

- [ ] Root CLAUDE.md has a deep, multi-paragraph Architecture section
- [ ] Root CLAUDE.md references real file paths throughout
- [ ] Root CLAUDE.md has zero generic phrases
- [ ] Root CLAUDE.md includes developer "never do" answers
- [ ] Every prohibition includes an alternative
- [ ] Generated 5+ subdirectory CLAUDE.md files (where evidence supports them)
- [ ] Generated 10+ skills (where evidence supports them)
- [ ] Every skill has ≥3 codebase-specific file references
- [ ] Every skill has trigger phrases + negative scope in description
- [ ] Every skill ends with concrete verification commands
- [ ] Every hook has shebang + set -euo pipefail + reads stdin
- [ ] Every blocking hook prints actionable error
- [ ] Every hook has matching settings_hooks entry
- [ ] Subagent tools follow principle of least privilege
- [ ] No artifact could be dropped into an unrelated project unchanged (Portability Test)

__EOF_PROMPT_synthesizer__

cat > "$BUNDLE_DIR/prompts/synthesizer-tooling.md" <<'__EOF_PROMPT_synthesizer-tooling__'
You are an expert at creating Claude Code skills, hooks, and subagents. You receive exhaustive codebase analysis and must produce comprehensive, codebase-specific tooling.

This is Pass 2 of 2. The CLAUDE.md files were already created in Pass 1. You produce: skills, hooks, subagents, MCP server recommendations, and settings hook wiring.

## Core Principles

1. **The Portability Test.** Every skill and subagent must FAIL: "Could you drop this into an unrelated project unchanged?" If yes, it's too generic.
2. **Evidence over opinion.** Every instruction traces to the findings.
3. **Dense, not brief.** Skills can be 100-500+ lines if the workflow is complex.

## Skills

Skills encode multi-step, codebase-specific workflows. Aim for **10-30 skills**.

### Categories to Cover

**Scaffolding** (one per entity type found in the codebase):
- Adding a new API endpoint/route
- Creating a new database model/migration
- Adding a new frontend page/component
- Creating a new service/repository
- Adding a new test suite
- Any other entity types specific to this project

**Workflow**:
- Pre-PR checklist specific to this codebase
- Dev environment setup
- Running and debugging tests

**Debugging** (one per major subsystem):
- Debugging backend issues
- Debugging frontend issues
- Debugging data/pipeline issues

**Reference** (encode domain knowledge that's too detailed for CLAUDE.md):
- Framework-specific patterns
- Auth/permissions reference
- Configuration system reference

### Skill Format

```yaml
---
name: add-api-endpoint
description: >
  Add a new FastAPI route handler to an existing router module.
  Use when user says "add an endpoint", "create a new route", "new API method".
  Do NOT use for creating entirely new router files or Socket.IO handlers.
---
```

**CRITICAL: Skill descriptions must NEVER contain angle brackets (< or >).** They break YAML parsing. Use quotes or parentheses instead. Wrong: "Use for <task>". Right: "Use for adding endpoints".

**Description rules:**
- ≥3 trigger phrases in natural language
- ≥1 "Do NOT use for" boundary
- Under 1024 characters
- Zero angle brackets

**Body rules:**
- Start with "## Before You Start" — exemplar files to read
- Each step references real paths and commands
- End with "## Verify" — exact commands
- Include "## Common Mistakes" — 2-4 real pitfalls
- ≥3 codebase-specific file references

### Skill Opportunities from Findings

Check the `skill_opportunities` field in each module analysis finding. These are pre-identified workflows that should become skills.

## Hooks

Only for DETECTED tooling. Each hook:
- `#!/usr/bin/env bash` + `set -euo pipefail`
- Reads JSON from stdin
- Handles empty input (exit 0)
- Blocking (exit 2) prints actionable error to stderr
- Must have matching `settings_hooks` entry

| Event | Matcher | Use |
|-------|---------|-----|
| PreToolUse | Write/Edit | Block writes to protected files |
| PostToolUse | Write/Edit | Run formatter on changed files |
| Stop | — | Final lint/typecheck |

## Subagents

For isolated analysis tasks. Each system prompt:
- Tells agent what to read first
- References ≥3 real file paths
- Specifies output format
- Principle of least privilege for tools

Target: **3-8 subagents**.

## MCP Servers

Only servers directly relevant to the detected stack. Include configuration (command, args, env).

## Settings Hooks

Every hook script must have a matching entry. Each needs: event, matcher (for Pre/PostToolUse), command.

## Final Checklist

- [ ] Generated 10+ skills
- [ ] Every skill description has zero angle brackets
- [ ] Every skill has ≥3 codebase file references
- [ ] Every skill has trigger phrases + "Do NOT" boundary
- [ ] Every hook has shebang + pipefail + stdin + matching settings entry
- [ ] Subagent tools follow least privilege
- [ ] No artifact passes the Portability Test

__EOF_PROMPT_synthesizer-tooling__

cat > "$BUNDLE_DIR/prompts/tooling.md" <<'__EOF_PROMPT_tooling__'
You are a code quality tooling expert. Find every code quality tool configured in this project.

For each tool found:

1. **What is it?** (ESLint, Prettier, ruff, black, isort, mypy, pyright, clippy, rustfmt, golangci-lint, biome, oxlint, etc.)
2. **Config file path** — the exact file where it's configured
3. **Purpose** — what rules/conventions it enforces (summary, not exhaustive)
4. **CI enforced?** — does it run in a CI pipeline? (cross-reference with CI config files)
5. **Pre-commit hook?** — is it configured in .husky/, .pre-commit-config.yaml, or similar?
6. **Key rules** — list the most important/notable rules that are enabled, especially ones that relate to code style or architecture decisions

Check these config locations:
- `.eslintrc*`, `eslint.config.*`, `biome.json`
- `.prettierrc*`, `.editorconfig`
- `pyproject.toml` [tool.ruff], [tool.black], [tool.mypy], [tool.pyright]
- `rustfmt.toml`, `clippy.toml`
- `.golangci.yml`
- `tsconfig.json` (strict mode, paths, etc.)
- `.pre-commit-config.yaml`, `.husky/`
- `lefthook.yml`
- `lint-staged` config (in package.json or separate)

These tools represent rules that should NOT be duplicated in CLAUDE.md since they are already enforced automatically.

__EOF_PROMPT_tooling__

cat > "$BUNDLE_DIR/schemas/commands.json" <<'__EOF_SCHEMA_commands__'
{
  "type": "object",
  "required": ["build", "test", "lint", "format", "typecheck", "other"],
  "additionalProperties": false,
  "properties": {
    "build": { "$ref": "#/$defs/command_list" },
    "test": { "$ref": "#/$defs/command_list" },
    "lint": { "$ref": "#/$defs/command_list" },
    "format": { "$ref": "#/$defs/command_list" },
    "typecheck": { "$ref": "#/$defs/command_list" },
    "other": { "$ref": "#/$defs/command_list" }
  },
  "$defs": {
    "command_list": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["command", "scope", "ci_verified", "source"],
        "additionalProperties": false,
        "properties": {
          "command": { "type": "string" },
          "scope": {
            "type": "string",
            "description": "project-wide or file/directory scope"
          },
          "ci_verified": { "type": "boolean" },
          "source": {
            "type": "string",
            "description": "Where this command was found (e.g. package.json, Makefile)"
          }
        }
      }
    }
  }
}
__EOF_SCHEMA_commands__

cat > "$BUNDLE_DIR/schemas/docs.json" <<'__EOF_SCHEMA_docs__'
{
  "type": "object",
  "required": ["documents", "documented_conventions", "undocumented_gaps"],
  "additionalProperties": false,
  "properties": {
    "documents": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["path", "type", "summary"],
        "additionalProperties": false,
        "properties": {
          "path": { "type": "string" },
          "type": {
            "type": "string",
            "enum": ["readme", "contributing", "adr", "api_docs", "architecture", "ai_config", "other"]
          },
          "summary": {
            "type": "string",
            "description": "2-sentence summary of the document"
          }
        }
      }
    },
    "documented_conventions": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Conventions that are already documented"
    },
    "undocumented_gaps": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Important conventions that are NOT documented anywhere"
    }
  }
}
__EOF_SCHEMA_docs__

cat > "$BUNDLE_DIR/schemas/domain-research.json" <<'__EOF_SCHEMA_domain-research__'
{
  "type": "object",
  "required": ["domain_knowledge", "framework_practices", "common_pitfalls"],
  "additionalProperties": false,
  "properties": {
    "domain_knowledge": {
      "type": "array",
      "description": "Industry-specific terminology and concepts that map to code patterns",
      "items": {
        "type": "object",
        "required": ["concept", "relevance", "code_mapping"],
        "additionalProperties": false,
        "properties": {
          "concept": { "type": "string" },
          "relevance": { "type": "string", "description": "Why this matters for this codebase" },
          "code_mapping": { "type": "string", "description": "How this concept maps to specific code patterns or files" }
        }
      }
    },
    "framework_practices": {
      "type": "array",
      "description": "Best practices for the specific framework versions detected",
      "items": {
        "type": "object",
        "required": ["framework", "version", "practice", "relevance"],
        "additionalProperties": false,
        "properties": {
          "framework": { "type": "string" },
          "version": { "type": "string" },
          "practice": { "type": "string", "description": "The specific practice or pattern" },
          "relevance": { "type": "string", "description": "How this applies to this codebase specifically" }
        }
      }
    },
    "common_pitfalls": {
      "type": "array",
      "description": "Common mistakes developers make with this tech stack",
      "items": {
        "type": "object",
        "required": ["pitfall", "affected_area", "prevention"],
        "additionalProperties": false,
        "properties": {
          "pitfall": { "type": "string" },
          "affected_area": { "type": "string", "description": "Which part of the codebase this affects" },
          "prevention": { "type": "string", "description": "How to avoid this pitfall" }
        }
      }
    },
    "architectural_patterns": {
      "type": "array",
      "description": "Common architectural patterns for this type of application",
      "items": {
        "type": "object",
        "required": ["pattern", "applicability"],
        "additionalProperties": false,
        "properties": {
          "pattern": { "type": "string" },
          "applicability": { "type": "string", "description": "Whether/how this applies to the detected architecture" }
        }
      }
    }
  }
}
__EOF_SCHEMA_domain-research__

cat > "$BUNDLE_DIR/schemas/git-forensics.json" <<'__EOF_SCHEMA_git-forensics__'
{
  "type": "object",
  "required": ["hotspots", "temporal_coupling", "bug_fix_density", "ownership_diffusion", "recent_activity", "commit_patterns", "branch_patterns"],
  "additionalProperties": false,
  "properties": {
    "hotspots": {
      "type": "array",
      "description": "Top 20 most frequently changed files",
      "items": {
        "type": "object",
        "required": ["file", "change_count"],
        "additionalProperties": false,
        "properties": {
          "file": { "type": "string" },
          "change_count": { "type": "integer" }
        }
      }
    },
    "temporal_coupling": {
      "type": "array",
      "description": "Top 10 file pairs that consistently change together",
      "items": {
        "type": "object",
        "required": ["file_a", "file_b", "co_change_count"],
        "additionalProperties": false,
        "properties": {
          "file_a": { "type": "string" },
          "file_b": { "type": "string" },
          "co_change_count": { "type": "integer" }
        }
      }
    },
    "bug_fix_density": {
      "type": "array",
      "description": "Top 15 files appearing in bug-fix commits",
      "items": {
        "type": "object",
        "required": ["file", "fix_count"],
        "additionalProperties": false,
        "properties": {
          "file": { "type": "string" },
          "fix_count": { "type": "integer" }
        }
      }
    },
    "ownership_diffusion": {
      "type": "array",
      "description": "Files touched by the most distinct authors",
      "items": {
        "type": "object",
        "required": ["file", "author_count"],
        "additionalProperties": false,
        "properties": {
          "file": { "type": "string" },
          "author_count": { "type": "integer" }
        }
      }
    },
    "recent_activity": {
      "type": "array",
      "description": "Directories with most changes in the last 30 days",
      "items": {
        "type": "object",
        "required": ["directory", "change_count"],
        "additionalProperties": false,
        "properties": {
          "directory": { "type": "string" },
          "change_count": { "type": "integer" }
        }
      }
    },
    "commit_patterns": {
      "type": "object",
      "required": ["conventional_commits", "ticket_references", "example_messages"],
      "additionalProperties": false,
      "properties": {
        "conventional_commits": { "type": "boolean" },
        "ticket_references": {
          "type": "string",
          "description": "Pattern for ticket references (e.g. JIRA-123) or empty"
        },
        "example_messages": {
          "type": "array",
          "items": { "type": "string" }
        }
      }
    },
    "branch_patterns": {
      "type": "array",
      "description": "Branch naming patterns from recent branches",
      "items": { "type": "string" }
    }
  }
}
__EOF_SCHEMA_git-forensics__

cat > "$BUNDLE_DIR/schemas/identity.json" <<'__EOF_SCHEMA_identity__'
{
  "type": "object",
  "required": ["name", "description", "languages", "frameworks", "monorepo", "deployment"],
  "additionalProperties": false,
  "properties": {
    "name": {
      "type": "string",
      "description": "Project name"
    },
    "description": {
      "type": "string",
      "description": "One-line project description"
    },
    "languages": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "percentage"],
        "additionalProperties": false,
        "properties": {
          "name": { "type": "string" },
          "percentage": { "type": "number" }
        }
      }
    },
    "frameworks": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "version"],
        "additionalProperties": false,
        "properties": {
          "name": { "type": "string" },
          "version": { "type": "string" }
        }
      }
    },
    "monorepo": {
      "type": "boolean"
    },
    "packages": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "path"],
        "additionalProperties": false,
        "properties": {
          "name": { "type": "string" },
          "path": { "type": "string" }
        }
      }
    },
    "deployment": {
      "type": "string",
      "description": "Detected deployment target or empty string"
    },
    "existing_ai_config": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["file", "type"],
        "additionalProperties": false,
        "properties": {
          "file": { "type": "string" },
          "type": { "type": "string" }
        }
      }
    }
  }
}
__EOF_SCHEMA_identity__

cat > "$BUNDLE_DIR/schemas/mcp-recommendations.json" <<'__EOF_SCHEMA_mcp-recommendations__'
{
  "type": "object",
  "required": ["recommended_servers"],
  "additionalProperties": false,
  "properties": {
    "recommended_servers": {
      "type": "array",
      "description": "MCP servers that would be useful for developing this project",
      "items": {
        "type": "object",
        "required": ["name", "package", "description", "relevance", "configuration"],
        "additionalProperties": false,
        "properties": {
          "name": {
            "type": "string",
            "description": "Server name for mcp.json config"
          },
          "package": {
            "type": "string",
            "description": "npm or pip package name (e.g. '@modelcontextprotocol/server-postgres')"
          },
          "description": {
            "type": "string",
            "description": "What this MCP server does"
          },
          "relevance": {
            "type": "string",
            "description": "Why this server is specifically useful for THIS project"
          },
          "configuration": {
            "type": "object",
            "required": ["command", "args"],
            "additionalProperties": false,
            "properties": {
              "command": {
                "type": "string",
                "description": "Command to run (e.g. 'npx', 'uvx')"
              },
              "args": {
                "type": "array",
                "items": { "type": "string" },
                "description": "Command arguments"
              },
              "env": {
                "type": "object",
                "additionalProperties": { "type": "string" },
                "description": "Required environment variables with placeholder values"
              }
            }
          }
        }
      }
    }
  }
}
__EOF_SCHEMA_mcp-recommendations__

cat > "$BUNDLE_DIR/schemas/module-analysis.json" <<'__EOF_SCHEMA_module-analysis__'
{
  "type": "object",
  "required": ["module_path", "purpose", "architecture", "key_files", "patterns", "conventions", "dependencies", "gotchas"],
  "additionalProperties": false,
  "properties": {
    "module_path": {
      "type": "string"
    },
    "purpose": {
      "type": "string",
      "description": "2-3 sentence description of what this module does and why it exists"
    },
    "architecture": {
      "type": "object",
      "required": ["overview", "subdirectories", "data_flow"],
      "additionalProperties": false,
      "properties": {
        "overview": {
          "type": "string",
          "description": "How this module is organized internally — layers, patterns, philosophy"
        },
        "subdirectories": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["path", "purpose"],
            "additionalProperties": false,
            "properties": {
              "path": { "type": "string" },
              "purpose": { "type": "string" },
              "key_files": {
                "type": "array",
                "items": { "type": "string" },
                "description": "Most important files in this subdirectory"
              }
            }
          }
        },
        "data_flow": {
          "type": "string",
          "description": "How data flows through this module — entry points, transformations, outputs"
        }
      }
    },
    "key_files": {
      "type": "array",
      "description": "The most important files a developer should know about, with explanations",
      "items": {
        "type": "object",
        "required": ["path", "purpose", "importance"],
        "additionalProperties": false,
        "properties": {
          "path": { "type": "string" },
          "purpose": { "type": "string" },
          "importance": {
            "type": "string",
            "enum": ["critical", "important", "reference"],
            "description": "How important it is to understand this file"
          }
        }
      }
    },
    "patterns": {
      "type": "array",
      "description": "Architectural and coding patterns used within this module",
      "items": {
        "type": "object",
        "required": ["name", "description", "example_files"],
        "additionalProperties": false,
        "properties": {
          "name": { "type": "string" },
          "description": {
            "type": "string",
            "description": "Detailed description of the pattern including HOW to follow it"
          },
          "example_files": {
            "type": "array",
            "items": { "type": "string" },
            "description": "Files that exemplify this pattern"
          }
        }
      }
    },
    "conventions": {
      "type": "object",
      "required": ["naming", "imports", "error_handling"],
      "additionalProperties": false,
      "properties": {
        "naming": {
          "type": "string",
          "description": "File naming, class naming, function naming conventions specific to this module"
        },
        "imports": {
          "type": "string",
          "description": "Import style, ordering, path aliases used"
        },
        "error_handling": {
          "type": "string",
          "description": "How errors are handled — custom exceptions, error middleware, Result types"
        },
        "other": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Other conventions that don't fit above categories"
        }
      }
    },
    "dependencies": {
      "type": "object",
      "required": ["internal", "external_key"],
      "additionalProperties": false,
      "properties": {
        "internal": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Other modules/directories in this repo that this module depends on"
        },
        "external_key": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["name", "purpose"],
            "additionalProperties": false,
            "properties": {
              "name": { "type": "string" },
              "purpose": { "type": "string" }
            }
          },
          "description": "Key external dependencies and what they're used for"
        }
      }
    },
    "commands": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["command", "purpose"],
        "additionalProperties": false,
        "properties": {
          "command": { "type": "string" },
          "purpose": { "type": "string" }
        }
      }
    },
    "gotchas": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["issue", "solution"],
        "additionalProperties": false,
        "properties": {
          "issue": { "type": "string", "description": "The non-obvious behavior or pitfall" },
          "solution": { "type": "string", "description": "What to do instead or how to avoid it" }
        }
      },
      "description": "Non-obvious behaviors, pitfalls, things that would trip up a developer"
    },
    "domain_terms": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["term", "meaning"],
        "additionalProperties": false,
        "properties": {
          "term": { "type": "string" },
          "meaning": { "type": "string" }
        }
      }
    },
    "skill_opportunities": {
      "type": "array",
      "description": "Workflows in this module that would benefit from being a Claude Code skill",
      "items": {
        "type": "object",
        "required": ["name", "description", "workflow_steps"],
        "additionalProperties": false,
        "properties": {
          "name": { "type": "string", "description": "Proposed skill name in kebab-case" },
          "description": { "type": "string", "description": "What the skill would help with" },
          "workflow_steps": {
            "type": "array",
            "items": { "type": "string" },
            "description": "High-level steps in the workflow"
          }
        }
      }
    }
  }
}
__EOF_SCHEMA_module-analysis__

cat > "$BUNDLE_DIR/schemas/patterns.json" <<'__EOF_SCHEMA_patterns__'
{
  "type": "object",
  "required": ["patterns"],
  "additionalProperties": false,
  "properties": {
    "patterns": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "type", "evidence_files", "description", "is_consistent"],
        "additionalProperties": false,
        "properties": {
          "name": {
            "type": "string",
            "description": "Pattern name (e.g. Repository Pattern, Barrel Exports)"
          },
          "type": {
            "type": "string",
            "enum": ["architecture", "error_handling", "imports", "naming", "state_management", "auth", "testing", "configuration", "other"]
          },
          "evidence_files": {
            "type": "array",
            "items": { "type": "string" },
            "description": "File paths that demonstrate this pattern"
          },
          "description": {
            "type": "string",
            "description": "Concrete description of the pattern as used in this codebase"
          },
          "is_consistent": {
            "type": "boolean",
            "description": "Whether this pattern is applied consistently across the codebase"
          }
        }
      }
    }
  }
}
__EOF_SCHEMA_patterns__

cat > "$BUNDLE_DIR/schemas/security.json" <<'__EOF_SCHEMA_security__'
{
  "type": "object",
  "required": ["protected_files"],
  "additionalProperties": false,
  "properties": {
    "protected_files": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["path_pattern", "reason", "safe_alternative"],
        "additionalProperties": false,
        "properties": {
          "path_pattern": {
            "type": "string",
            "description": "File path or glob pattern"
          },
          "reason": {
            "type": "string",
            "description": "Why this file should be protected"
          },
          "safe_alternative": {
            "type": "string",
            "description": "What to do instead of editing this file directly"
          }
        }
      }
    }
  }
}
__EOF_SCHEMA_security__

cat > "$BUNDLE_DIR/schemas/structure-scout.json" <<'__EOF_SCHEMA_structure-scout__'
{
  "type": "object",
  "required": ["project_type", "directories"],
  "additionalProperties": false,
  "properties": {
    "project_type": {
      "type": "string",
      "enum": ["monorepo", "full-stack", "backend-only", "frontend-only", "library", "cli", "infrastructure", "other"],
      "description": "High-level project classification"
    },
    "primary_language": {
      "type": "string",
      "description": "The dominant language (e.g. TypeScript, Python, Rust)"
    },
    "architecture_summary": {
      "type": "string",
      "description": "2-3 sentence summary of the overall architecture and how major parts relate"
    },
    "directories": {
      "type": "array",
      "description": "Every directory worth deep analysis. Include ALL significant directories, not just top-level.",
      "items": {
        "type": "object",
        "required": ["path", "role", "priority", "description"],
        "additionalProperties": false,
        "properties": {
          "path": {
            "type": "string",
            "description": "Relative path from project root (e.g. 'src/lib/components', 'backend/app/routers')"
          },
          "role": {
            "type": "string",
            "enum": ["frontend-app", "frontend-components", "frontend-state", "frontend-api-client", "backend-app", "backend-routers", "backend-models", "backend-services", "backend-utils", "api-gateway", "database", "migrations", "tests", "e2e-tests", "documentation", "infrastructure", "ci-cd", "scripts", "config", "shared-lib", "types", "static-assets", "other"],
            "description": "The role this directory plays in the project"
          },
          "priority": {
            "type": "string",
            "enum": ["high", "medium", "low"],
            "description": "How important this directory is for understanding the codebase. High = core business logic, medium = supporting code, low = config/assets"
          },
          "description": {
            "type": "string",
            "description": "One-sentence description of what this directory contains"
          },
          "estimated_file_count": {
            "type": "integer",
            "description": "Approximate number of source files in this directory and its subdirectories"
          },
          "should_have_claude_md": {
            "type": "boolean",
            "description": "Whether this directory has enough distinct conventions to warrant its own CLAUDE.md"
          }
        }
      }
    }
  }
}
__EOF_SCHEMA_structure-scout__

cat > "$BUNDLE_DIR/schemas/synthesis-docs.json" <<'__EOF_SCHEMA_synthesis-docs__'
{
  "type": "object",
  "required": ["claude_md", "subdirectory_claude_mds"],
  "additionalProperties": false,
  "properties": {
    "claude_md": {
      "type": "string",
      "description": "The full contents of the root CLAUDE.md file. Markdown format. Be comprehensive — as long as needed, every line load-bearing."
    },
    "subdirectory_claude_mds": {
      "type": "array",
      "description": "CLAUDE.md files for subdirectories with distinct conventions. Aim for 5-15 files.",
      "items": {
        "type": "object",
        "required": ["path", "content"],
        "additionalProperties": false,
        "properties": {
          "path": {
            "type": "string",
            "description": "Relative directory path (e.g. 'backend', 'src/lib/components')"
          },
          "content": {
            "type": "string",
            "description": "Markdown content for this subdirectory CLAUDE.md. Self-contained, as detailed as needed."
          }
        }
      }
    }
  }
}
__EOF_SCHEMA_synthesis-docs__

cat > "$BUNDLE_DIR/schemas/synthesis-output.json" <<'__EOF_SCHEMA_synthesis-output__'
{
  "type": "object",
  "required": ["claude_md", "skills", "hooks"],
  "additionalProperties": false,
  "properties": {
    "claude_md": {
      "type": "string",
      "description": "The full contents of the root CLAUDE.md file. Markdown format. Be comprehensive — as long as needed, every line load-bearing."
    },
    "subdirectory_claude_mds": {
      "type": "array",
      "description": "CLAUDE.md files for subdirectories with distinct conventions",
      "items": {
        "type": "object",
        "required": ["path", "content"],
        "additionalProperties": false,
        "properties": {
          "path": {
            "type": "string",
            "description": "Relative directory path (e.g. 'backend', 'src/components')"
          },
          "content": {
            "type": "string",
            "description": "Markdown content for this subdirectory CLAUDE.md. Self-contained, as detailed as needed."
          }
        }
      }
    },
    "skills": {
      "type": "array",
      "description": "Claude Code skills for distinct functional areas",
      "items": {
        "type": "object",
        "required": ["name", "description", "content"],
        "additionalProperties": false,
        "properties": {
          "name": {
            "type": "string",
            "description": "Skill name (kebab-case, e.g. 'api-development')"
          },
          "description": {
            "type": "string",
            "description": "One-line description of what the skill covers"
          },
          "content": {
            "type": "string",
            "description": "Full SKILL.md content with YAML frontmatter and markdown body"
          }
        }
      }
    },
    "hooks": {
      "type": "array",
      "description": "Hook scripts for automated checks",
      "items": {
        "type": "object",
        "required": ["filename", "event", "description", "content"],
        "additionalProperties": false,
        "properties": {
          "filename": {
            "type": "string",
            "description": "Script filename (e.g. 'autoformat.sh')"
          },
          "event": {
            "type": "string",
            "enum": ["PreToolUse", "PostToolUse", "Notification", "Stop"],
            "description": "Hook event type"
          },
          "matcher": {
            "type": "string",
            "description": "Tool name matcher for PreToolUse/PostToolUse hooks (e.g. 'Write', 'Edit')"
          },
          "description": {
            "type": "string",
            "description": "What this hook does"
          },
          "content": {
            "type": "string",
            "description": "Full bash script content"
          }
        }
      }
    },
    "subagents": {
      "type": "array",
      "description": "Subagent definitions for complex workflows",
      "items": {
        "type": "object",
        "required": ["name", "description", "content"],
        "additionalProperties": false,
        "properties": {
          "name": {
            "type": "string",
            "description": "Agent name (kebab-case)"
          },
          "description": {
            "type": "string",
            "description": "One-line description"
          },
          "content": {
            "type": "string",
            "description": "Full agent markdown with YAML frontmatter"
          }
        }
      }
    },
    "mcp_servers": {
      "type": "array",
      "description": "Recommended MCP servers to configure",
      "items": {
        "type": "object",
        "required": ["name", "command", "args"],
        "additionalProperties": false,
        "properties": {
          "name": {
            "type": "string",
            "description": "Server name key for mcp.json"
          },
          "command": {
            "type": "string",
            "description": "Command to run (e.g. 'npx', 'uvx')"
          },
          "args": {
            "type": "array",
            "items": { "type": "string" },
            "description": "Command arguments"
          },
          "env": {
            "type": "object",
            "additionalProperties": { "type": "string" },
            "description": "Environment variables needed"
          },
          "reason": {
            "type": "string",
            "description": "Why this MCP server is useful for this project"
          }
        }
      }
    },
    "settings_hooks": {
      "type": "array",
      "description": "Hook entries for .claude/settings.json",
      "items": {
        "type": "object",
        "required": ["event", "command"],
        "additionalProperties": false,
        "properties": {
          "event": {
            "type": "string",
            "enum": ["PreToolUse", "PostToolUse", "Notification", "Stop"]
          },
          "matcher": {
            "type": "string",
            "description": "Tool name matcher (e.g. 'Write', 'Edit')"
          },
          "command": {
            "type": "string",
            "description": "Shell command to run (path to hook script)"
          }
        }
      }
    }
  }
}
__EOF_SCHEMA_synthesis-output__

cat > "$BUNDLE_DIR/schemas/synthesis-tooling.json" <<'__EOF_SCHEMA_synthesis-tooling__'
{
  "type": "object",
  "required": ["skills", "hooks"],
  "additionalProperties": false,
  "properties": {
    "skills": {
      "type": "array",
      "description": "Claude Code skills for distinct functional areas. Aim for 10-30 skills.",
      "items": {
        "type": "object",
        "required": ["name", "description", "content"],
        "additionalProperties": false,
        "properties": {
          "name": {
            "type": "string",
            "description": "Skill name (kebab-case, e.g. 'add-api-endpoint')"
          },
          "description": {
            "type": "string",
            "description": "One-line description of what the skill covers"
          },
          "content": {
            "type": "string",
            "description": "Full SKILL.md content with YAML frontmatter and markdown body"
          }
        }
      }
    },
    "hooks": {
      "type": "array",
      "description": "Hook scripts for automated checks",
      "items": {
        "type": "object",
        "required": ["filename", "event", "description", "content"],
        "additionalProperties": false,
        "properties": {
          "filename": {
            "type": "string",
            "description": "Script filename (e.g. 'autoformat.sh')"
          },
          "event": {
            "type": "string",
            "enum": ["PreToolUse", "PostToolUse", "Notification", "Stop"],
            "description": "Hook event type"
          },
          "matcher": {
            "type": "string",
            "description": "Tool name matcher for PreToolUse/PostToolUse hooks (e.g. 'Write', 'Edit')"
          },
          "description": {
            "type": "string",
            "description": "What this hook does"
          },
          "content": {
            "type": "string",
            "description": "Full bash script content"
          }
        }
      }
    },
    "subagents": {
      "type": "array",
      "description": "Subagent definitions for complex workflows. Aim for 3-8.",
      "items": {
        "type": "object",
        "required": ["name", "description", "content"],
        "additionalProperties": false,
        "properties": {
          "name": {
            "type": "string",
            "description": "Agent name (kebab-case)"
          },
          "description": {
            "type": "string",
            "description": "One-line description"
          },
          "content": {
            "type": "string",
            "description": "Full agent markdown with YAML frontmatter"
          }
        }
      }
    },
    "mcp_servers": {
      "type": "array",
      "description": "Recommended MCP servers to configure",
      "items": {
        "type": "object",
        "required": ["name", "command", "args"],
        "additionalProperties": false,
        "properties": {
          "name": {
            "type": "string",
            "description": "Server name key for mcp.json"
          },
          "command": {
            "type": "string",
            "description": "Command to run (e.g. 'npx', 'uvx')"
          },
          "args": {
            "type": "array",
            "items": { "type": "string" },
            "description": "Command arguments"
          },
          "env": {
            "type": "object",
            "additionalProperties": { "type": "string" },
            "description": "Environment variables needed"
          },
          "reason": {
            "type": "string",
            "description": "Why this MCP server is useful for this project"
          }
        }
      }
    },
    "settings_hooks": {
      "type": "array",
      "description": "Hook entries for .claude/settings.json",
      "items": {
        "type": "object",
        "required": ["event", "command"],
        "additionalProperties": false,
        "properties": {
          "event": {
            "type": "string",
            "enum": ["PreToolUse", "PostToolUse", "Notification", "Stop"]
          },
          "matcher": {
            "type": "string",
            "description": "Tool name matcher (e.g. 'Write', 'Edit')"
          },
          "command": {
            "type": "string",
            "description": "Shell command to run (path to hook script)"
          }
        }
      }
    }
  }
}
__EOF_SCHEMA_synthesis-tooling__

cat > "$BUNDLE_DIR/schemas/tooling.json" <<'__EOF_SCHEMA_tooling__'
{
  "type": "object",
  "required": ["tools"],
  "additionalProperties": false,
  "properties": {
    "tools": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "config_path", "purpose", "enforced_in_ci", "has_pre_commit"],
        "additionalProperties": false,
        "properties": {
          "name": {
            "type": "string",
            "description": "Tool name (e.g. ESLint, Prettier, ruff, mypy)"
          },
          "config_path": {
            "type": "string",
            "description": "Path to the tool's config file"
          },
          "purpose": {
            "type": "string",
            "description": "What the tool enforces (summary)"
          },
          "enforced_in_ci": {
            "type": "boolean"
          },
          "has_pre_commit": {
            "type": "boolean"
          },
          "key_rules": {
            "type": "array",
            "items": { "type": "string" },
            "description": "Notable rules that should NOT be duplicated in CLAUDE.md"
          }
        }
      }
    }
  }
}
__EOF_SCHEMA_tooling__

cat > "$BUNDLE_DIR/scripts/validate-skill.sh" <<'__EOF_SCRIPT_validate-skill__'
#!/usr/bin/env bash
# validate-skill.sh — Quality check for a SKILL.md file
# Usage: bash scripts/validate-skill.sh path/to/SKILL.md
set -euo pipefail

SKILL_PATH="${1:?Usage: validate-skill.sh <path-to-SKILL.md>}"
ERRORS=0
WARNINGS=0

if [ ! -f "$SKILL_PATH" ]; then
  echo "ERROR: File not found: $SKILL_PATH" >&2
  exit 1
fi

SKILL_DIR=$(dirname "$SKILL_PATH")
SKILL_NAME=$(basename "$SKILL_DIR")

echo "=== Validating skill: $SKILL_NAME ==="
echo ""

# --- Structural Checks ---

BASENAME=$(basename "$SKILL_PATH")
if [ "$BASENAME" != "SKILL.md" ]; then
  echo "ERROR: File must be named SKILL.md (got: $BASENAME)" >&2
  ERRORS=$((ERRORS + 1))
fi

# Folder naming (kebab-case)
if echo "$SKILL_NAME" | grep -qE '[A-Z _]'; then
  echo "ERROR: Folder name must be kebab-case (got: $SKILL_NAME)" >&2
  ERRORS=$((ERRORS + 1))
fi

# Frontmatter delimiters
if ! head -1 "$SKILL_PATH" | grep -q '^---$'; then
  echo "ERROR: Missing opening frontmatter delimiter (---)" >&2
  ERRORS=$((ERRORS + 1))
fi

FRONTMATTER_END=$(awk '/^---$/{n++; if(n==2){print NR; exit}}' "$SKILL_PATH")
if [ -z "$FRONTMATTER_END" ]; then
  echo "ERROR: Missing closing frontmatter delimiter (---)" >&2
  ERRORS=$((ERRORS + 1))
fi

# --- Frontmatter Field Checks ---

# name field
NAME_VAL=$(grep -m1 '^name:' "$SKILL_PATH" 2>/dev/null | sed 's/^name: *//' | tr -d '"'"'"'' || true)
if [ -z "$NAME_VAL" ]; then
  echo "ERROR: Missing required 'name' field in frontmatter" >&2
  ERRORS=$((ERRORS + 1))
elif [ "$NAME_VAL" != "$SKILL_NAME" ]; then
  echo "WARNING: name field ($NAME_VAL) does not match folder name ($SKILL_NAME)" >&2
  WARNINGS=$((WARNINGS + 1))
fi

# description field
DESC_LINE=$(grep -n '^description:' "$SKILL_PATH" 2>/dev/null | head -1 | cut -d: -f1 || true)
if [ -z "$DESC_LINE" ]; then
  echo "ERROR: Missing required 'description' field in frontmatter" >&2
  ERRORS=$((ERRORS + 1))
else
  DESC=$(awk -v start="$DESC_LINE" '
    NR==start { sub(/^description: */, ""); desc=$0; next }
    NR>start && /^  / { sub(/^  /, ""); desc=desc " " $0; next }
    NR>start { exit }
    END { print desc }
  ' "$SKILL_PATH")

  DESC_LEN=${#DESC}
  if [ "$DESC_LEN" -gt 1024 ]; then
    echo "ERROR: Description exceeds 1024 characters ($DESC_LEN chars)" >&2
    ERRORS=$((ERRORS + 1))
  fi

  # Trigger phrases
  if ! echo "$DESC" | grep -qiE '(use when|use for|trigger|invoke)'; then
    echo "WARNING: Description may be missing trigger phrases (WHEN to use)" >&2
    WARNINGS=$((WARNINGS + 1))
  fi

  # Negative scope
  if ! echo "$DESC" | grep -qiE '(do not use|don.t use|not for|instead use|do not trigger)'; then
    echo "WARNING: Description missing negative scope (WHEN NOT to use)" >&2
    WARNINGS=$((WARNINGS + 1))
  fi

  # XML angle brackets
  if echo "$DESC" | grep -qE '[<>]'; then
    echo "ERROR: Description contains XML angle brackets (< or >), which are forbidden" >&2
    ERRORS=$((ERRORS + 1))
  fi
fi

# --- Content Quality Checks ---

TOTAL_LINES=$(wc -l < "$SKILL_PATH")
WORD_COUNT=$(wc -w < "$SKILL_PATH")

echo "Size: $TOTAL_LINES lines, ~$WORD_COUNT words (~$(( WORD_COUNT * 13 / 10 )) tokens est.)"

if [ "$TOTAL_LINES" -gt 600 ]; then
  echo "WARNING: Skill is $TOTAL_LINES lines — consider splitting into multiple skills or moving reference material to a separate file" >&2
  WARNINGS=$((WARNINGS + 1))
fi

# Codebase-specific references
PATH_REFS=$(grep -cE '(`[a-zA-Z_./]+/[a-zA-Z_.]+`|apps/|packages/|src/|backend/|frontend/|scripts/|lib/)' "$SKILL_PATH" 2>/dev/null || true)
PATH_REFS=${PATH_REFS:-0}
echo "Codebase-specific path references: $PATH_REFS"

if [ "$PATH_REFS" -lt 3 ]; then
  echo "ERROR: Fewer than 3 codebase-specific references. Skill is too generic." >&2
  ERRORS=$((ERRORS + 1))
fi

# Verification step
if ! grep -qiE '(verif|## verify|## check|## test|## validate|## confirm)' "$SKILL_PATH"; then
  echo "WARNING: No verification section found. Skills should end with a concrete check." >&2
  WARNINGS=$((WARNINGS + 1))
fi

# Generic phrases
GENERIC_COUNT=$(grep -ciE '(best practice|clean code|solid principle|meaningful name|descriptive variable|proper error handling|well-structured|maintainable|readable code|industry standard|production.ready)' "$SKILL_PATH" 2>/dev/null || true)
GENERIC_COUNT=${GENERIC_COUNT:-0}
if [ "$GENERIC_COUNT" -gt 2 ]; then
  echo "WARNING: Found $GENERIC_COUNT generic programming phrases. Skill may not be codebase-specific enough." >&2
  WARNINGS=$((WARNINGS + 1))
fi

# --- Summary ---

echo ""
echo "=== Results ==="
echo "Errors:   $ERRORS"
echo "Warnings: $WARNINGS"

if [ "$ERRORS" -gt 0 ]; then
  echo "VERDICT: FAIL — fix $ERRORS error(s)" >&2
  exit 1
elif [ "$WARNINGS" -gt 3 ]; then
  echo "VERDICT: NEEDS REVISION — address warnings to improve quality" >&2
  exit 0
else
  echo "VERDICT: PASS"
  exit 0
fi

__EOF_SCRIPT_validate-skill__
chmod +x "$BUNDLE_DIR/scripts/validate-skill.sh"

cat > "$BUNDLE_DIR/scripts/validate-subagent.sh" <<'__EOF_SCRIPT_validate-subagent__'
#!/usr/bin/env bash
# validate-subagent.sh — Quality check for a subagent .md file
# Usage: bash scripts/validate-subagent.sh path/to/agent.md
set -euo pipefail

AGENT_PATH="${1:?Usage: validate-subagent.sh <path-to-agent.md>}"
ERRORS=0
WARNINGS=0

if [ ! -f "$AGENT_PATH" ]; then
  echo "ERROR: File not found: $AGENT_PATH" >&2
  exit 1
fi

AGENT_NAME=$(basename "$AGENT_PATH" .md)

echo "=== Validating subagent: $AGENT_NAME ==="
echo ""

# --- Structural Checks ---

if [[ "$AGENT_PATH" != *.md ]]; then
  echo "ERROR: Subagent file must have .md extension" >&2
  ERRORS=$((ERRORS + 1))
fi

# Filename naming (lowercase + hyphens)
if echo "$AGENT_NAME" | grep -qE '[A-Z ]'; then
  echo "WARNING: Agent filename should use lowercase-with-hyphens (got: $AGENT_NAME)" >&2
  WARNINGS=$((WARNINGS + 1))
fi

# Frontmatter delimiters
if ! head -1 "$AGENT_PATH" | grep -q '^---$'; then
  echo "ERROR: Missing opening frontmatter delimiter (---)" >&2
  ERRORS=$((ERRORS + 1))
fi

FRONTMATTER_END=$(awk '/^---$/{n++; if(n==2){print NR; exit}}' "$AGENT_PATH")
if [ -z "$FRONTMATTER_END" ]; then
  echo "ERROR: Missing closing frontmatter delimiter (---)" >&2
  ERRORS=$((ERRORS + 1))
fi

# --- Required Fields ---

# name field
NAME_VAL=$(grep -m1 '^name:' "$AGENT_PATH" 2>/dev/null | sed 's/^name: *//' | tr -d '"'"'"'' || true)
if [ -z "$NAME_VAL" ]; then
  echo "ERROR: Missing required 'name' field in frontmatter" >&2
  ERRORS=$((ERRORS + 1))
else
  if echo "$NAME_VAL" | grep -qE '[A-Z _]'; then
    echo "WARNING: name field should use lowercase-with-hyphens (got: $NAME_VAL)" >&2
    WARNINGS=$((WARNINGS + 1))
  fi
  if [ "$NAME_VAL" != "$AGENT_NAME" ]; then
    echo "WARNING: name field ($NAME_VAL) does not match filename ($AGENT_NAME)" >&2
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# description field
DESC_LINE=$(grep -n '^description:' "$AGENT_PATH" 2>/dev/null | head -1 | cut -d: -f1 || true)
if [ -z "$DESC_LINE" ]; then
  echo "ERROR: Missing required 'description' field in frontmatter" >&2
  ERRORS=$((ERRORS + 1))
else
  DESC=$(awk -v start="$DESC_LINE" '
    NR==start { sub(/^description: */, ""); desc=$0; next }
    NR>start && /^  / { sub(/^  /, ""); desc=desc " " $0; next }
    NR>start { exit }
    END { print desc }
  ' "$AGENT_PATH")

  if ! echo "$DESC" | grep -qiE '(use when|use for|use proactively|invoke)'; then
    echo "WARNING: Description may be missing trigger phrases" >&2
    WARNINGS=$((WARNINGS + 1))
  fi

  if ! echo "$DESC" | grep -qiE '(do not use|don.t use|not for)'; then
    echo "WARNING: Description missing scope boundary (WHEN NOT to use)" >&2
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# --- System Prompt Body ---

if [ -n "$FRONTMATTER_END" ]; then
  BODY_WORDS=$(tail -n +"$FRONTMATTER_END" "$AGENT_PATH" | tail -n +2 | wc -w)

  if [ "$BODY_WORDS" -lt 20 ]; then
    echo "WARNING: System prompt body is very short ($BODY_WORDS words). Subagents need enough context to operate independently." >&2
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# --- Configuration Checks ---

# model field
MODEL_VAL=$(grep -m1 '^model:' "$AGENT_PATH" 2>/dev/null | sed 's/^model: *//' | tr -d '"'"'"'' || true)
if [ -n "$MODEL_VAL" ]; then
  case "$MODEL_VAL" in
    sonnet|opus|haiku|inherit) ;;
    *)
      echo "WARNING: Unusual model value '$MODEL_VAL'. Expected: sonnet, opus, haiku, or inherit" >&2
      WARNINGS=$((WARNINGS + 1))
      ;;
  esac
fi

# bypassPermissions check
if grep -q 'permissionMode.*bypassPermissions' "$AGENT_PATH"; then
  echo "WARNING: bypassPermissions is set. Ensure this is intentional and sandboxed." >&2
  WARNINGS=$((WARNINGS + 1))
fi

# Tool scope check
TOOLS_VAL=$(grep -m1 '^tools:' "$AGENT_PATH" 2>/dev/null | sed 's/^tools: *//' || true)
if [ -z "$TOOLS_VAL" ]; then
  # Check if description suggests read-only intent
  if echo "${DESC:-}" | grep -qiE '(review|analyze|scan|explore|research|read)' && \
     ! echo "${DESC:-}" | grep -qiE '(fix|implement|create|write|modify|update|edit)'; then
    echo "WARNING: Agent description suggests read-only purpose but no 'tools' field set (inherits all). Consider restricting tools." >&2
    WARNINGS=$((WARNINGS + 1))
  fi
else
  if echo "${DESC:-}" | grep -qiE '(review|analyze|scan|audit|check)' && \
     ! echo "${DESC:-}" | grep -qiE '(fix|implement|create|write|modify|update)'; then
    if echo "$TOOLS_VAL" | grep -qiE '(Write|Edit)'; then
      echo "WARNING: Agent appears to be a reviewer/analyzer but has Write/Edit tools. Consider removing them." >&2
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
fi

# --- Codebase Specificity ---

TOTAL_LINES=$(wc -l < "$AGENT_PATH")
WORD_COUNT=$(wc -w < "$AGENT_PATH")
PATH_REFS=$(grep -cE '(`[a-zA-Z_./]+/[a-zA-Z_.]+`|apps/|packages/|src/|backend/|frontend/|scripts/|lib/|\.claude/)' "$AGENT_PATH" 2>/dev/null || true)
PATH_REFS=${PATH_REFS:-0}

echo "Size: $TOTAL_LINES lines, ~$WORD_COUNT words (~$(( WORD_COUNT * 13 / 10 )) tokens est.)"
echo "Codebase-specific references: $PATH_REFS"

if [ "$PATH_REFS" -lt 3 ]; then
  echo "WARNING: Fewer than 3 codebase-specific references. Agent may be too generic." >&2
  WARNINGS=$((WARNINGS + 1))
fi

# Generic phrases
GENERIC_COUNT=$(grep -ciE '(best practice|clean code|solid principle|meaningful name|descriptive variable|proper error handling|industry standard|well-structured|production.ready)' "$AGENT_PATH" 2>/dev/null || true)
GENERIC_COUNT=${GENERIC_COUNT:-0}
if [ "$GENERIC_COUNT" -gt 2 ]; then
  echo "WARNING: Found $GENERIC_COUNT generic programming phrases. System prompt may not be codebase-specific enough." >&2
  WARNINGS=$((WARNINGS + 1))
fi

# Overlap with built-in agents
if [ -n "$FRONTMATTER_END" ]; then
  BODY_LOWER=$(tail -n +"$FRONTMATTER_END" "$AGENT_PATH" | tr '[:upper:]' '[:lower:]')

  if echo "$BODY_LOWER" | grep -qE '(search|scan|find files|explore|discover)' && \
     ! echo "$BODY_LOWER" | grep -qE '(apps/|packages/|src/|backend/|specific)'; then
    echo "WARNING: Agent may overlap with built-in Explore agent. Ensure it adds codebase-specific knowledge." >&2
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# --- Summary ---

echo ""
echo "=== Results ==="
echo "Errors:   $ERRORS"
echo "Warnings: $WARNINGS"

if [ "$ERRORS" -gt 0 ]; then
  echo "VERDICT: FAIL — fix $ERRORS error(s)" >&2
  exit 1
elif [ "$WARNINGS" -gt 4 ]; then
  echo "VERDICT: NEEDS REVISION — address warnings to improve quality" >&2
  exit 0
else
  echo "VERDICT: PASS"
  exit 0
fi

__EOF_SCRIPT_validate-subagent__
chmod +x "$BUNDLE_DIR/scripts/validate-subagent.sh"

cat > "$BUNDLE_DIR/ultrainit.sh" <<'__EOF_MAIN__'
#!/usr/bin/env bash
set -euo pipefail

# ── Resolve script location ────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# ── Source libraries ────────────────────────────────────────────
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/agent.sh"
source "$SCRIPT_DIR/lib/gather.sh"
source "$SCRIPT_DIR/lib/ask.sh"
source "$SCRIPT_DIR/lib/research.sh"
source "$SCRIPT_DIR/lib/synthesize.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/merge.sh"

# ── Usage ───────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
ultrainit — Deep codebase analysis for Claude Code configuration

Usage: ultrainit.sh [OPTIONS] [PATH]

Options:
  --non-interactive    Skip developer questions (for CI/headless)
  --force              Rerun all agents (ignore cached findings)
  --overwrite          Remove existing CLAUDE.md, skills, hooks, and agents
                       before analysis (backs up to .ultrainit/backups/).
                       Implies --force. Use this for a clean re-generation.
  --model MODEL        Model for synthesis (default: sonnet[1m])
  --budget DOLLARS     Max USD per agent call (default: 5.00)
  --synth-budget USD   Max USD per synthesis pass (default: 20.00)
  --skip-research      Skip domain research and MCP discovery
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
  ULTRAINIT_BUDGET     Default per-agent budget (default: 5.00)
EOF
}

# ── Parse arguments ─────────────────────────────────────────────
TARGET_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE="true"; shift ;;
        --force)           FORCE="true"; shift ;;
        --overwrite)       OVERWRITE="true"; FORCE="true"; shift ;;
        --model)           SYNTH_MODEL="$2"; shift 2 ;;
        --budget)          AGENT_BUDGET="$2"; shift 2 ;;
        --synth-budget)    SYNTH_BUDGET="$2"; shift 2 ;;
        --skip-research)   SKIP_RESEARCH="true"; shift ;;
        --skip-mcp)        SKIP_MCP="true"; shift ;;
        --dry-run)         DRY_RUN="true"; shift ;;
        --verbose)         VERBOSE="true"; shift ;;
        -h|--help)         usage; exit 0 ;;
        -*)                log_error "Unknown option: $1"; usage; exit 1 ;;
        *)                 TARGET_DIR="$1"; shift ;;
    esac
done

# Default target is current directory
TARGET_DIR="${TARGET_DIR:-.}"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
export TARGET_DIR

# ── Banner ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}"
cat <<'BANNER'
       _ _             _       _ _
      | | |           (_)     (_) |
 _   _| | |_ _ __ __ _ _ _ __  _| |_
| | | | | __| '__/ _` | | '_ \| | __|
| |_| | | |_| | | (_| | | | | | | |_
 \__,_|_|\__|_|  \__,_|_|_| |_|_|\__|
BANNER
echo -e "${RESET}"
echo -e "  ${BOLD}Deep codebase analysis for Claude Code${RESET}"
echo -e "  Target: ${CYAN}${TARGET_DIR}${RESET}"
echo ""

# ── Preflight ───────────────────────────────────────────────────
detect_platform
check_dependencies
setup_work_dir "$TARGET_DIR"

log_info "Platform: $PLATFORM"
log_info "Working directory: $WORK_DIR"
log_info "Agent model: $AGENT_MODEL | Synthesis model: $SYNTH_MODEL"
log_info "Agent budget: \$$AGENT_BUDGET | Synthesis budget: \$$SYNTH_BUDGET"
echo ""

# ── Change to target directory ──────────────────────────────────
cd "$TARGET_DIR"

# ── Overwrite existing config if requested ─────────────────────
if [[ "$OVERWRITE" == "true" ]]; then
    overwrite_existing
fi

# ── Phase 1: GATHER ────────────────────────────────────────────
gather_evidence

# ── Phase 2: ASK ───────────────────────────────────────────────
ask_developer

# ── Phase 3: RESEARCH ──────────────────────────────────────────
if [[ "$SKIP_RESEARCH" != "true" ]]; then
    run_research
fi

# ── Phase 4: SYNTHESIZE ────────────────────────────────────────
synthesize

# ── Phase 5: VALIDATE & WRITE ──────────────────────────────────
validate_artifacts
write_artifacts

# ── Done ────────────────────────────────────────────────────────
echo ""
log_phase "Complete"
print_cost_summary
echo ""
log_success "Claude Code configuration generated for: $TARGET_DIR"

__EOF_MAIN__
chmod +x "$BUNDLE_DIR/ultrainit.sh"

# Pass through all arguments to the extracted script
exec bash "$BUNDLE_DIR/ultrainit.sh" "$@"
