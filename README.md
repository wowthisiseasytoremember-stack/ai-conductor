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
