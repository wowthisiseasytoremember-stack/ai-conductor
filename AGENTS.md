---
schema: agents-md/v1

project: ai-conductor
initiative: agent-infra
family: tooling

what: >-
  Shell-based multi-agent debate orchestrator. Given a topic and a mode —
  brainstorm, decide or review — it runs a structured multi-round debate
  between several LLMs and synthesizes a scored verdict. Uses blind first
  rounds, adversarial personas, an anonymized transcript and context
  compression between rounds, and allows a human to interject with an
  auto-timeout.

stack: [bash]
entrypoints:
  - ai-conductor.sh
  - launch.sh

modules:
  - name: Conductor
    path: ai-conductor.sh
    does: Main entry point — runs debate rounds and produces scored output.
  - name: Score UI audit
    path: score-ui-audit.sh
    does: Purpose-built audit runner for the Score UI.
  - name: Installer
    path: install.sh
    does: New-machine setup; config lives in ~/.ai-conductor/.

updated: "2026-10-01"
---

# AI Conductor — Agent Policy

## Repository identity

AI Conductor is a shell-based multi-model debate/review tool. It is advisory tooling: its synthesized verdicts do not authorize mutation in another project.

Current work selection belongs in GitHub Issues/PRs and current source. Do not keep a permanent "next action" queue in this file.

## Context

Use current machine/project context sources when available. Absence of an optional memory/context connector is not a blocker to ordinary repository work.

## Environment boundary

This repository is cross-environment tooling, but several scripts contain macOS/Homebrew assumptions.

- Inspect the current host before installation or execution.
- `install.sh` is a mutating installer and currently assumes Homebrew/macOS.
- `~/.ai-conductor/` is local runtime/config state, not repository truth.
- Do not claim a canonical current machine or OS from this document alone.

## Side effects and safety

- `ai-conductor.sh` and `score-ui-audit.sh` make external model/provider calls. These may incur cost and are not pure local validation.
- Their preflight checks also call providers.
- `launch.sh` creates tmux sessions and running processes.
- `install.sh` installs packages, may install Homebrew/Google Cloud SDK, writes a Desktop launcher, and changes local executable state.
- Ordinary code/doc review must not run debates, model calls, installers, or tmux sessions automatically.
- Never expose API keys, Secret Manager values, or provider credentials in logs, transcripts, Issues, or PR comments.
- Model/provider availability and aliases are runtime state. Verify current source/runtime before asserting a provider is available.
- Fallback behavior is defined in current source and can change; verify it rather than relying on old docs.
- Debate output is advisory evidence. It does not override the owning project's code, current Issue/PR, explicit operator decision, or external factual source.

## Source boundaries

Key current entrypoints:

- `ai-conductor.sh` — interactive multi-model debate engine.
- `launch.sh` — starts independent conductor sessions in tmux.
- `score-ui-audit.sh` — Score-specific multi-model UI audit pipeline.
- `install.sh` — environment setup; mutating and platform-sensitive.
- `README.md` — user-facing setup/usage documentation.
- `CHANGELOG.md` — accepted history.

## Completion

For repository work, provide a concise completion receipt in the active Issue/PR/task. Use any machine-wide closeout mechanism only when it is explicitly current and required. Do not write arbitrary memory files or external board state merely because an old repository policy once required it.
