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
ENABLE_RESEARCH="false"

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
  echo -e "${DIM}  Analyzing screenshot with GPT-4o (30s timeout)...${RESET}"
  timeout 30 llm -m "${LLM_MODEL[openai]}" -a "$img" \
    "Describe this screenshot exhaustively for AI models that cannot see it. Cover: all visible text, UI elements, layout structure, colors, visual hierarchy, and any data or state shown. Format as structured markdown." \
    > "$out" 2>/dev/null \
    || timeout 45 llm -m "${LLM_MODEL[gemini]}" -a "$img" \
    "Describe this screenshot exhaustively for AI models that cannot see it. Cover: all visible text, UI elements, layout structure, colors, visual hierarchy, and any data or state shown. Format as structured markdown." \
    > "$out" 2>/dev/null \
    || echo "Screenshot analysis failed — describe it manually in context." > "$out"
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
      # Try GPT-4o first (best vision), fall back to Gemini if OpenAI quota exceeded or times out
      gum spin --title "  Analyzing image: $(basename "$file")..." -- \
        bash -c "timeout 30 llm -m '${LLM_MODEL[openai]}' -a '$file' < '$img_prompt_file' > '$img_desc_file' 2>/dev/null \
          || timeout 45 llm -m '${LLM_MODEL[gemini]}' -a '$file' < '$img_prompt_file' > '$img_desc_file' 2>/dev/null \
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

