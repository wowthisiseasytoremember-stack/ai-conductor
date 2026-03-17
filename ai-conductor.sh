#!/usr/local/opt/bash/bin/bash
# ai-conductor.sh — Multi-Agent Debate Conductor v1.0
#
# Interactive wizard that asks what you need, then runs a structured
# multi-model debate with best-practice prompt design built in.
#
# Modes: brainstorm | decide | review | custom
# Stack: gum (wizard) · llm (model calls) · glow (render) · GCP secrets
#
# Usage: ./ai-conductor.sh
#
# [2026-03-17] v1.0 initial release

set -euo pipefail

# ─── COLORS ──────────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

# ─── CONFIG ──────────────────────────────────────────────────────────────────
GCP_PROJECT="pwa-id-app"
PYTHON_BIN=$(python3 -m site --user-scripts 2>/dev/null || true)
[[ -n "$PYTHON_BIN" ]] && export PATH="$PATH:$PYTHON_BIN"

# llm model aliases — update these as models improve
# "claude" uses the `claude` CLI directly (Claude Code's own auth — no separate API key needed)
# All others go through llm with keys from the GCP keystore
declare -A LLM_MODEL
LLM_MODEL[claude]="claude-cli"          # uses `claude --print` — no Anthropic API key cost
LLM_MODEL[openai]="gpt-4o"             # optional — fails gracefully if quota exceeded
LLM_MODEL[gemini]="gemini-2.5-pro"
LLM_MODEL[deepseek]="deepseek-chat"
LLM_MODEL[groq]="groq-llama-3.3-70b"
LLM_MODEL[perplexity]="openrouter/perplexity/sonar-pro"
LLM_MODEL[openrouter]="openrouter/auto"
LLM_MODEL[mistral]="openrouter/mistralai/devstral-2512"
LLM_MODEL[kimi]="groq-kimi-k2"
LLM_MODEL[flash]="gemini-2.5-flash"     # fast model for State of the Board
LLM_MODEL[judge]="claude-cli"           # synthesis/judge — uses Claude Code directly

# Persona roles assigned by agent index position
PERSONAS=("BUILDER" "RED_TEAMER" "CHALLENGER" "CHALLENGER")
LETTERS=("A" "B" "C" "D" "E")

# Interjection settings — populated by wizard
ENABLE_INTERJECT="false"
INTERJECT_TIMEOUT=30

# ─── MODEL CALLER ────────────────────────────────────────────────────────────
# Routes claude-cli to `claude --print` (Claude Code native auth, no API key cost).
# Everything else goes through `llm` with keys from the keystore.
# Never exits non-zero — all failures are caught and written to output_file.
call_model() {
  local model="$1"
  local prompt_file="$2"
  local output_file="$3"
  local error_file="${4:-/dev/null}"
  local exit_code=0

  if [[ "$model" == "claude-cli" ]]; then
    claude --print -p "$(cat "$prompt_file")" > "$output_file" 2>"$error_file" || exit_code=$?
  else
    llm -m "$model" < "$prompt_file" > "$output_file" 2>"$error_file" || exit_code=$?
  fi

  # If the call failed or produced no output, write a clear skip message
  if [[ $exit_code -ne 0 ]] || [[ ! -s "$output_file" ]]; then
    local err=""
    [[ -s "$error_file" ]] && err=" ($(head -1 "$error_file" | cut -c1-80))"
    echo "[${model} unavailable — skipped${err}]" > "$output_file"
  fi
  return 0  # always succeed so set -e never fires on a model failure
}

# ─── PREFLIGHT ───────────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in gum llm glow jq gcloud; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}Missing tools: ${missing[*]}${RESET}"
    echo "Install with: brew install ${missing[*]}"
    exit 1
  fi
}

# ─── GCP SECRETS ─────────────────────────────────────────────────────────────
fetch_key() {
  gcloud secrets versions access latest --secret="$1" --project="$GCP_PROJECT" 2>/dev/null || true
}

