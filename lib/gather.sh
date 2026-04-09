#!/usr/bin/env bash
# lib/gather.sh — Phase 1: Evidence gathering agents

gather_evidence() {
    log_phase "Phase 1: Gathering evidence"

    if is_phase_complete "gather" && [[ "$FORCE" != "true" ]]; then
        log_info "Phase 1 already complete. Use --force to rerun."
        return 0
    fi

    local schemas="$SCRIPT_DIR/schemas"

    # Set per-agent budget: gather phase gets 50% of total, split across agents
    # Stage 1 has 8 agents, stage 2 has N agents — estimate ~50 total
    export AGENT_PHASE="gather"
    set_agent_budget "$GATHER_BUDGET" 50

    # ── Stage 1: Core agents + structure scout in parallel ──────

    log_progress "Stage 1: Core analysis + structure mapping..."

    # Run all core agents in parallel; individual failures are tolerated
    run_agents_parallel \
        "run_agent identity \
            'Analyze this codebase. Determine the project identity: name, description, languages, frameworks, monorepo structure, deployment target, and existing AI config files.' \
            '$schemas/identity.json' \
            'Read,Bash(find:*),Bash(ls:*),Bash(cat:*),Bash(head:*)' \
            $AGENT_MODEL" \
        "run_agent commands \
            'Find every build, test, lint, format, and typecheck command in this project. Check package.json, Makefile, CI pipelines, pyproject.toml, Cargo.toml, and task runners. Note which are CI-verified.' \
            '$schemas/commands.json' \
            'Read,Bash(find:*),Bash(cat:*),Bash(grep:*),Bash(jq:*)' \
            $AGENT_MODEL" \
        "run_agent git-forensics \
            'Analyze the git history of this repository. Find hotspots, temporal coupling, bug-fix density, ownership diffusion, recent activity, commit patterns, and branch naming patterns.' \
            '$schemas/git-forensics.json' \
            'Bash(git:*)' \
            $AGENT_MODEL" \
        "run_agent patterns \
            'Examine this codebase for architectural patterns and conventions. Look for design patterns, error handling, import conventions, naming conventions, state management, auth patterns, testing patterns, and configuration management. Cite specific files as evidence.' \
            '$schemas/patterns.json' \
            'Read,Bash(find:*),Bash(grep:*),Glob' \
            $AGENT_MODEL" \
        "run_agent tooling \
            'Find every code quality tool configured in this project (linters, formatters, type checkers, pre-commit hooks). For each: name, config path, what it enforces, whether it runs in CI, and key rules.' \
            '$schemas/tooling.json' \
            'Read,Bash(find:*),Bash(cat:*),Bash(ls:*)' \
            $AGENT_MODEL" \
        "run_agent docs-scanner \
            'Find and summarize all existing documentation in this repo: READMEs, CONTRIBUTING, ADRs, docs directories, API docs, AI config files. Identify documented conventions and undocumented gaps.' \
            '$schemas/docs.json' \
            'Read,Bash(find:*),Bash(head:*),Bash(wc:*)' \
            $AGENT_MODEL" \
        "run_agent security-scan \
            'Scan for files that should be protected from AI agent modification: secrets, migrations, lock files, generated files, CI configs, and security-critical code.' \
            '$schemas/security.json' \
            'Read,Bash(find:*),Bash(grep:*),Bash(ls:*)' \
            $AGENT_MODEL" \
        "run_agent structure-scout \
            'Map the directory structure of this project. Identify EVERY directory that deserves deep analysis — dig at least 3 levels deep. Classify each by role and priority. Be thorough: a typical full-stack app has 15-30 directories worth analyzing.' \
            '$schemas/structure-scout.json' \
            'Bash(find:*),Bash(ls:*),Bash(wc:*),Read' \
            $AGENT_MODEL" \
        || true

    # ── Check for critical failures before proceeding ──────────
    # identity and structure-scout are required for downstream phases.
    # If more than 3 agents failed overall, something systemic is wrong.

    local core_agents=(identity commands git-forensics patterns tooling docs-scanner security-scan structure-scout)
    local critical_agents=(identity structure-scout)
    local failed_agents
    failed_agents=($(get_failed_agents "${core_agents[@]}"))
    local fail_count=${#failed_agents[@]}

    # Check critical agents first
    local critical_failed=()
    for agent in "${critical_agents[@]}"; do
        if [[ ! -f "$WORK_DIR/findings/${agent}.json" ]]; then
            critical_failed+=("$agent")
        fi
    done

    if [[ ${#critical_failed[@]} -gt 0 ]]; then
        log_error "Critical agent(s) failed: ${critical_failed[*]}"
        log_error "These are required for synthesis. Cannot continue."
        diagnose_phase_failure "gather" "${failed_agents[@]}"
        log_info "Fix the issue and re-run ultrainit. Successfully completed agents will be skipped."
        return 1
    fi

    if [[ $fail_count -ge 3 ]]; then
        log_error "$fail_count of ${#core_agents[@]} agents failed. This suggests a systemic issue."
        diagnose_phase_failure "gather" "${failed_agents[@]}"
        log_info "Fix the issue and re-run ultrainit. Successfully completed agents will be skipped."
        return 1
    fi

    if [[ $fail_count -gt 0 ]]; then
        log_warn "$fail_count agent(s) failed: ${failed_agents[*]} (continuing with partial results)"
    fi

    # ── Stage 2: Deep-dive agents per directory of interest ─────

    run_deep_dive_agents \
        || log_warn "Some Stage 2 deep-dive agents failed (non-fatal)"

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
        safe_name=$(echo "$dir_path" | sed 's|/|-|g; s|\.|-|g; s|[()]||g; s| ||g; s|^-||; s|-$||')

        # Skip empty names (e.g., from "." directory)
        if [[ -z "$safe_name" ]]; then
            safe_name="root"
        fi

        # Skip if already analyzed
        if [[ -f "$WORK_DIR/findings/module-${safe_name}.json" ]] && [[ "$FORCE" != "true" ]]; then
            log_info "Skipping module-${safe_name} (findings exist)"
            continue
        fi

        module_calls+=("run_agent module-${safe_name} \
            'Deeply analyze the directory at ${dir_path}/ in this project. This directory is classified as: ${dir_role}. Brief context: ${dir_desc}. Produce an exhaustive analysis covering: architecture and internal organization, key files (read at least 5-10 files), coding patterns with examples, conventions, dependencies, gotchas, and skill opportunities. Be thorough — read actual source files, not just directory listings.' \
            '$schemas/module-analysis.json' \
            'Read,Bash(find:*),Bash(grep:*),Bash(cat:*),Bash(wc:*),Bash(ls:*),Glob' \
            $AGENT_MODEL")
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
        safe_name=$(echo "$rel_name" | sed 's|/|-|g; s|\.|-|g; s| ||g; s|^-||; s|-$||')
        [[ -z "$safe_name" ]] && safe_name="root"

        module_calls+=("run_agent module-${safe_name} \
            'Deeply analyze the directory at ${rel_name}/ in this project. Produce an exhaustive analysis covering: architecture, key files, patterns, conventions, dependencies, gotchas, and skill opportunities.' \
            '$schemas/module-analysis.json' \
            'Read,Bash(find:*),Bash(grep:*),Bash(cat:*),Bash(wc:*),Bash(ls:*),Glob' \
            $AGENT_MODEL")
    done

    run_agents_parallel "${module_calls[@]}"
}
