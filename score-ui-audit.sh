#!/usr/local/opt/bash/bin/bash
# score-ui-audit.sh — Full-Surface UI Audit Pipeline for Score.
#
# 3-phase pipeline: SCATTER → DISTILL → SOLVE
# Phase 1 (scatter): 23 screens × 10 models = ~230 independent reviews
# Phase 2 (distill): Synthesize findings, deduplicate, rank by consensus
# Phase 3 (solve): Multi-model solution debates for top issues
#
# Ralph pattern: resumable, per-screen progress, parallel execution
# Stack: llm (model calls) · gum (TUI) · glow (render) · GCP secrets
#
# Usage:
#   ./score-ui-audit.sh --scatter           # Phase 1: fan out all screens to all models
#   ./score-ui-audit.sh --distill           # Phase 2: synthesize findings
#   ./score-ui-audit.sh --solve             # Phase 3: solution debates for top issues
#   ./score-ui-audit.sh --all               # Run all 3 phases sequentially
#   ./score-ui-audit.sh --scatter --screen 01_home_dashboard   # Single screen test
#   ./score-ui-audit.sh --dry-run --scatter # Show plan without calling models
#   ./score-ui-audit.sh --view 01_home_dashboard               # View results for a screen
#   ./score-ui-audit.sh --view-consensus    # View distill report
#   ./score-ui-audit.sh --view-solve 1      # View solution debate #1
#   ./score-ui-audit.sh --quiet --all       # No TUI, plain text output
#
# [2026-03-19] v1.0 initial release

set -euo pipefail

# ─── COLORS ──────────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
RESET='\033[0m'

# ─── PATHS ───────────────────────────────────────────────────────────────────
SCREENSHOTS_DIR="$HOME/Documents/Score/_dev/ux_audit/ScoreScreenshots_Final"
AUDIT_DIR="$HOME/.ai-conductor/audit"
SCATTER_DIR="$AUDIT_DIR/scatter"
SOLVE_DIR="$AUDIT_DIR/solve"
PROGRESS_FILE="$AUDIT_DIR/scatter_progress.txt"
DISTILL_REPORT="$AUDIT_DIR/distill_report.md"
CONVENTIONS_FILE="$HOME/Documents/Score/_dev/ux_audit/gemini_audit_conventions.md"
GCP_PROJECT="pwa-id-app"

# ─── MODEL CONFIG ────────────────────────────────────────────────────────────
# Vision-capable models get raw screenshots via llm -a
# Text-only models get a pre-generated image description
declare -A MODELS
MODELS[gemini-pro]="gemini-2.5-pro"
MODELS[gemini-flash]="gemini-2.5-flash"
MODELS[deepseek]="deepseek-chat"
MODELS[groq-llama]="groq-llama-3.3-70b"
MODELS[groq-kimi]="groq-kimi-k2"
MODELS[perplexity]="sonar-pro"
MODELS[qwen]="openrouter/qwen/qwen3.5-9b"
MODELS[gemma]="openrouter/google/gemma-3-27b-it:free"
MODELS[glm]="openrouter/z-ai/glm-4.5-air:free"
MODELS[stepfun]="openrouter/stepfun/step-3.5-flash:free"

# Models that can accept -a image attachments
VISION_MODELS=("gemini-pro" "gemini-flash")

# All model keys in run order
ALL_MODEL_KEYS=(gemini-pro gemini-flash deepseek groq-llama groq-kimi perplexity qwen gemma glm stepfun)

# Solve debate models (subset — strong reasoning models)
SOLVE_MODELS=(gemini-pro deepseek groq-kimi perplexity)

# ─── RUNTIME CONFIG ──────────────────────────────────────────────────────────
MODEL_TIMEOUT=45          # seconds per model call
VISION_TIMEOUT=60         # seconds for vision model calls
QUIET=false
DRY_RUN=false
SINGLE_SCREEN=""

# ─── HELPERS ─────────────────────────────────────────────────────────────────

log() { echo -e "${DIM}[$(date +%H:%M:%S)]${RESET} $*"; }
log_ok() { echo -e "${GREEN}  ✓${RESET} $*"; }
log_warn() { echo -e "${YELLOW}  !${RESET} $*"; }
log_err() { echo -e "${RED}  ✗${RESET} $*"; }

has_gum() { command -v gum >/dev/null 2>&1 && [[ "$QUIET" == "false" ]]; }
has_glow() { command -v glow >/dev/null 2>&1; }

