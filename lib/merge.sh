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
