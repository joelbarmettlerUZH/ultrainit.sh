#!/usr/bin/env bash
# lib/config.sh — Dependency checks, defaults, platform detection, budget

# ── Defaults (overridable via env or CLI flags) ─────────────────

export FORCE="${FORCE:-false}"
export NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
export VERBOSE="${VERBOSE:-false}"
export DRY_RUN="${DRY_RUN:-false}"
export SKIP_RESEARCH="${SKIP_RESEARCH:-false}"
export SKIP_MCP="${SKIP_MCP:-false}"
export OVERWRITE="${OVERWRITE:-false}"

export AGENT_MODEL="${ULTRAINIT_MODEL:-sonnet}"
export SYNTH_MODEL="${SYNTH_MODEL:-sonnet[1m]}"
export TOTAL_BUDGET="${ULTRAINIT_BUDGET:-100.00}"

# Allow large output from synthesis passes (default 32k is too small)
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-128000}"

# ── Budget allocation ───────────────────────────────────────────
#
# The total budget is split across phases:
#   Phase 1 (gather):     50%  — 8 core agents + N deep-dive agents
#   Phase 3 (research):   10%  — 2 research agents
#   Phase 4 (synthesis):  30%  — 2 synthesis passes (most expensive)
#   Phase 5 (validation): 10%  — optional revision agent
#
# Within each phase, the budget is divided equally among agents.
# Estimated costs per model per call:
#   haiku:       $0.02–0.15
#   sonnet:      $0.10–0.80
#   sonnet[1m]:  $1.00–5.00
#   opus[1m]:    $3.00–15.00

BUDGET_PCT_GATHER=50
BUDGET_PCT_RESEARCH=10
BUDGET_PCT_SYNTHESIS=30
BUDGET_PCT_VALIDATION=10

# Computed per-phase budgets (set in compute_budgets)
# These are computed by compute_budgets() and must survive child re-sourcing
export GATHER_BUDGET="${GATHER_BUDGET:-}"
export RESEARCH_BUDGET="${RESEARCH_BUDGET:-}"
export SYNTH_BUDGET="${SYNTH_BUDGET:-}"
export VALIDATION_BUDGET="${VALIDATION_BUDGET:-}"
export AGENT_BUDGET="${AGENT_BUDGET:-}"

compute_budgets() {
    # Default to 100.00 if TOTAL_BUDGET is empty or non-numeric
    if [[ -z "$TOTAL_BUDGET" ]] || ! echo "$TOTAL_BUDGET" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
        TOTAL_BUDGET="100.00"
    fi

    GATHER_BUDGET=$(echo "scale=2; $TOTAL_BUDGET * $BUDGET_PCT_GATHER / 100" | bc)
    RESEARCH_BUDGET=$(echo "scale=2; $TOTAL_BUDGET * $BUDGET_PCT_RESEARCH / 100" | bc)
    SYNTH_BUDGET=$(echo "scale=2; $TOTAL_BUDGET * $BUDGET_PCT_SYNTHESIS / 100" | bc)
    VALIDATION_BUDGET=$(echo "scale=2; $TOTAL_BUDGET * $BUDGET_PCT_VALIDATION / 100" | bc)

    export GATHER_BUDGET RESEARCH_BUDGET SYNTH_BUDGET VALIDATION_BUDGET
}

# Set per-agent budget for a phase given the number of agents.
# Usage: set_agent_budget <phase_budget> <agent_count>
set_agent_budget() {
    local phase_budget="$1"
    local agent_count="$2"

    # Default phase_budget to 1.00 if empty or non-numeric
    if [[ -z "$phase_budget" ]] || ! echo "$phase_budget" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
        phase_budget="1.00"
    fi

    # Ensure agent_count is a positive integer
    if ! [[ "$agent_count" =~ ^[0-9]+$ ]] || [[ "$agent_count" -lt 1 ]]; then
        agent_count=1
    fi

    AGENT_BUDGET=$(echo "scale=2; $phase_budget / $agent_count" | bc)
    export AGENT_BUDGET
}

# ── Budget enforcement ──────────────────────────────────────────

