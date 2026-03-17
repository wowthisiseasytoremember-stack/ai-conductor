# AI Conductor

A multi-agent debate tool. You tell it what you need — brainstorm, decide, or review — and it runs a structured debate between Claude, GPT-4o, Gemini, and DeepSeek, then synthesizes a verdict.

## What it does

- **Brainstorm mode** — agents build on each other's ideas, produces a prioritized idea list
- **Decide mode** — agents argue positions, scored on a rubric (accuracy/logic/completeness), judge picks a winner
- **Review mode** — agents critique a design or plan, grouped by severity (Critical / Major / Minor)

Built-in best practices: blind Round 1, adversarial personas, anonymized transcript, State of the Board context compression, image analysis for non-vision models, user interjection with auto-timeout.

## Setup (new machine)

```bash
git clone https://github.com/wowthisiseasytoremember-stack/ai-conductor.git ~/Documents/ai-conductor
cd ~/Documents/ai-conductor
./install.sh
```

Then authenticate GCP (needed for API key injection):
```bash
gcloud auth login
gcloud config set project pwa-id-app
```

## Run

```bash
./ai-conductor.sh
```

Or double-click **AI Conductor** on your Desktop (created by install.sh).

## Dependencies

| Tool | Purpose | Install |
|---|---|---|
| `gum` | Interactive wizard UI | `brew install gum` |
| `llm` | Unified model caller | `brew install llm` |
| `glow` | Markdown renderer | `brew install glow` |
| `jq` | JSON parsing (decide mode scoring) | `brew install jq` |
| `gcloud` | GCP secret injection for API keys | `brew install --cask google-cloud-sdk` |

## API keys

Keys are pulled from GCP Secrets Manager at runtime — nothing is stored locally or committed to this repo. Required secrets in project `pwa-id-app`:

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `GEMINI_API_KEY`
- `DEEPSEEK_API_KEY`

## Models

Edit the `LLM_MODEL` map at the top of `ai-conductor.sh` to change which model aliases are used.

## Context gatherer

During setup, you can search for files by keyword (uses macOS Spotlight), paste text, or add screenshots. Images are described by GPT-4o so all models — vision or not — receive full context.

## tmux live view

If you run inside tmux, the script auto-splits the window and streams the transcript on the right pane. If not in tmux, it prints a `tail -f` command to paste in another terminal.

## Multi-instance (parallel debates)

Run multiple independent debates simultaneously using `launch.sh`:

```bash
./launch.sh       # starts 2 sessions (default)
./launch.sh 3     # starts 3 sessions
```

Each session gets its own named tmux session. Attach to any one:

```bash
tmux ls                              # list all running sessions
tmux attach -t conductor-1-<epoch>  # attach to a specific one
```

Kill all conductor sessions:
```bash
tmux ls | grep '^conductor-' | awk -F: '{print $1}' | xargs -I{} tmux kill-session -t {}
```

## Model availability (pre-flight)

Before Round 1, the script pings every selected agent with a trivial prompt (5s timeout). Agents that fail or time out are removed from the debate. If all agents fail, the script exits with a clear error instead of running a broken debate.

Override the preflight timeout: `PREFLIGHT_TIMEOUT=10 ./ai-conductor.sh`

## Fallback providers

If a model returns bad output (empty, too short, raw API error JSON, or our own skip-message format), the script automatically retries with a fallback model:

| Primary | Fallback |
|---------|----------|
| gemini | flash (Gemini 2.5 Flash) |
| openai | claude |
| deepseek | groq |
| perplexity | groq |
| mistral | or-free |

claude, groq, flash, or-free, or-best, and kimi are terminal tier — no further fallback.

## Timeouts

All model calls have hard timeouts enforced via `timeout(1)`. Override via env vars:

| Var | Default | Applies to |
|-----|---------|-----------|
| `DEBATE_TIMEOUT` | 45s | Each agent call during debate rounds |
| `SYNTHESIS_TIMEOUT` | 120s | Final synthesis/scoring call |
| `PREFLIGHT_TIMEOUT` | 5s | Pre-flight availability ping |

Example: `DEBATE_TIMEOUT=20 SYNTHESIS_TIMEOUT=60 ./ai-conductor.sh`

## Project Briefing (skip Perplexity with curated context)

If your project has a `README.md` with a `## Project Briefing` section timestamped less than 24 hours ago, AI Conductor uses it instead of running a Perplexity research pass. This gives the agents tighter, project-specific context — what's locked in, what's in progress, what not to re-debate.

**Generate a briefing** using the Claude Code skill:
```
/update-project-for-conductor
```

This scans your CHANGELOG.md, CLAUDE.md, and ARCHITECTURE.md, drafts a briefing, lets you edit it, then writes it to README.md.

**Briefing format** (in README.md):
```markdown
## Project Briefing
**Last Updated:** 2026-03-17 11:30 UTC

**What it is:** [1-2 sentences]
**Current focus:** [active phase / what's being built now]
**Locked-in decisions (do not flag as errors):**
- [decision and why]
**Known rough edges (intentional):**
- [thing that looks wrong but isn't]
```

The briefing is valid for 24 hours. Re-run `/update-project-for-conductor` after major state changes.