check_deps() {
  local missing=()
  for cmd in llm jq; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}Missing required tools: ${missing[*]}${RESET}"
    echo "Install with: brew install ${missing[*]}"
    exit 1
  fi
}

# ─── GCP SECRETS ─────────────────────────────────────────────────────────────

fetch_key() {
  gcloud secrets versions access latest --secret="$1" --project="$GCP_PROJECT" 2>/dev/null || true
}

setup_keys() {
  log "Fetching credentials from GCP..."
  local k loaded=()

  k=$(fetch_key "GEMINI_API_KEY");      [[ -n "$k" ]] && export GEMINI_API_KEY="$k"      && loaded+=("gemini")
  k=$(fetch_key "DEEPSEEK_API_KEY");    [[ -n "$k" ]] && export DEEPSEEK_API_KEY="$k"    && loaded+=("deepseek")
  k=$(fetch_key "GROQ_API_KEY");        [[ -n "$k" ]] && export GROQ_API_KEY="$k"        && loaded+=("groq")
  k=$(fetch_key "OPENROUTER_API_KEY");  [[ -n "$k" ]] && export OPENROUTER_API_KEY="$k"  && loaded+=("openrouter")
  k=$(fetch_key "PERPLEXITY_API_KEY");  [[ -n "$k" ]] && export PERPLEXITY_API_KEY="$k"  && loaded+=("perplexity")

  if [[ ${#loaded[@]} -eq 0 ]]; then
    log_warn "No keys loaded from GCP. Using llm's own keystore if available."
  else
    log_ok "Keys loaded: ${loaded[*]}"
  fi
}

# ─── MODEL CALLER ────────────────────────────────────────────────────────────
# Calls a model with optional image attachments.
# Always returns 0 — failures are written to output file.
call_model() {
  local model_id="$1"      # e.g. "gemini-2.5-pro"
  local prompt_file="$2"
  local output_file="$3"
  local call_timeout="$4"
  shift 4
  local -a image_args=("$@")  # remaining args are -a /path/to/image pairs

  local error_file="${output_file}.err"
  local exit_code=0

  if [[ ${#image_args[@]} -gt 0 ]]; then
    timeout "$call_timeout" llm -m "$model_id" "${image_args[@]}" < "$prompt_file" > "$output_file" 2>"$error_file" || exit_code=$?
  else
    timeout "$call_timeout" llm -m "$model_id" < "$prompt_file" > "$output_file" 2>"$error_file" || exit_code=$?
  fi

  # Check for failure or empty output
  if [[ $exit_code -ne 0 ]] || [[ ! -s "$output_file" ]]; then
    local err=""
    [[ -s "$error_file" ]] && err=" ($(head -1 "$error_file" | cut -c1-120))"
    echo "[${model_id} unavailable — skipped${err}]" > "$output_file"
  fi

  rm -f "$error_file"
  return 0
}

# Returns 0 if output is a real response, 1 if garbage/skip
validate_output() {
  local file="$1"
  [[ ! -s "$file" ]] && return 1
  local content
  content=$(cat "$file")
  [[ ${#content} -lt 30 ]] && return 1
  [[ "$content" == "["* ]] && return 1
  echo "$content" | grep -qE '^\s*\{[^}]*"error"' 2>/dev/null && return 1
  return 0
}

# ─── IMAGE DESCRIPTION GENERATOR ─────────────────────────────────────────────
# For text-only models: generate a description of all screenshots using Gemini Flash
generate_image_description() {
  local screen_name="$1"
  local screen_dir="$2"
  local desc_file="$SCATTER_DIR/$screen_name/_image_desc.txt"

  # Cached — skip if already exists
  if [[ -s "$desc_file" ]]; then
    return 0
  fi

  local -a attach_args=()
  for img in "$screen_dir"/current/*.png; do
    [[ -f "$img" ]] && attach_args+=(-a "$img")
  done

  if [[ ${#attach_args[@]} -eq 0 ]]; then
    echo "No screenshots available for $screen_name." > "$desc_file"
    return 0
  fi

  local prompt_file
  prompt_file=$(mktemp)
  cat > "$prompt_file" << 'DESCEOF'
Describe each screenshot in detail for a UI reviewer who cannot see the images.
For each screenshot, describe:
- The screen layout (header, cards, lists, buttons, navigation)
- All visible text/labels/numbers
- Color scheme and visual styling
- State of the screen (empty, populated, scrolled, modal open, etc.)
- Any notable UI elements (status pills, progress rings, icons)

Be thorough and specific. A reviewer should be able to evaluate the UI from your description alone.
DESCEOF

  log "    Generating image descriptions for $screen_name..."
  call_model "${MODELS[gemini-flash]}" "$prompt_file" "$desc_file" "$VISION_TIMEOUT" "${attach_args[@]}"
  rm -f "$prompt_file"

  if ! validate_output "$desc_file"; then
    log_warn "    Image description failed for $screen_name — text-only models will have limited context"
  fi
}

# ─── PROMPT BUILDER ──────────────────────────────────────────────────────────
build_scatter_prompt() {
  local screen_name="$1"
  local is_vision="$2"
  local prompt_file="$3"

  local desc_file="$SCATTER_DIR/$screen_name/_image_desc.txt"

  cat > "$prompt_file" << PROMPTEOF
Review this screen from an iOS reseller profit tracker called Score.
The app tracks sourcing trips, inventory, and profit for people who
buy at thrift stores and resell on eBay/Poshmark/Mercari.

Screen: $screen_name

PROMPTEOF

  # For text-only models, inject the image description
  if [[ "$is_vision" == "false" ]] && [[ -s "$desc_file" ]]; then
    cat >> "$prompt_file" << DESCBLOCK
=== SCREENSHOT DESCRIPTIONS ===
$(cat "$desc_file")
=== END SCREENSHOTS ===

DESCBLOCK
  fi

  # Inject project conventions (first 60 lines — the essential stuff)
  if [[ -f "$CONVENTIONS_FILE" ]]; then
    cat >> "$prompt_file" << CONVBLOCK
=== PROJECT CONVENTIONS (key design rules) ===
$(head -60 "$CONVENTIONS_FILE")
=== END CONVENTIONS ===

CONVBLOCK
  fi

  # The actual review prompt
  cat >> "$prompt_file" << 'EVALEOF'
IMPORTANT: You may see a small "DEV" sticker/badge in the top-right corner of screenshots.
This is a debug-mode indicator only visible during development — ignore it completely.
Do NOT flag it as a UI issue.

Evaluate this screen on these 5 dimensions:

1. FIRST IMPRESSION: What does a new user think this screen does? (3 seconds)
2. FRICTION: Where would a user get stuck or confused?
3. HIERARCHY: Is the most important information the most visually prominent?
4. CONSISTENCY: Anything that looks different from standard iOS patterns?
5. CONVERSION: Does this screen help or hurt the path to Pro upgrade?

Output ONLY as structured lines in this exact format:
SCREEN | SEVERITY | FINDING | SPECIFIC LOCATION

Where SEVERITY is one of: blocker, warning, minor

One finding per line. Maximum 5 findings. Be specific, not generic.
If the screen looks good, output: SCREEN | clean | No issues found | N/A

Example:
home_dashboard | blocker | New user sees -100% ROI with no items — discouraging | KPI card row, ROI metric
home_dashboard | warning | Tooltip icon too small for touch target | Help button, top right
EVALEOF
}

# ─── SCATTER: SINGLE SCREEN × SINGLE MODEL ──────────────────────────────────
scatter_one() {
  local screen_name="$1"
  local model_key="$2"

  local screen_dir="$SCREENSHOTS_DIR/$screen_name"
  local result_dir="$SCATTER_DIR/$screen_name"
  local result_file="$result_dir/${model_key}.txt"

  # Ralph check — skip if already done
  if [[ -s "$result_file" ]] && validate_output "$result_file"; then
    return 0
  fi

  mkdir -p "$result_dir"

  # Determine if this is a vision model
  local is_vision="false"
  for vm in "${VISION_MODELS[@]}"; do
    [[ "$model_key" == "$vm" ]] && is_vision="true" && break
  done

  # Build prompt
  local prompt_file
  prompt_file=$(mktemp)
  build_scatter_prompt "$screen_name" "$is_vision" "$prompt_file"

  # Build image attachment args for vision models
  local -a img_args=()
  if [[ "$is_vision" == "true" ]]; then
    for img in "$screen_dir"/current/*.png; do
      [[ -f "$img" ]] && img_args+=(-a "$img")
    done
  fi

  # Pick timeout
  local tout="$MODEL_TIMEOUT"
  [[ "$is_vision" == "true" ]] && tout="$VISION_TIMEOUT"

  # Call the model
  local model_id="${MODELS[$model_key]}"
  call_model "$model_id" "$prompt_file" "$result_file" "$tout" "${img_args[@]}"
  rm -f "$prompt_file"

  # Report result
  if validate_output "$result_file"; then
    local finding_count
    finding_count=$(grep -c '|' "$result_file" 2>/dev/null || echo "0")
    log_ok "    ${model_key}: ${finding_count} findings"
  else
    log_warn "    ${model_key}: failed or empty"
  fi
}

# ─── SCATTER: SINGLE SCREEN (ALL MODELS) ────────────────────────────────────
scatter_screen() {
  local screen_name="$1"
  local screen_dir="$SCREENSHOTS_DIR/$screen_name"

  # Check for screenshots
  local img_count=0
  img_count=$(find "$screen_dir/current" -name "*.png" 2>/dev/null | wc -l | tr -d '[:space:]' || true)
  [[ -z "$img_count" ]] && img_count=0
  if [[ "$img_count" -eq 0 ]]; then
    log_warn "  Skipping $screen_name — no screenshots"
    return 0
  fi

  log "  Screen: ${BOLD}$screen_name${RESET} ($img_count screenshots)"

  # Ensure output directory exists before any model calls
  mkdir -p "$SCATTER_DIR/$screen_name"

  # Generate image description for text-only models (cached)
  generate_image_description "$screen_name" "$screen_dir"

  # Run all models — background jobs, wait at end
  local pids=()
  for model_key in "${ALL_MODEL_KEYS[@]}"; do
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "    [dry-run] Would call ${MODELS[$model_key]} for $screen_name"
    else
      scatter_one "$screen_name" "$model_key" &
      pids+=($!)
    fi
  done

  # Wait for all models on this screen
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Count results
  local done_count=0
  for model_key in "${ALL_MODEL_KEYS[@]}"; do
    local rf="$SCATTER_DIR/$screen_name/${model_key}.txt"
    [[ -s "$rf" ]] && validate_output "$rf" && done_count=$((done_count + 1))
  done

  log_ok "  $screen_name: $done_count/${#ALL_MODEL_KEYS[@]} models succeeded"

  # Mark screen complete in progress file
  echo "$screen_name" >> "$PROGRESS_FILE"
}

# ─── SCATTER: ALL SCREENS ───────────────────────────────────────────────────
run_scatter() {
  echo ""
  echo -e "${BOLD}${CYAN}── PHASE 1: SCATTER ──────────────────────────────────────────${RESET}"
  echo ""

  mkdir -p "$SCATTER_DIR"
  touch "$PROGRESS_FILE"

  # Get screen list
  local -a screens=()
  if [[ -n "$SINGLE_SCREEN" ]]; then
    screens=("$SINGLE_SCREEN")
  else
    for d in "$SCREENSHOTS_DIR"/*/; do
      local name
      name=$(basename "$d")
      screens+=("$name")
    done
  fi

  local total=${#screens[@]}
  log "Scatter: $total screens × ${#ALL_MODEL_KEYS[@]} models = $((total * ${#ALL_MODEL_KEYS[@]})) reviews"
  echo ""

  if [[ "$DRY_RUN" == "true" ]]; then
    for s in "${screens[@]}"; do
      local img_count=0
      img_count=$(find "$SCREENSHOTS_DIR/$s/current" -name "*.png" 2>/dev/null | wc -l | tr -d '[:space:]' || true)
      [[ -z "$img_count" ]] && img_count=0
      if [[ "$img_count" -eq 0 ]]; then
        echo "  $s (no screenshots — skipping)"
        continue
      fi
      echo "  $s ($img_count screenshots) × ${#ALL_MODEL_KEYS[@]} models"
    done
    echo ""
    echo "Dry run complete. No model calls made."
    return 0
  fi

  # Run screens sequentially — per-model parallelism happens inside scatter_screen.
  # Sequential screen processing avoids nested subshell issues where
  # associative arrays (MODELS, VISION_MODELS) get lost in double-backgrounded jobs.
  local idx=0

  for screen_name in "${screens[@]}"; do
    idx=$((idx + 1))

    # Check if already done (all models have results)
    local all_done=true
    for model_key in "${ALL_MODEL_KEYS[@]}"; do
      local rf="$SCATTER_DIR/$screen_name/${model_key}.txt"
      if [[ ! -s "$rf" ]] || ! validate_output "$rf"; then
        all_done=false
        break
      fi
    done

    if [[ "$all_done" == "true" ]]; then
      log "  [$idx/$total] $screen_name — already complete, skipping"
      continue
    fi

    log "  [$idx/$total] Starting $screen_name..."
    scatter_screen "$screen_name"
  done

  echo ""

  # Summary
  local total_findings=0
  local screens_done=0
  for screen_name in "${screens[@]}"; do
    local screen_findings=0
    for model_key in "${ALL_MODEL_KEYS[@]}"; do
      local rf="$SCATTER_DIR/$screen_name/${model_key}.txt"
      if [[ -s "$rf" ]] && validate_output "$rf"; then
        local fc
        fc=$(grep -c '|' "$rf" 2>/dev/null || echo "0")
        screen_findings=$((screen_findings + fc))
      fi
    done
    [[ $screen_findings -gt 0 ]] && screens_done=$((screens_done + 1))
    total_findings=$((total_findings + screen_findings))
  done

  echo -e "${GREEN}${BOLD}Scatter complete.${RESET}"
  echo "  Screens processed: $screens_done/$total"
  echo "  Total finding lines: $total_findings"
  echo "  Results: $SCATTER_DIR/"
  echo ""
}

# ─── DISTILL ─────────────────────────────────────────────────────────────────
run_distill() {
  echo ""
  echo -e "${BOLD}${CYAN}── PHASE 2: DISTILL ─────────────────────────────────────────${RESET}"
  echo ""

  # Collect all scatter results into one file for synthesis
  local all_findings
  all_findings=$(mktemp)
  local total_lines=0

  for screen_dir in "$SCATTER_DIR"/*/; do
    [[ -d "$screen_dir" ]] || continue
    local screen_name
    screen_name=$(basename "$screen_dir")

    for result_file in "$screen_dir"/*.txt; do
      [[ -f "$result_file" ]] || continue
      local model_key
      model_key=$(basename "$result_file" .txt)
      [[ "$model_key" == "_image_desc" ]] && continue

      if validate_output "$result_file"; then
        # Prefix each line with the model name for tracking
        while IFS= read -r line; do
          # Only include lines that look like structured findings (contain |)
          if [[ "$line" == *"|"* ]]; then
            echo "[$model_key] $line" >> "$all_findings"
            total_lines=$((total_lines + 1))
          fi
        done < "$result_file"
      fi
    done
  done

  if [[ $total_lines -eq 0 ]]; then
    log_err "No findings to distill. Run --scatter first."
    rm -f "$all_findings"
    return 1
  fi

  log "Collected $total_lines finding lines from scatter results"
  log "Sending to Gemini for synthesis..."

  # Build the distill prompt
  local distill_prompt
  distill_prompt=$(mktemp)
  cat > "$distill_prompt" << DISTILLEOF
You are synthesizing a multi-model UI audit of Score., an iOS reseller profit tracker.

$total_lines findings were collected from 10 different AI models reviewing 23 screens.
Each finding is prefixed with [model_name] so you can count consensus.

Your job:
1. GROUP findings by screen
2. DEDUPLICATE similar findings (e.g., "KPI confusing" and "ROI metric unclear for new users" are the same issue)
3. COUNT how many distinct models flagged each unique issue (consensus score)
4. RANK by: blocker severity first, then by consensus count (more models = higher priority)
5. For the top 10 issues (highest consensus × severity), write a SPECIFIC debate question for Phase 3

OUTPUT FORMAT:

# Score. UI Audit — Distill Report
Generated: $(date -u '+%Y-%m-%d %H:%M UTC')
Total scatter findings: $total_lines lines from 10 models across 23 screens

## Section 1: High-Consensus Issues (3+ models agree)
For each issue:
### [rank]. [screen_name] — [one-line issue summary]
- **Consensus:** N/10 models flagged this
- **Severity:** blocker/warning/minor
- **Models:** [list which models flagged it]
- **Details:** [merged description from all models that flagged it]

## Section 2: Per-Screen Breakdown
For each screen that has findings:
### [screen_name]
- [finding 1] (severity, N models)
- [finding 2] (severity, N models)
...

## Section 3: Solve Queue
For each of the top 10 issues, write a debate question:
### Solve [N]: [screen_name] — [issue]
**Question:** [Specific question with 2-3 option sketches, not generic]
**Context:** [What the user sees, why it matters]

=== RAW FINDINGS ===
$(cat "$all_findings")
=== END RAW FINDINGS ===
DISTILLEOF

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] Would send $(wc -l < "$distill_prompt") line prompt to gemini-2.5-pro"
    rm -f "$all_findings" "$distill_prompt"
    return 0
  fi

  call_model "${MODELS[gemini-pro]}" "$distill_prompt" "$DISTILL_REPORT" 120
  rm -f "$all_findings" "$distill_prompt"

  if validate_output "$DISTILL_REPORT"; then
    local issue_count
    issue_count=$(grep -c '^### Solve' "$DISTILL_REPORT" 2>/dev/null || echo "0")
    echo ""
    echo -e "${GREEN}${BOLD}Distill complete.${RESET}"
    echo "  Report: $DISTILL_REPORT"
    echo "  Solve queue: $issue_count issues ready for Phase 3"
    echo ""

    # Show preview
    if has_glow; then
      head -40 "$DISTILL_REPORT" | glow - 2>/dev/null || head -40 "$DISTILL_REPORT"
    else
      head -40 "$DISTILL_REPORT"
    fi
  else
    log_err "Distill synthesis failed. Check $DISTILL_REPORT for errors."
  fi
}

# ─── SOLVE ───────────────────────────────────────────────────────────────────
run_solve() {
  echo ""
  echo -e "${BOLD}${CYAN}── PHASE 3: SOLVE ───────────────────────────────────────────${RESET}"
  echo ""

  if [[ ! -s "$DISTILL_REPORT" ]]; then
    log_err "No distill report found. Run --distill first."
    return 1
  fi

  mkdir -p "$SOLVE_DIR"

  # Extract solve queue items from the distill report
  # Look for "### Solve N:" headings and extract the block
  local -a solve_items=()
  local -a solve_screens=()
  local -a solve_questions=()

  local in_solve=false
  local current_item=""
  local current_screen=""
  local current_num=""
  local item_text=""

  while IFS= read -r line; do
    if [[ "$line" =~ ^###\ Solve\ ([0-9]+):\ ([a-z0-9_]+)\ —\ (.+)$ ]]; then
      # Save previous item if exists
      if [[ -n "$current_num" ]]; then
        solve_items+=("$current_num")
        solve_screens+=("$current_screen")
        solve_questions+=("$item_text")
      fi
      current_num="${BASH_REMATCH[1]}"
      current_screen="${BASH_REMATCH[2]}"
      item_text="$line"$'\n'
      in_solve=true
    elif [[ "$in_solve" == "true" ]]; then
      if [[ "$line" =~ ^###\  ]] && [[ ! "$line" =~ ^###\ Solve ]]; then
        # Hit a non-solve heading — end of solve section
        if [[ -n "$current_num" ]]; then
          solve_items+=("$current_num")
          solve_screens+=("$current_screen")
          solve_questions+=("$item_text")
        fi
        in_solve=false
        current_num=""
      else
        item_text+="$line"$'\n'
      fi
    fi
  done < "$DISTILL_REPORT"

  # Capture last item
  if [[ -n "$current_num" ]]; then
    solve_items+=("$current_num")
    solve_screens+=("$current_screen")
    solve_questions+=("$item_text")
  fi

  local solve_count=${#solve_items[@]}
  if [[ $solve_count -eq 0 ]]; then
    log_warn "No solve items found in distill report. Check report format."
    return 1
  fi

  log "Solve queue: $solve_count issues to debate"
  echo ""

  for i in "${!solve_items[@]}"; do
    local num="${solve_items[$i]}"
    local screen="${solve_screens[$i]}"
    local question="${solve_questions[$i]}"
    local solve_file="$SOLVE_DIR/solve_${num}_${screen}.md"

    # Ralph check — skip if already done
    if [[ -s "$solve_file" ]] && validate_output "$solve_file"; then
      log "  Solve #$num ($screen) — already complete, skipping"
      continue
    fi

    log "  Solve #$num: $screen"

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "    [dry-run] Would debate with ${#SOLVE_MODELS[@]} models"
      continue
    fi

    # Get image description for context
    local img_desc=""
    local desc_file="$SCATTER_DIR/$screen/_image_desc.txt"
    [[ -s "$desc_file" ]] && img_desc=$(cat "$desc_file")

    # Round 1: Each model proposes solutions independently
    local -a round1_files=()
    local -a round1_pids=()

    for model_key in "${SOLVE_MODELS[@]}"; do
      local r1_file="$SOLVE_DIR/.r1_${num}_${model_key}.txt"
      round1_files+=("$r1_file")

      local r1_prompt
      r1_prompt=$(mktemp)
      cat > "$r1_prompt" << SOLVEEOF
A multi-model UI audit of Score. (iOS reseller profit tracker) found this issue:

$question

Screenshot context for $screen:
$img_desc

Propose 2-3 SPECIFIC solutions. For each:
- OPTION [letter]: [one-line description]
- IMPLEMENTATION: What changes in the UI (be specific about layout, copy, flow)
- TRADEOFF: What you give up with this approach
- EFFORT: trivial / small / medium / large

Pick your recommended option and explain why in 2-3 sentences.
SOLVEEOF

      call_model "${MODELS[$model_key]}" "$r1_prompt" "$r1_file" "$MODEL_TIMEOUT" &
      round1_pids+=($!)
      rm -f "$r1_prompt"
    done

    # Wait for round 1
    for pid in "${round1_pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done

    # Round 2: Synthesis — one model sees all proposals and picks the best
    local all_proposals=""
    for j in "${!SOLVE_MODELS[@]}"; do
      local mk="${SOLVE_MODELS[$j]}"
      local rf="${round1_files[$j]}"
      if [[ -s "$rf" ]] && validate_output "$rf"; then
        all_proposals+="=== ${mk} proposal ===$( echo; cat "$rf"; echo )=== end ${mk} ==="$'\n\n'
      fi
    done

    local synth_prompt
    synth_prompt=$(mktemp)
    cat > "$synth_prompt" << SYNTHEOF
You are synthesizing solution proposals for a UI issue in Score. (iOS app).

ISSUE:
$question

Multiple models proposed solutions:

$all_proposals

Your job:
1. Compare all proposals — note areas of agreement and disagreement
2. Pick the BEST overall approach (may combine elements from multiple proposals)
3. Write a clear RECOMMENDATION with:
   - What to change (specific UI elements, copy, layout)
   - Why this approach wins (tradeoffs considered)
   - Implementation notes (effort level, any gotchas)
   - What NOT to do (rejected approaches and why)

Format as a clean, readable markdown section. Lead with the recommendation.
SYNTHEOF

    local synth_file="$SOLVE_DIR/.synth_${num}.txt"
    call_model "${MODELS[gemini-pro]}" "$synth_prompt" "$synth_file" 90
    rm -f "$synth_prompt"

    # Assemble final solve file
    {
      echo "# Solve #$num: $screen"
      echo ""
      echo "Generated: $(date -u '+%Y-%m-%d %H:%M UTC')"
      echo ""
      echo "## Issue"
      echo "$question"
      echo ""
      echo "---"
      echo ""
      echo "## Individual Proposals"
      echo ""
      for j in "${!SOLVE_MODELS[@]}"; do
        local mk="${SOLVE_MODELS[$j]}"
        local rf="${round1_files[$j]}"
        echo "### ${mk}"
        if [[ -s "$rf" ]] && validate_output "$rf"; then
          cat "$rf"
        else
          echo "[Model unavailable]"
        fi
        echo ""
        echo "---"
        echo ""
      done
      echo "## Synthesis & Recommendation"
      echo ""
      if [[ -s "$synth_file" ]] && validate_output "$synth_file"; then
        cat "$synth_file"
      else
        echo "[Synthesis failed — review individual proposals above]"
      fi
    } > "$solve_file"

    # Clean up temp files
    for rf in "${round1_files[@]}"; do rm -f "$rf"; done
    rm -f "$synth_file"

    log_ok "  Solve #$num complete → $solve_file"
  done

  echo ""
  echo -e "${GREEN}${BOLD}Solve complete.${RESET}"
  echo "  Results: $SOLVE_DIR/"
  echo ""
}

# ─── VIEW COMMANDS ───────────────────────────────────────────────────────────
view_screen() {
  local screen_name="$1"
  local screen_dir="$SCATTER_DIR/$screen_name"

  if [[ ! -d "$screen_dir" ]]; then
    echo "No results for screen: $screen_name"
    echo "Available: $(ls "$SCATTER_DIR" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi

  echo -e "${BOLD}Results for: $screen_name${RESET}"
  echo ""

  for result_file in "$screen_dir"/*.txt; do
    [[ -f "$result_file" ]] || continue
    local model_key
    model_key=$(basename "$result_file" .txt)
    [[ "$model_key" == "_image_desc" ]] && continue

    if validate_output "$result_file"; then
      echo -e "${GREEN}── $model_key ──${RESET}"
      cat "$result_file"
      echo ""
    else
      echo -e "${DIM}── $model_key ── (failed/empty)${RESET}"
    fi
  done
}

view_consensus() {
  if [[ ! -s "$DISTILL_REPORT" ]]; then
    echo "No distill report found. Run --distill first."
    return 1
  fi

  if has_glow; then
    glow "$DISTILL_REPORT"
  else
    cat "$DISTILL_REPORT"
  fi
}

view_solve_item() {
  local num="$1"
  local found=false

  for f in "$SOLVE_DIR"/solve_${num}_*.md; do
    if [[ -f "$f" ]]; then
      if has_glow; then
        glow "$f"
      else
        cat "$f"
      fi
      found=true
      break
    fi
  done

  if [[ "$found" == "false" ]]; then
    echo "No solve result for issue #$num"
    echo "Available: $(ls "$SOLVE_DIR"/*.md 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ')"
    return 1
  fi
}

# ─── MAIN ────────────────────────────────────────────────────────────────────

main() {
  local do_scatter=false
  local do_distill=false
  local do_solve=false
  local view_target=""
  local view_consensus_flag=false
  local view_solve_num=""

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scatter)    do_scatter=true; shift ;;
      --distill)    do_distill=true; shift ;;
      --solve)      do_solve=true; shift ;;
      --all)        do_scatter=true; do_distill=true; do_solve=true; shift ;;
      --screen)     SINGLE_SCREEN="$2"; shift 2 ;;
      --dry-run)    DRY_RUN=true; shift ;;
      --quiet)      QUIET=true; shift ;;
      --view)       view_target="$2"; shift 2 ;;
      --view-consensus) view_consensus_flag=true; shift ;;
      --view-solve) view_solve_num="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: $0 [--scatter] [--distill] [--solve] [--all]"
        echo "       $0 --screen SCREEN_NAME --scatter"
        echo "       $0 --view SCREEN_NAME"
        echo "       $0 --view-consensus"
        echo "       $0 --view-solve N"
        echo "       $0 --dry-run --scatter"
        echo "       $0 --quiet --all"
        exit 0
        ;;
      *) echo "Unknown option: $1"; exit 1 ;;
    esac
  done

  # Handle view commands (no setup needed)
  if [[ -n "$view_target" ]]; then
    view_screen "$view_target"
    return 0
  fi
  if [[ "$view_consensus_flag" == "true" ]]; then
    view_consensus
    return 0
  fi
  if [[ -n "$view_solve_num" ]]; then
    view_solve_item "$view_solve_num"
    return 0
  fi

  # Must specify at least one phase
  if [[ "$do_scatter" == "false" && "$do_distill" == "false" && "$do_solve" == "false" ]]; then
    echo "Specify a phase: --scatter, --distill, --solve, or --all"
    echo "Run $0 --help for full usage."
    exit 1
  fi

  # Preflight
  check_deps

  echo ""
  echo -e "${BOLD}${CYAN}Score. Full-Surface UI Audit Pipeline${RESET}"
  echo -e "${DIM}$(date -u '+%Y-%m-%d %H:%M UTC')${RESET}"
  echo ""

  # Verify screenshots directory exists
  if [[ ! -d "$SCREENSHOTS_DIR" ]]; then
    echo -e "${RED}Screenshots directory not found: $SCREENSHOTS_DIR${RESET}"
    exit 1
  fi

  # Create audit directory
  mkdir -p "$AUDIT_DIR" "$SCATTER_DIR" "$SOLVE_DIR"

  # Load API keys
  if [[ "$DRY_RUN" == "false" ]]; then
    setup_keys
  fi

  echo ""

  # Run phases
  [[ "$do_scatter" == "true" ]]  && run_scatter
  [[ "$do_distill" == "true" ]]  && run_distill
  [[ "$do_solve" == "true" ]]    && run_solve

  echo -e "${BOLD}Done.${RESET} All results in: $AUDIT_DIR/"
}

main "$@"