# ─── PROJECT CONTEXT GENERATOR ───────────────────────────────────────────────
# Scans the current working directory for project docs (CLAUDE.md, ARCHITECTURE.md,
# README, design specs) and uses Claude Code to write a concise briefing:
# what the app does, what the specific page/feature does, and what decisions
# are already locked in — so agents don't re-litigate settled choices.
generate_project_context() {
  local topic="$1"
  local pf="/tmp/conductor_projctx_prompt_$$"
  local out="/tmp/conductor_projctx_out_$$"
  local cwd
  cwd="$(pwd)"

  # Build a list of doc files to read
  local doc_list=""
  for f in CLAUDE.md README.md _dev/docs/tech/ARCHITECTURE.md \
            _dev/docs/design/DESIGN_RECONCILIATION.md \
            _dev/docs/shipping/SHIPPING_STATUS_V1.md; do
    [[ -f "$cwd/$f" ]] && doc_list="${doc_list}${cwd}/${f}\n"
  done
  # Also check for any CLAUDE.md up one level
  [[ -f "$HOME/.claude/CLAUDE.md" ]] && doc_list="${doc_list}${HOME}/.claude/CLAUDE.md\n"

  cat > "$pf" << PROJPROMPT
You are helping set up a multi-agent AI debate. Read the project documentation files listed below and write a concise context briefing (200-300 words) for AI debate agents.

The briefing must cover:
1. What this app/project does (1-2 sentences)
2. What the specific screen, component, or feature being debated does and how it fits into the app (if determinable from the topic)
3. Key architectural decisions or design invariants that are ALREADY LOCKED IN and must NOT be re-debated (e.g. "currency uses Decimal not Double", "no gradient backgrounds", specific tech choices already made)
4. Any relevant constraints agents should know (tech stack, user tier system, data model patterns)

Keep it tight. Agents are smart — just give them the anchors so they don't suggest things that are already handled or decided elsewhere.

Topic being debated: ${topic}

Project documentation to read:
$(echo -e "$doc_list" | while read -r f; do
  [[ -z "$f" ]] && continue
  echo "=== $f ==="
  head -80 "$f" 2>/dev/null || echo "(file not readable)"
  echo ""
done)
PROJPROMPT

  gum spin --title "  Scanning project docs for context..." -- \
    bash -c "claude --print -p \"\$(cat '$pf')\" > '$out' 2>/dev/null || echo 'Project context scan failed.' > '$out'; true"

  local result
  result=$(cat "$out" 2>/dev/null || echo "")
  rm -f "$pf" "$out"

  if [[ -n "$result" ]] && [[ "$result" != "Project context scan failed." ]]; then
    gum style --foreground 82 "  Project context injected."
    echo "$result"
  else
    gum style --foreground 214 "  No project docs found — skipping."
    echo ""
  fi
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
# ─── PROMPT ENHANCER ─────────────────────────────────────────────────────────
# Takes the user's raw natural-language intent + all gathered context and uses
# Claude (the orchestrator itself) to:
#   1. Detect the right debate mode
#   2. Rewrite the prompt into a sharp, specific debate question
#   3. Suggest the right agents and round count
#   4. Explain what was changed and why (rationale shown to user)
# Returns structured output parsed back into MODE/TOPIC/AGENTS_STR/ROUNDS globals.
enhance_prompt() {
  local raw_intent="$1"
  local context_preview="${CONTEXT_TEXT:0:3000}"  # cap to avoid bloating the meta-call
  local pf="/tmp/conductor_enhance_prompt_$$"
  local out="/tmp/conductor_enhance_out_$$"

  cat > "$pf" << 'ENHEOF'
You are the AI Conductor — an orchestrator for multi-agent AI debates. A user has described what they want in natural language. Your job is to interpret their intent and produce a polished debate setup.

Rules:
- MODE must be exactly one of: brainstorm | decide | review
  - brainstorm: exploring ideas, "what should we...", "help me think about...", "how might we..."
  - decide: choosing between options, "should we...", "which is better...", "is X worth it..."
  - review: critiquing something specific — a design, screen, plan, code, or written thing
- TOPIC must be a single sentence (max 120 chars). Make it specific and concrete. Include relevant constraints visible in the context (tech stack, component names, existing decisions). Remove vague filler.
- AGENTS: pick 3 from: claude, gemini, deepseek, groq, perplexity, mistral. Use perplexity for factual/market topics. Use groq for fast counterpoint. Default: claude,gemini,deepseek
- ROUNDS: integer 2-5. brainstorm→3, decide→4, review→2
- RATIONALE: 1-2 sentences max. Say what you changed and why. Be direct.

Output ONLY these 5 lines, nothing else:
MODE: [mode]
TOPIC: [improved single-sentence debate question]
AGENTS: [comma-separated]
ROUNDS: [number]
RATIONALE: [explanation]
ENHEOF

  # Append the dynamic parts after the heredoc (avoids variable expansion issues)
  printf '\nUser raw input: %s\n\nContext available:\n%s\n' \
    "$raw_intent" "$context_preview" >> "$pf"

  gum spin --title "  Sharpening your prompt..." -- \
    bash -c "claude --print -p \"\$(cat '$pf')\" > '$out' 2>/dev/null || echo 'ENHANCE_FAILED' > '$out'; true"

  local result
  result=$(cat "$out" 2>/dev/null || echo "ENHANCE_FAILED")
  rm -f "$pf" "$out"
  echo "$result"
}

run_wizard() {
  clear
  gum style \
    --border double \
    --border-foreground 212 \
    --padding "1 4" \
    --margin "1 2" \
    --bold "AI DEBATE CONDUCTOR"

  # Step 1: Natural language intent — no mode selector, no rigid format required.
  # The orchestrator figures out mode, sharpens the question, picks agents.
  echo ""
  gum style --bold "Step 1: What do you want to work on?"
  gum style --foreground 245 "Plain English. Ask a question, describe a decision, or name a thing to review."
  local RAW_INTENT
  RAW_INTENT=$(gum input \
    --placeholder "e.g. should we break up the item detail view into smaller screens" \
    --width 90)
  [[ -z "$RAW_INTENT" ]] && { echo "Nothing entered. Exiting."; exit 1; }

  # Step 2: Context
  echo ""
  gum style --bold "Step 2: Context"
  if gum confirm --default=false "Add context? (files, screenshots, docs, pasted text)"; then
    gather_context_interactive
  else
    CONTEXT_TEXT=""
    SCREENSHOT_PATH=""
  fi

  # Step 2.5: Project context injection
  echo ""
  gum style --bold "Step 2.5: Project context"
  gum style --foreground 245 "Scans CLAUDE.md, ARCHITECTURE.md, and design specs in this directory."
  if gum confirm --default=false "Inject project context? (tells agents what's already decided)" 2>/dev/null || false; then
    local proj_ctx
    proj_ctx=$(generate_project_context "$RAW_INTENT")
    if [[ -n "$proj_ctx" ]]; then
      CONTEXT_TEXT="--- Project Context (orchestrator-generated) ---
${proj_ctx}
--- End Project Context ---

${CONTEXT_TEXT}"
    fi
  fi

  # Step 3: Orchestrator enhances the prompt
  # Claude reads the raw intent + all gathered context, detects mode, rewrites
  # the question to be sharp and specific, suggests agents and rounds.
  echo ""
  gum style --bold "Step 3: Sharpening your prompt..."
  local enhanced
  enhanced=$(enhance_prompt "$RAW_INTENT")

  # Parse structured output — each field is on its own labeled line
  local e_mode e_topic e_agents e_rounds e_rationale
  e_mode=$(echo "$enhanced"    | grep -m1 '^MODE:'      | sed 's/^MODE: *//')
  e_topic=$(echo "$enhanced"   | grep -m1 '^TOPIC:'     | sed 's/^TOPIC: *//')
  e_agents=$(echo "$enhanced"  | grep -m1 '^AGENTS:'    | sed 's/^AGENTS: *//')
  e_rounds=$(echo "$enhanced"  | grep -m1 '^ROUNDS:'    | sed 's/^ROUNDS: *//')
  e_rationale=$(echo "$enhanced" | grep -m1 '^RATIONALE:' | sed 's/^RATIONALE: *//')

  # Validate mode — fall back to decide if the enhancer returned garbage
  case "$e_mode" in
    brainstorm|decide|review) ;;
    *) e_mode="decide" ;;
  esac

  # Validate rounds — fall back sensibly
  [[ "$e_rounds" =~ ^[0-9]+$ ]] || e_rounds=3

  # Fall back to raw intent if topic came back empty
  [[ -z "$e_topic" ]] && e_topic="$RAW_INTENT"

  # Show the enhanced prompt to the user with rationale
  echo ""
  gum style --border normal --border-foreground 82 --padding "1 2" \
    --bold "Orchestrator improved your prompt:"
  echo ""
  gum style --foreground 212 "  Mode:    $e_mode"
  gum style --foreground 212 "  Topic:   $e_topic"
  gum style --foreground 212 "  Agents:  $e_agents"
  gum style --foreground 212 "  Rounds:  $e_rounds"
  echo ""
  [[ -n "$e_rationale" ]] && gum style --foreground 245 --italic "  $e_rationale"
  echo ""

  # Step 4: Let user edit before committing — all fields pre-filled from enhancer
  gum style --bold "Step 4: Review and adjust (press Enter to accept)"

  TOPIC=$(gum input \
    --header "Debate question (edit or accept):" \
    --value "$e_topic" \
    --width 90)
  TOPIC="${TOPIC:-$e_topic}"

  MODE=$(gum choose \
    --header "Mode:" \
    --selected "$e_mode" \
    "brainstorm" "decide" "review")
  MODE="${MODE:-$e_mode}"

  ROUNDS=$(gum input \
    --header "Total passes (baseline + debate rounds — baseline is always first):" \
    --value "$e_rounds" \
    --width 10)
  ROUNDS="${ROUNDS:-$e_rounds}"

  AGENTS_STR=$(gum input \
    --header "Models (comma-separated):" \
    --value "$e_agents" \
    --placeholder "claude,gemini,deepseek" \
    --width 50)
  AGENTS_STR="${AGENTS_STR:-$e_agents}"
  # Always need at least one agent
  [[ -z "$AGENTS_STR" ]] && AGENTS_STR="claude,gemini,deepseek"

  # Step 5: Interjection
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

  # Step 6: Perplexity research pass (optional)
  echo ""
  gum style --bold "Step 6: Research grounding (optional)"
  gum style --foreground 245 "Runs a Perplexity Sonar Pro search before Round 1 — useful for factual or market topics."
  if gum confirm --default=false "Run a Perplexity research pass first?" 2>/dev/null || false; then
    ENABLE_RESEARCH="true"
  fi

  # Final confirmation — shows the fully enhanced, user-reviewed prompt
  echo ""
  gum style --border double --border-foreground 212 --padding "1 3" \
    "MODE: $MODE  |  ROUNDS: $ROUNDS  |  MODELS: $AGENTS_STR