# Check if we've exceeded the total budget. Returns 0 if OK, 1 if over.
# Reads per-agent cost files from $WORK_DIR/costs/ (one file per agent,
# no shared file, so parallel agents can't corrupt each other's data).
check_budget() {
    local cost_dir="$WORK_DIR/costs"
    [[ ! -d "$cost_dir" ]] && return 0

    # Guard: with nullglob, *.cost expands to nothing if no files exist,
    # causing cat (no args) to block on stdin. Check for files first.
    local cost_files=("$cost_dir"/*.cost)
    [[ ${#cost_files[@]} -eq 0 || ! -f "${cost_files[0]}" ]] && return 0

    local spent
    spent=$(cat "${cost_files[@]}" 2>/dev/null | awk -F'|' '{ sum += $3 } END { printf "%.4f", sum }' 2>/dev/null || echo "0")

    local over
    over=$(echo "$spent >= $TOTAL_BUDGET" | bc 2>/dev/null || echo "0")

    if [[ "$over" == "1" ]]; then
        log_warn "Budget exhausted: \$$spent spent of \$$TOTAL_BUDGET total"
        return 1
    fi
    return 0
}

# Get remaining budget
get_remaining_budget() {
    local cost_dir="$WORK_DIR/costs"
    local spent="0"
    if [[ -d "$cost_dir" ]]; then
        local cost_files=("$cost_dir"/*.cost)
        if [[ ${#cost_files[@]} -gt 0 && -f "${cost_files[0]}" ]]; then
            spent=$(cat "${cost_files[@]}" 2>/dev/null | awk -F'|' '{ sum += $3 } END { printf "%.4f", sum }' 2>/dev/null || echo "0")
        fi
    fi
    echo "scale=2; $TOTAL_BUDGET - $spent" | bc 2>/dev/null || echo "$TOTAL_BUDGET"
}

# ── Budget warnings ────────────────────────────────────────────

check_budget_sanity() {
    local model="$SYNTH_MODEL"
    local agent_model="$AGENT_MODEL"

    # Minimum viable budget depends on both gather model and synthesis model.
    # Each claude -p call costs at least $0.05 (haiku) to $0.30 (sonnet) for
    # schema caching alone. With 8 core agents + 2 synthesis passes minimum:
    local min_cost=10
    case "$model" in
        *opus*)  min_cost=25 ;;
        *sonnet*) min_cost=10 ;;
        *haiku*) min_cost=3 ;;
    esac

    if (( $(echo "$TOTAL_BUDGET < $min_cost" | bc 2>/dev/null || echo 0) )); then
        log_warn "Budget \$$TOTAL_BUDGET may be too low for model '$model' (recommended: \$$min_cost+)"
        log_warn "Consider increasing with --budget or using a cheaper model"
    fi

    # Check per-agent budget viability: gather phase splits across ~50 agents.
    # If per-agent budget is below the minimum for a single API call, warn loudly.
    local per_agent_budget
    per_agent_budget=$(echo "scale=2; $GATHER_BUDGET / 50" | bc 2>/dev/null || echo "0")
    local min_per_agent="0.10"
    case "$agent_model" in
        *opus*)  min_per_agent="0.50" ;;
        *sonnet*) min_per_agent="0.20" ;;
        *haiku*) min_per_agent="0.10" ;;
    esac

    if (( $(echo "$per_agent_budget < $min_per_agent" | bc 2>/dev/null || echo 0) )); then
        log_error "Per-agent budget is \$$per_agent_budget — too low for even one $agent_model call (minimum ~\$$min_per_agent)"
        log_error "Increase --budget to at least \$$(echo "scale=0; $min_per_agent * 50 / 0.5 + 1" | bc) or use a cheaper model"
        exit 1
    fi
}

# ── Platform detection ──────────────────────────────────────────

detect_platform() {
    case "$(uname -s)" in
        Darwin)  PLATFORM="macos" ;;
        Linux)   PLATFORM="linux" ;;
        MINGW*|MSYS*|CYGWIN*)  PLATFORM="windows" ;;
        *)
            PLATFORM="unknown"
            log_warn "Unrecognized platform: $(uname -s)"
            log_warn "ultrainit is tested on macOS, Linux, and Windows (Git Bash)."
            log_warn "On Windows, use Git Bash (included with Git for Windows):"
            log_warn "  https://git-scm.com/download/win"
            log_warn "Continuing anyway, but some tools may be missing."
            ;;
    esac
    export PLATFORM
}

# ── Dependency checks ──────────────────────────────────────────

check_dependencies() {
    local missing=0

    # claude CLI: required for all agent calls
    if ! command -v claude &>/dev/null; then
        log_error "claude CLI not found. Install: https://docs.anthropic.com/en/docs/claude-code/overview"
        missing=1
    elif ! claude auth status 2>/dev/null | jq -e '.loggedIn == true' &>/dev/null; then
        log_error "claude is installed but not logged in. Run: claude auth login"
        missing=1
    fi

    # jq: required for all JSON processing
    if ! command -v jq &>/dev/null; then
        log_error "jq not found."
        case "$PLATFORM" in
            macos)   log_error "  Install: brew install jq" ;;
            linux)   log_error "  Install: sudo apt install jq  (or your package manager)" ;;
            windows) log_error "  Install: choco install jq  (in Git Bash)" ;;
        esac
        missing=1
    fi

    # git: required for git-forensics agent and history analysis
    if ! command -v git &>/dev/null; then
        log_error "git not found."
        case "$PLATFORM" in
            macos)   log_error "  Install: brew install git" ;;
            linux)   log_error "  Install: sudo apt install git  (or your package manager)" ;;
            windows) log_error "  Install: https://git-scm.com/download/win" ;;
        esac
        missing=1
    fi

    # bc: required for budget arithmetic calculations
    if ! command -v bc &>/dev/null; then
        log_error "bc not found."
        case "$PLATFORM" in
            macos)   log_error "  Install: brew install bc" ;;
            linux)   log_error "  Install: sudo apt install bc  (or your package manager)" ;;
            windows) log_error "  Install: choco install bc  (in Git Bash)" ;;
        esac
        missing=1
    fi

    # mktemp: required for safe temporary file/directory creation
    if ! command -v mktemp &>/dev/null; then
        log_error "mktemp not found."
        case "$PLATFORM" in
            macos)   log_error "  Install: brew install coreutils" ;;
            linux)   log_error "  Install: sudo apt install coreutils  (or your package manager)" ;;
            windows) log_error "  mktemp should be available in Git Bash; try reinstalling Git for Windows" ;;
        esac
        missing=1
    fi

    # sed: required for text processing in synthesis and validation
    if ! command -v sed &>/dev/null; then
        log_error "sed not found."
        case "$PLATFORM" in
            macos)   log_error "  Install: should be preinstalled; try: brew install gnu-sed" ;;
            linux)   log_error "  Install: sudo apt install sed  (or your package manager)" ;;
            windows) log_error "  sed should be available in Git Bash; try reinstalling Git for Windows" ;;
        esac
        missing=1
    fi

    # awk: required for text processing in config and validation
    if ! command -v awk &>/dev/null; then
        log_error "awk not found."
        case "$PLATFORM" in
            macos)   log_error "  Install: should be preinstalled; try: brew install gawk" ;;
            linux)   log_error "  Install: sudo apt install gawk  (or your package manager)" ;;
            windows) log_error "  awk should be available in Git Bash; try reinstalling Git for Windows" ;;
        esac
        missing=1
    fi

    # grep: required for pattern matching throughout the pipeline
    if ! command -v grep &>/dev/null; then
        log_error "grep not found."
        case "$PLATFORM" in
            macos)   log_error "  Install: should be preinstalled; try: brew install grep" ;;
            linux)   log_error "  Install: sudo apt install grep  (or your package manager)" ;;
            windows) log_error "  grep should be available in Git Bash; try reinstalling Git for Windows" ;;
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

    mkdir -p "$WORK_DIR"/{findings/modules,synthesis/skills,synthesis/hooks,synthesis/subagents,logs,backups,costs,prompts}

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