setup_keys() {
  echo -e "${DIM}  Fetching credentials from GCP...${RESET}"
  local k
  local loaded=()

  k=$(fetch_key "OPENAI_API_KEY");    [[ -n "$k" ]] && export OPENAI_API_KEY="$k"    && loaded+=("openai")
  k=$(fetch_key "ANTHROPIC_API_KEY"); [[ -n "$k" ]] && export ANTHROPIC_API_KEY="$k" && loaded+=("claude")
  k=$(fetch_key "GEMINI_API_KEY");    [[ -n "$k" ]] && export GEMINI_API_KEY="$k"    && loaded+=("gemini")
  k=$(fetch_key "DEEPSEEK_API_KEY");  [[ -n "$k" ]] && export DEEPSEEK_API_KEY="$k"  && loaded+=("deepseek")

  if [[ ${#loaded[@]} -eq 0 ]]; then
    echo -e "${YELLOW}  No keys loaded from GCP.${RESET}"
    echo -e "${DIM}  If you have keys in llm's own store (llm keys set ...) those will be used.${RESET}"
    echo -e "${DIM}  To fix GCP auth: gcloud auth login && gcloud config set project ${GCP_PROJECT}${RESET}"
    echo ""
  else
    echo -e "${GREEN}  Keys loaded: ${loaded[*]}${RESET}"
  fi
}

# ─── PERSONAS ────────────────────────────────────────────────────────────────
# Each agent gets a fixed adversarial role for the entire debate.
# This prevents the "everyone agrees politely" collapse that happens
# when models have no structural incentive to disagree.
persona_prompt() {
  case "$1" in
    BUILDER)
      echo "You are THE BUILDER in a structured multi-agent debate.
YOUR ONLY JOB: Take the current best proposal and make it more robust, efficient, or complete.
You MUST begin your response with 'I can improve this by' or 'I can make this more robust by'.
Never simply agree. Always propose a concrete addition or refinement. Max 150 words."
      ;;
    RED_TEAMER)
      echo "You are THE RED TEAMER in a structured multi-agent debate.
YOUR ONLY JOB: Find the breaking point. Identify logical flaws, edge cases, risks, or gaps.
You MUST begin your response with 'I disagree because' or 'This breaks when'.
Do NOT propose solutions — only identify specific problems. Be relentless. Max 150 words."
      ;;
    CHALLENGER)
      echo "You are THE CHALLENGER in a structured multi-agent debate.
YOUR ONLY JOB: Propose a fundamentally different approach when the group is converging.
You MUST begin your response with 'An alternative approach would be' or 'We are ignoring'.
Diversity of thought is your mandate. Max 150 words."
      ;;
  esac
}

# ─── VISION PROXY ────────────────────────────────────────────────────────────
# Converts a screenshot to a detailed text description.
# Models that support vision get the raw image.
# Models that don't get this text description injected as context.
prepare_image_context() {
  local img="$1"
  local out="$2"
  echo -e "${DIM}  Analyzing screenshot with GPT-4o...${RESET}"
  llm -m "${LLM_MODEL[openai]}" -a "$img" \
    "Describe this screenshot exhaustively for AI models that cannot see it. Cover: all visible text, UI elements, layout structure, colors, visual hierarchy, and any data or state shown. Format as structured markdown." \
    > "$out" 2>/dev/null || echo "Screenshot analysis failed." > "$out"
}

# ─── STATE OF THE BOARD ──────────────────────────────────────────────────────
# After each round, a fast model compresses the full transcript into
# three bullets. Agents in the next round get this summary + their last
# turn only — not the full raw transcript. Prevents context bloat.
summarize_board() {
  local prompt_file="$1"
  local out_file="$2"
  gum spin --title "  Summarizing round..." -- \
    bash -c "$(declare -f call_model); call_model '${LLM_MODEL[flash]}' '$prompt_file' '$out_file'"
}

# ─── TMUX SPLIT ──────────────────────────────────────────────────────────────
# If running inside tmux: auto-splits the window and tails the transcript.
# If not in tmux: prints a one-liner to paste in another terminal.
setup_tmux_split() {
  local transcript="$1"
  if [[ -n "${TMUX:-}" ]]; then
    tmux split-window -h "tail -f '$transcript'"
    tmux select-pane -L
    echo -e "${GREEN}  Split pane opened — transcript streaming on the right.${RESET}"
    echo ""
  else
    echo ""
    gum style --foreground 241 --border normal --padding "0 2" \
      "  Watch live in another terminal:" \
      "  tail -f ${transcript}"
    echo ""
  fi
}

