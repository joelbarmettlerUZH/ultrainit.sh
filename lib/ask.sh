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