TOPIC: $TOPIC"
  echo ""
  gum confirm "Start the debate with this prompt?" || exit 0
}

# ─── PERPLEXITY RESEARCH PASS ────────────────────────────────────────────────
# Optional pre-debate step. Calls Perplexity Sonar Pro to ground the debate in
# current factual context (market data, recent developments, citations).
# Results are injected into every agent's context before Round 1.
# Cost: ~$0.002 per call. Skipped gracefully if Perplexity key isn't loaded.
run_research_pass() {
  local topic="$1"
  local out="$2"

  local pf="/tmp/conductor_research_prompt_$$"
  cat > "$pf" << RPROMPT
You are a research assistant. Search for current, factual information about the following topic and return a concise briefing (300-500 words) that will help AI models debate it intelligently.

Include: key facts, recent developments, relevant statistics or data points, and notable perspectives or arguments already in the field. Cite sources where available.

Topic: ${topic}
RPROMPT

  local ef="/tmp/conductor_research_err_$$"
  gum spin --title "  Running Perplexity research pass..." -- \
    bash -c "timeout 60 llm -m '${LLM_MODEL[perplexity]}' < '$pf' > '$out' 2>'$ef'; true"

  local success=false
  if [[ -s "$out" ]] && ! grep -q "unavailable\|skipped\|error" "$out" 2>/dev/null; then
    success=true
  fi

  rm -f "$pf" "$ef"

  if [[ "$success" == "true" ]]; then
    gum style --foreground 82 "  Research pass complete — context injected."
    # Prepend to CONTEXT_TEXT so all agents see it
    local research_content
    research_content=$(cat "$out")
    CONTEXT_TEXT="--- Perplexity Research (pre-debate) ---
${research_content}
--- End Research ---

${CONTEXT_TEXT}"
  else
    gum style --foreground 214 "  Perplexity unavailable — skipping research pass (debate will continue)."
    echo "[Perplexity research unavailable]" > "$out"
  fi
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
  local debate_rounds=$((ROUNDS - 1))
  {
    echo "# AI Conductor — $MODE Mode"
    echo "**Topic:** $TOPIC"
    echo "**Date:** $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "**Structure:** 1 baseline pass + ${debate_rounds} debate round(s)  |  Agents: $AGENTS_STR"
    echo "---"
  } > "$transcript"

  # Split terminal or show paste command — happens before first round
  setup_tmux_split "$transcript"

  # Optional pre-debate research pass — injects Perplexity results into CONTEXT_TEXT
  # before any agent sees the topic, so all perspectives are grounded in current facts
  if [[ "$ENABLE_RESEARCH" == "true" ]]; then
    run_research_pass "$TOPIC" "$dir/research.md"
  fi

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
  # Round 1 is the BASELINE — agents answer cold, in parallel, with no knowledge
  # of each other or that a debate is happening. This is Round 0 conceptually:
  # pure unvarnished positions before any cross-pollination.
  # Rounds 2..N are the actual debate where agents see the board and respond.
  for round in $(seq 1 "$ROUNDS"); do
    echo ""
    if [[ $round -eq 1 ]]; then
      gum style --bold --foreground 245 "── BASELINE  (independent positions — agents unaware of each other) ────────"
    else
      local debate_round=$((round - 1))
      local total_debate=$((ROUNDS - 1))
      gum style --bold --foreground 212 "── ROUND $debate_round of $total_debate ─────────────────────────────────────────────────────"
    fi
    echo ""

    local round_content=""

    for i in "${!AGENTS[@]}"; do
      local agent="${AGENTS[$i]}"
      local persona="${PERSONAS[$i]:-CHALLENGER}"
      local label="${ANON[$agent]}"
      local model="${LLM_MODEL[$agent]:-gpt-4o}"
      local pf="$dir/prompt_${agent}_r${round}.txt"
      local rf="$dir/response_${agent}_r${round}.txt"

      local sys
      sys=$(persona_prompt "$persona")

      if [[ $round -eq 1 ]]; then
        # Baseline round: agents don't know this is a debate or that others will respond.
        # No system framing about "rounds" or "other perspectives" — pure cold opinion.
        cat > "$pf" << PROMPT
${sys}

${ctx}Question: ${TOPIC}

Answer directly and specifically. Give your honest assessment.
PROMPT
      else
        cat > "$pf" << PROMPT
${sys}

[TOPIC]: ${TOPIC}

${ctx}STATE OF THE BOARD (summary of previous rounds):
$(cat "$board_file")

MOST RECENT TURN:
${last_turn}

INSTRUCTION: Respond to the current state of the debate. Challenge, build on, or defend positions as your role demands. Stay specific.
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

  # Save timestamped output to ~/.ai-conductor/outputs/ so other agents
  # (Claude Code, automation) can find it and pull action items into changelogs/todos
  local saved_path
  saved_path=$(save_output "$final_out" "$transcript")
  echo -e "${DIM}  Synthesis saved to:  ${saved_path}${RESET}"
  echo -e "${DIM}  Full transcript:     ${transcript}${RESET}"
  echo ""
  gum style --foreground 245 "To act on this output, run Claude Code and say:"
  gum style --foreground 212 "  \"Read ${saved_path} and add any action items to CHANGELOG.md and the project todo list.\""
}