# ─── INTERACTIVE CONTEXT GATHERER ───────────────────────────────────────────
# Accepts: keyword search (Spotlight), drag & drop files/folders, 'paste' for
# freeform text. Images are described by GPT-4o so all models get full context.
# Sets globals: CONTEXT_TEXT, SCREENSHOT_PATH

# Shared helper — adds a single file path to CONTEXT_TEXT.
# Called from both the search path and the drag-and-drop path.
_add_file_to_context() {
  local file="$1"
  local ext="${file##*.}"
  case "${ext,,}" in
    png|jpg|jpeg|gif|webp|heic|bmp|tiff)
      local img_desc_file="/tmp/conductor_img_$$"
      local img_prompt_file="/tmp/conductor_img_prompt_$$"
      echo "Describe this image exhaustively for AI models that cannot see it. Cover: all visible text, UI elements, layout structure, colors, visual hierarchy, and any data or state shown. Format as structured markdown." > "$img_prompt_file"
      # Try GPT-4o first (best vision), fall back to Gemini if OpenAI quota exceeded
      gum spin --title "  Analyzing image: $(basename "$file")..." -- \
        bash -c "llm -m '${LLM_MODEL[openai]}' -a '$file' < '$img_prompt_file' > '$img_desc_file' 2>/dev/null \
          || llm -m '${LLM_MODEL[gemini]}' -a '$file' < '$img_prompt_file' > '$img_desc_file' 2>/dev/null \
          || echo 'Image could not be analyzed — describe it manually in the context.' > '$img_desc_file'; true"
      local img_desc
      img_desc=$(cat "$img_desc_file" 2>/dev/null || echo "Image analysis failed.")
      rm -f "$img_desc_file" "$img_prompt_file"
      CONTEXT_TEXT="${CONTEXT_TEXT}
--- Image: $(basename "$file") ---
${img_desc}
"
      SCREENSHOT_PATH="$file"
      echo -e "${GREEN}  Image analyzed and added: $(basename "$file")${RESET}"
      ;;
    *)
      local content
      content=$(cat "$file" 2>/dev/null | head -300) || {
        echo -e "${YELLOW}  Cannot read: $(basename "$file")${RESET}"
        return 1
      }
      CONTEXT_TEXT="${CONTEXT_TEXT}
--- $(basename "$file") ---
${content}
"
      echo -e "${GREEN}  File added: $(basename "$file")${RESET}"
      ;;
  esac
  return 0
}

