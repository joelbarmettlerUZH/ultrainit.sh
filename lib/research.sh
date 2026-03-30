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
