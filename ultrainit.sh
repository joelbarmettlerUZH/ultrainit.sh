#!/usr/bin/env bash
set -euo pipefail

# ── Windows shell check ───────────────────────────────────────
# If someone runs this from CMD or PowerShell, bash may not be
# available or may lack the features we need. Detect and warn early.
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "ERROR: ultrainit requires bash. You appear to be running a different shell." >&2
    echo "" >&2
    echo "On Windows, use Git Bash (included with Git for Windows):" >&2
    echo "  1. Install Git for Windows: https://git-scm.com/download/win" >&2
    echo "  2. Open 'Git Bash' from the Start menu" >&2
    echo "  3. Re-run this script from Git Bash" >&2
    exit 1
fi

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

# ── Banner ──────────────────────────────────────────────────────
print_banner() {
    local R='\033[0;31m' O='\033[38;5;208m' Y='\033[0;33m' G='\033[0;32m' V='\033[0;35m' B='\033[0;34m' P='\033[38;5;213m' X='\033[0m'
    echo ""
    echo -e "${R}▗▖ ▗▖${O}▗▖ ${Y}▗▄▄▄▖${G}▗▄▄▖ ${V} ▗▄▖ ${B}▗▄▄▄▖${P}▗▖  ▗▖${R}▗▄▄▄▖${O}▗▄▄▄▖${X}"
    echo -e "${R}▐▌ ▐▌${O}▐▌ ${Y}  █  ${G}▐▌ ▐▌${V}▐▌ ▐▌${B}  █  ${P}▐▛▚▖▐▌${R}  █  ${O}  █  ${X}"
    echo -e "${R}▐▌ ▐▌${O}▐▌ ${Y}  █  ${G}▐▛▀▚▖${V}▐▛▀▜▌${B}  █  ${P}▐▌ ▝▜▌${R}  █  ${O}  █  ${X}"
    echo -e "${R}▝▚▄▞▘${O}▐▙▄▄▖${Y}█  ${G}▐▌ ▐▌${V}▐▌ ▐▌${B}▗▄█▄▖${P}▐▌  ▐▌${R}▗▄█▄▖${O}  █  ${X}"
}

# ── Usage ───────────────────────────────────────────────────────
usage() {
    print_banner
    cat <<'EOF'
Deep codebase analysis for Claude Code configuration

Usage: ultrainit.sh [OPTIONS] [PATH]

Options:
  --non-interactive    Skip developer questions (for CI/headless)
  --force              Rerun all agents (ignore cached findings)
  --overwrite          Remove existing CLAUDE.md, skills, hooks, and agents
                       before analysis (backs up to .ultrainit/backups/).
                       Implies --force. Use this for a clean re-generation.
  --model MODEL        Model for synthesis (default: sonnet[1m])
  --budget DOLLARS     Total budget for the entire run (default: 100.00).
                       Automatically divided across phases and agents.
                       The run stops when the budget is exhausted.
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
  ultrainit.sh --budget 50               # Lower budget for small projects

Environment:
  ULTRAINIT_MODEL      Default model for gather agents (default: sonnet)
  ULTRAINIT_BUDGET     Total budget in USD (default: 100.00)
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
        --budget)          TOTAL_BUDGET="$2"; shift 2 ;;
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

print_banner
echo -e "  ${BOLD}Deep codebase analysis for Claude Code${RESET}"
echo -e "  Target: ${CYAN}${TARGET_DIR}${RESET}"
echo ""

# ── Preflight ───────────────────────────────────────────────────
detect_platform
check_dependencies
setup_work_dir "$TARGET_DIR"

compute_budgets
check_budget_sanity

log_info "Platform: $PLATFORM"
log_info "Working directory: $WORK_DIR"
log_info "Agent model: $AGENT_MODEL | Synthesis model: $SYNTH_MODEL"
log_info "Total budget: \$$TOTAL_BUDGET (gather: \$$GATHER_BUDGET | research: \$$RESEARCH_BUDGET | synthesis: \$$SYNTH_BUDGET | validation: \$$VALIDATION_BUDGET)"

# Show remaining budget if resuming a previous run
remaining=$(get_remaining_budget)
if [[ "$remaining" != "$TOTAL_BUDGET" ]]; then
    log_info "Resuming: \$$remaining remaining from \$$TOTAL_BUDGET budget"
fi
echo ""

# ── Change to target directory ──────────────────────────────────
cd "$TARGET_DIR"

# ── Overwrite existing config if requested ─────────────────────
if [[ "$OVERWRITE" == "true" ]]; then
    overwrite_existing
fi

# ── Phase 1: GATHER ────────────────────────────────────────────
if ! gather_evidence; then
    echo ""
    print_cost_summary
    log_error "Phase 1 (gather) failed. Exiting."
    log_info "Re-run ultrainit after fixing the issue. Successful agents will be skipped."
    exit 1
fi

# ── Phase 2: ASK ───────────────────────────────────────────────
ask_developer

# ── Phase 3: RESEARCH ──────────────────────────────────────────
if [[ "$SKIP_RESEARCH" != "true" ]]; then
    run_research
fi

# ── Phase 4: SYNTHESIZE ────────────────────────────────────────
if ! synthesize; then
    echo ""
    diagnose_phase_failure "synthesize" "synthesis-docs" "synthesis-tooling"
    print_cost_summary
    log_error "Phase 4 (synthesis) failed. Exiting."
    log_info "Re-run ultrainit to retry synthesis. Gather and research phases will be skipped."
    exit 1
fi

# ── Phase 5: VALIDATE & WRITE ──────────────────────────────────
validate_artifacts
write_artifacts

# ── Done ────────────────────────────────────────────────────────
echo ""
log_phase "Complete"
print_cost_summary
echo ""
log_success "Claude Code configuration generated for: $TARGET_DIR"
