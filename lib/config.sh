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
    [[ "$agent_count" -lt 1 ]] && agent_count=1
    AGENT_BUDGET=$(echo "scale=2; $phase_budget / $agent_count" | bc)
    export AGENT_BUDGET
}

# ── Budget enforcement ──────────────────────────────────────────

# Check if we've exceeded the total budget. Returns 0 if OK, 1 if over.
check_budget() {
    local cost_file="$WORK_DIR/cost.log"
    [[ ! -f "$cost_file" ]] && return 0

    local spent
    spent=$(awk -F'|' '{ sum += $3 } END { printf "%.4f", sum }' "$cost_file" 2>/dev/null || echo "0")

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
    local cost_file="$WORK_DIR/cost.log"
    local spent="0"
    if [[ -f "$cost_file" ]]; then
        spent=$(awk -F'|' '{ sum += $3 } END { printf "%.4f", sum }' "$cost_file" 2>/dev/null || echo "0")
    fi
    echo "scale=2; $TOTAL_BUDGET - $spent" | bc 2>/dev/null || echo "$TOTAL_BUDGET"
}

# ── Budget warnings ────────────────────────────────────────────

check_budget_sanity() {
    local model="$SYNTH_MODEL"

    # Estimate minimum costs based on model
    local min_cost=10
    case "$model" in
        *opus*)  min_cost=25 ;;
        *sonnet*) min_cost=10 ;;
        *haiku*) min_cost=5 ;;
    esac

    if (( $(echo "$TOTAL_BUDGET < $min_cost" | bc 2>/dev/null || echo 0) )); then
        log_warn "Budget \$$TOTAL_BUDGET may be too low for model '$model' (recommended: \$$min_cost+)"
        log_warn "Consider increasing with --budget or using a cheaper model"
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