gather_context_interactive() {
  CONTEXT_TEXT=""
  SCREENSHOT_PATH=""
  local items_added=0

  gum style --bold --foreground 212 "  Context Gatherer"
  echo -e "${DIM}  Search by keyword, drag & drop a file or folder, type 'paste' for text, or 'done' to finish.${RESET}"
  echo -e "${DIM}  Examples: 'home screen', 'architecture doc'  —  or just drag a file here${RESET}"
  echo ""

  while true; do
    [[ $items_added -gt 0 ]] && echo -e "${GREEN}  ${items_added} item(s) added.${RESET} Add more, or type 'done':"

    local query
    query=$(gum input \
      --placeholder "search term, drag a file/folder, 'paste', or 'done'" \
      --width 80) || break

    [[ -z "$query" || "$query" == "done" ]] && break

    # ── Paste mode ────────────────────────────────────────────────────────────
    if [[ "$query" == "paste" ]]; then
      local pasted
      pasted=$(gum write \
        --header "Paste your text (Ctrl+D when done):" \
        --placeholder "Paste anything here..." \
        --width 80 --height 12) || continue
      if [[ -n "$pasted" ]]; then
        CONTEXT_TEXT="${CONTEXT_TEXT}
--- Pasted Text ---
${pasted}
"
        items_added=$((items_added + 1))
        echo -e "${GREEN}  Text added.${RESET}"
      fi
      echo ""
      continue
    fi

    # ── Drag & drop detection ─────────────────────────────────────────────────
    # macOS Terminal pastes the path when you drag a file/folder in.
    # Paths may have: trailing space, backslash-escaped spaces, surrounding quotes.
    local dropped="$query"
    dropped="${dropped%% }"           # strip trailing space macOS adds
    dropped="${dropped//\\ / }"       # unescape backslash-spaces in paths
    dropped="${dropped#\'}"           # strip leading single-quote
    dropped="${dropped%\'}"           # strip trailing single-quote
    dropped="${dropped/#\~/$HOME}"    # expand tilde

    if [[ "$dropped" == /* && -e "$dropped" ]]; then
      if [[ -d "$dropped" ]]; then
        # ── Folder dropped — show contents, allow multi-select ───────────────
        echo -e "${DIM}  Folder: $(basename "$dropped") — listing contents...${RESET}"
        local folder_files
        folder_files=$(find "$dropped" -maxdepth 1 -type f ! -name ".*" | sort 2>/dev/null || true)

        if [[ -z "$folder_files" ]]; then
          echo -e "${YELLOW}  No readable files in that folder.${RESET}"
          echo ""
          continue
        fi

        local file_count
        file_count=$(echo "$folder_files" | wc -l | tr -d ' ')
        echo -e "${DIM}  ${file_count} file(s) found. Space to select multiple, Enter to confirm.${RESET}"

        local chosen
        chosen=$(echo "$folder_files" | gum choose \
          --header "Select files from $(basename "$dropped"):" \
          --no-limit \
          --height 15) || true

        [[ -z "$chosen" ]] && { echo ""; continue; }

        while IFS= read -r f; do
          [[ -z "$f" ]] && continue
          _add_file_to_context "$f" && items_added=$((items_added + 1)) || true
        done <<< "$chosen"

      else
        # ── Single file dropped — add directly, no search needed ─────────────
        echo -e "${DIM}  File dropped: $(basename "$dropped")${RESET}"
        _add_file_to_context "$dropped" && items_added=$((items_added + 1)) || true
      fi
      echo ""
      continue
    fi

    # ── Keyword search via Spotlight ──────────────────────────────────────────
    local results_file="/tmp/conductor_search_$$"
    gum spin --title "  Searching for '$query'..." -- \
      bash -c "timeout 15 mdfind -onlyin '$HOME' '$query' 2>/dev/null \
        | grep -v '\.DS_Store\|/\.git/\|/node_modules/\|/\.Trash/' \
        | head -40 > '$results_file' 2>/dev/null; true"

    local results
    results=$(cat "$results_file" 2>/dev/null || true)
    rm -f "$results_file"

    if [[ -z "$results" ]]; then
      echo -e "${YELLOW}  Nothing found for: '$query' — try different keywords.${RESET}"
      echo ""
      continue
    fi

    local result_count
    result_count=$(echo "$results" | wc -l | tr -d ' ')
    echo -e "${DIM}  Found ${result_count} file(s). Arrow keys to select, Enter to confirm, Esc to cancel.${RESET}"

    local selected
    selected=$(echo "$results" | gum choose \
      --header "Select a file to add:" \
      --height 15) || true

    [[ -z "$selected" ]] && { echo ""; continue; }

    _add_file_to_context "$selected" && items_added=$((items_added + 1)) || true
    echo ""
  done

  if [[ $items_added -gt 0 ]]; then
    echo -e "${GREEN}  Context ready: ${items_added} item(s) loaded.${RESET}"
  else
    echo -e "${DIM}  No context added.${RESET}"
  fi
  echo ""
}

# ─── WIZARD ──────────────────────────────────────────────────────────────────
# Globals set by wizard: MODE, TOPIC, CONTEXT_TEXT, SCREENSHOT_PATH, ROUNDS, AGENTS_STR, ENABLE_INTERJECT, INTERJECT_TIMEOUT
run_wizard() {
  clear
  gum style \
    --border double \
    --border-foreground 212 \
    --padding "1 4" \
    --margin "1 2" \
    --bold "AI DEBATE CONDUCTOR"

  # Step 1: Mode
  MODE=$(gum choose \
    --header "What do you need?" \
    --header.foreground 212 \
    "brainstorm  — generate and build on ideas" \
    "decide      — argue positions, reach a verdict" \
    "review      — critique a design, plan, or screen" \
    "custom      — configure everything manually")
  MODE=$(echo "$MODE" | awk '{print $1}')

  # Step 2: Topic
  TOPIC=$(gum input \
    --header "Topic or question:" \
    --placeholder "e.g. Should we use a tab bar or sidebar for navigation?" \
    --width 80)
  [[ -z "$TOPIC" ]] && { echo "No topic provided. Exiting."; exit 1; }

  # Step 3: Context (interactive gatherer)
  if gum confirm --default=false "Add context? (files, screenshots, docs, pasted text)"; then
    gather_context_interactive
  else
    CONTEXT_TEXT=""
    SCREENSHOT_PATH=""
  fi

  # Step 4: Rounds (smart defaults per mode)
  local dr
  case "$MODE" in
    brainstorm) dr=3 ;;
    decide)     dr=4 ;;
    review)     dr=2 ;;
    *)          dr=3 ;;
  esac
  ROUNDS=$(gum input \
    --header "How many rounds? (default: $dr)" \
    --value "$dr" \
    --width 10)
  ROUNDS="${ROUNDS:-$dr}"

  # Step 5: Models (smart defaults per mode)
  local da
  case "$MODE" in
    brainstorm) da="claude,gemini,deepseek" ;;
    decide)     da="claude,gemini,deepseek" ;;
    review)     da="claude,gemini,groq" ;;
    *)          da="claude,gemini" ;;
  esac
  AGENTS_STR=$(gum input \
    --header "Models (comma-separated):" \
    --value "$da" \
    --placeholder "claude,openai,gemini,deepseek" \
    --width 50)
  AGENTS_STR="${AGENTS_STR:-$da}"

  # Step 6: Interjection
  if gum confirm --default=false "Pause between rounds for your input?"; then
    ENABLE_INTERJECT="true"
    INTERJECT_TIMEOUT=$(gum input \
      --header "Auto-continue after how many seconds? (0 = wait forever, default: 30)" \
      --value "30" \
      --width 10)
    INTERJECT_TIMEOUT="${INTERJECT_TIMEOUT:-30}"
  else
    ENABLE_INTERJECT="false"
  fi

  echo ""
  gum confirm "Start debate?  Mode: $MODE  |  Rounds: $ROUNDS  |  Models: $AGENTS_STR" || exit 0
}

# ─── DEBATE ENGINE ───────────────────────────────────────────────────────────
run_debate() {
  IFS=',' read -ra AGENTS <<< "$AGENTS_STR"

  local dir="/tmp/ai-conductor-$(date +%s)"
  mkdir -p "$dir"

  local transcript="$dir/transcript.md"
  local board_file="$dir/board.md"
  local image_ctx="$dir/image_context.md"
  local final_out="$dir/final_output.md"

  # Init transcript
  {
    echo "# AI Debate — $MODE Mode"
    echo "**Topic:** $TOPIC"
    echo "**Date:** $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "---"
  } > "$transcript"

  # Split terminal or show paste command — happens before first round
  setup_tmux_split "$transcript"

  # Build anonymous label map — agents never see each other's real names.
  # Prevents identity sycophancy (models deferring to "GPT-4o Expert" etc).
  declare -A ANON
  for i in "${!AGENTS[@]}"; do
    ANON[${AGENTS[$i]}]="Perspective ${LETTERS[$i]}"
  done

  # Build base context block — CONTEXT_TEXT already includes any image descriptions
  # from the interactive gatherer (images were analyzed inline during wizard step 3)
  local ctx=""
  if [[ -n "$CONTEXT_TEXT" ]]; then
    ctx="CONTEXT PROVIDED:
${CONTEXT_TEXT}

"
  fi

  echo "" > "$board_file"
  local last_turn=""

  # ── ROUND LOOP ──────────────────────────────────────────────────────────────
  for round in $(seq 1 "$ROUNDS"); do
    echo ""
    gum style --bold --foreground 212 "── ROUND $round of $ROUNDS ──────────────────────────────────────────"
    echo ""

    local round_content=""

    for i in "${!AGENTS[@]}"; do
      local agent="${AGENTS[$i]}"
      local persona="${PERSONAS[$i]:-CHALLENGER}"
      local label="${ANON[$agent]}"
      local model="${LLM_MODEL[$agent]:-gpt-4o}"
      local pf="$dir/prompt_${agent}_r${round}.txt"
      local rf="$dir/response_${agent}_r${round}.txt"

      # Build prompt — Round 1 is blind (no history, no other perspectives).
      # This forces each agent to form an independent position before
      # being influenced by what others said.
      local sys
      sys=$(persona_prompt "$persona")

      if [[ $round -eq 1 ]]; then
        cat > "$pf" << PROMPT
${sys}

[ORIGINAL USER GOAL]: ${TOPIC}

${ctx}INSTRUCTION: State your initial independent position on this topic. This is Round 1 — you have not seen other perspectives yet. Be specific and direct.
PROMPT
      else
        cat > "$pf" << PROMPT
${sys}

[ORIGINAL USER GOAL]: ${TOPIC}

${ctx}STATE OF THE BOARD (summary of all previous rounds):
$(cat "$board_file")

MOST RECENT TURN:
${last_turn}

INSTRUCTION: Respond to the current state of the debate. Stay in your assigned role.
PROMPT
      fi

      # Call model with spinner — call_model always returns 0, so this never crashes
      local ef="$dir/error_${agent}_r${round}.log"
      gum spin --title "  ${label} (${agent}) thinking..." -- \
        bash -c "$(declare -f call_model); call_model '$model' '$pf' '$rf' '$ef'"

      local response
      response=$(cat "$rf")

      # Track last turn for next agent's context
      last_turn="[${label} — ${persona}]:
${response}"

      # Accumulate round content for State of the Board summarization
      round_content="${round_content}
[${label} — ${persona}]:
${response}
---"

      # Append to full transcript
      printf "\n### %s (Round %d)\n\n%s\n\n---\n" "$label" "$round" "$response" >> "$transcript"

      # Display
      gum style --foreground 212 "  ${label}  (${persona}):"
      echo ""
      echo "$response" | glow - 2>/dev/null || echo "$response"
      echo ""
    done

    # State of the Board — compress this round for the next round's context.
    # Skipped after the final round (nothing to prepare for).
    if [[ $round -lt $ROUNDS ]]; then
      cat > "$dir/board_prompt_r${round}.txt" << PROMPT
Summarize this debate round into exactly three sections. Be specific, not vague. Under 80 words total.

**Established Facts:** what all sides agree on
**Active Disagreements:** specific unresolved conflicts
**Open Questions:** what hasn't been addressed yet

DEBATE:
${round_content}
PROMPT
      summarize_board "$dir/board_prompt_r${round}.txt" "$board_file"
      echo ""
      gum style --foreground 241 "$(cat "$board_file")"
      echo ""
    fi

    # User interjection — only if enabled in wizard, only between rounds
    if [[ "$ENABLE_INTERJECT" == "true" ]] && [[ -t 0 ]] && [[ $round -lt $ROUNDS ]]; then
      local timeout_hint=""
      if [[ "$INTERJECT_TIMEOUT" -gt 0 ]]; then
        timeout_hint=" (auto-continuing in ${INTERJECT_TIMEOUT}s)"
      fi
      echo -e "${DIM}  [Enter = continue  |  type = inject guidance  |  stop = end early]${timeout_hint}${RESET}"

      local inject=""
      if [[ "$INTERJECT_TIMEOUT" -gt 0 ]]; then
        read -t "$INTERJECT_TIMEOUT" -r -p "  > " inject || true
      else
        read -r -p "  > " inject || true
      fi

      if [[ "$inject" == "stop" ]] || [[ "$inject" == "decide" ]]; then
        echo -e "${YELLOW}  Ending early — moving to synthesis...${RESET}"
        break
      elif [[ -n "$inject" ]]; then
        last_turn="${last_turn}

[USER GUIDANCE — acknowledge and incorporate this]:
${inject}"
        printf "\n**[USER INTERJECTION, Round %d]:** %s\n" "$round" "$inject" >> "$transcript"
        echo -e "${GREEN}  Guidance injected into next round.${RESET}"
        echo ""
      else
        echo -e "${DIM}  Continuing...${RESET}"
        echo ""
      fi
    fi
  done

  # ── SYNTHESIS ───────────────────────────────────────────────────────────────
  echo ""
  gum style --bold --foreground 212 "── SYNTHESIS ─────────────────────────────────────────────────────────"
  echo ""

  local full_transcript
  full_transcript=$(cat "$transcript")
  local sp="$dir/synth_prompt.txt"
  local sr="$dir/synth_result.txt"

  case "$MODE" in
    brainstorm)
      cat > "$sp" << PROMPT
TOPIC: ${TOPIC}

DEBATE:
${full_transcript}

Compile the top 5-7 distinct ideas that emerged from this debate into a prioritized list.
For each idea: one-line title, two-sentence explanation, and why it ranked where it did.
Format as clean markdown with numbered items.
PROMPT
      gum spin --title "Compiling ideas..." -- \
        bash -c "$(declare -f call_model); call_model '${LLM_MODEL[judge]}' '$sp' '$sr'"
      ;;

    decide)
      # PolyCouncil scoring: agents score each other on a rubric.
      # A judge outputs JSON; jq picks the winner mathematically.
      # This avoids the "polite summary" problem where the judge just
      # agrees with whoever spoke last.
      cat > "$sp" << PROMPT
TOPIC: ${TOPIC}

DEBATE:
${full_transcript}

You are the final judge. Score each perspective on:
- accuracy (1-5): factual correctness
- logic (1-5): strength of reasoning
- completeness (1-5): how thoroughly they addressed the topic

Output ONLY valid JSON, no other text, no markdown fences:
{"scores":{"perspective_a":{"accuracy":0,"logic":0,"completeness":0,"total":0}},"winner":"perspective_X","verdict":"one sentence explaining the winning position"}
PROMPT
      local jr="$dir/scores.json"
      gum spin --title "Scoring perspectives..." -- \
        bash -c "$(declare -f call_model); call_model '${LLM_MODEL[judge]}' '$sp' '$jr' && sed -i '' 's/\`\`\`json//g; s/\`\`\`//g' '$jr' 2>/dev/null || echo '{}' > '$jr'"

      local winner verdict
      winner=$(jq -r '.winner // "unclear"' "$jr" 2>/dev/null || echo "unclear")
      verdict=$(jq -r '.verdict // "Synthesis unavailable"' "$jr" 2>/dev/null || echo "Synthesis unavailable")

      {
        echo "## Verdict: ${winner^}"
        echo ""
        echo "**Decision:** ${verdict}"
        echo ""
        echo "### Score Breakdown"
        jq -r '.scores | to_entries[] | "- \(.key): accuracy=\(.value.accuracy) logic=\(.value.logic) completeness=\(.value.completeness) → **\(.value.total)/15**"' \
          "$jr" 2>/dev/null || cat "$jr"
      } > "$sr"
      ;;

    review)
      cat > "$sp" << PROMPT
TOPIC: ${TOPIC}

DEBATE:
${full_transcript}

Compile all identified issues into a structured review grouped by severity:
- **Critical** — blocks launch or causes failures
- **Major** — significant UX or logic problems
- **Minor** — polish, edge cases, nice-to-haves

For each issue: one-line description and recommended fix. Format as clean markdown.
PROMPT
      gum spin --title "Compiling review..." -- \
        bash -c "$(declare -f call_model); call_model '${LLM_MODEL[judge]}' '$sp' '$sr'"
      ;;

    *)
      cat > "$sp" << PROMPT
Synthesize the final answer based on this debate.
TOPIC: ${TOPIC}
DEBATE:
${full_transcript}
PROMPT
      gum spin --title "Synthesizing..." -- \
        bash -c "$(declare -f call_model); call_model '${LLM_MODEL[judge]}' '$sp' '$sr'"
      ;;
  esac

  # Guard: if synthesis llm call failed and produced no file, write a fallback
  if [[ ! -s "$sr" ]]; then
    echo "Synthesis could not be generated — all model calls failed." > "$sr"
    echo ""
    echo -e "${RED}  All agents failed to respond. Likely cause: API keys not loaded.${RESET}"
    echo -e "${DIM}  Check your GCP auth: gcloud auth login${RESET}"
    echo -e "${DIM}  Or set keys directly: llm keys set openai / llm keys set anthropic / llm keys set gemini${RESET}"
    echo ""
  fi

  cp "$sr" "$final_out"
  printf "\n## FINAL SYNTHESIS\n\n%s\n" "$(cat "$sr")" >> "$transcript"

  # ── FINAL DISPLAY ────────────────────────────────────────────────────────────
  echo ""
  gum style --border normal --border-foreground 212 --padding "1 3" --bold "RESULT"
  echo ""
  glow "$final_out" 2>/dev/null || cat "$final_out"
  echo ""
  echo -e "${DIM}  Full transcript saved to: ${transcript}${RESET}"
}

# ─── MAIN ────────────────────────────────────────────────────────────────────
check_deps
setup_keys
run_wizard
run_debate