# ─── OUTPUT SAVER ────────────────────────────────────────────────────────────
# Saves the final synthesis to ~/.ai-conductor/outputs/ with a timestamp.
# Other agents (Claude Code sessions, automation scripts) can read this dir
# to pull action items into project changelogs and todo lists.
save_output() {
  local synthesis_file="$1"
  local transcript_file="$2"
  local outdir="$HOME/.ai-conductor/outputs"
  mkdir -p "$outdir"

  local timestamp
  timestamp=$(date -u '+%Y-%m-%d-%H%M')
  local slug
  slug=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/--*/-/g' | cut -c1-45 | sed 's/-$//')
  local outfile="${outdir}/${timestamp}-${MODE}-${slug}.md"

  {
    echo "**Generated:** $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "**Mode:** $MODE"
    echo "**Topic:** $TOPIC"
    echo "**Agents:** $AGENTS_STR"
    echo "**Rounds:** $ROUNDS"
    echo ""
    echo "---"
    echo ""
    cat "$synthesis_file"
    echo ""
    echo "---"
    echo ""
    echo "_Full transcript: ${transcript_file}_"
  } > "$outfile"

  echo "$outfile"
}

# ─── MAIN ────────────────────────────────────────────────────────────────────
check_deps
setup_keys
run_wizard
run_debate
