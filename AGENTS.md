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
    does: Main entry point — runs the debate rounds and produces the scored output.
  - name: Score UI audit
    path: score-ui-audit.sh
    does: Purpose-built audit runner for the Score UI.
  - name: Installer
    path: install.sh
    does: New-machine setup; config lives in ~/.ai-conductor/.

updated: "2026-08-07 05:48 UTC"
---

# AI Conductor — Agent Policy

AI Conductor is a shell-based multi-model debate/review tool. It can call external model providers, create local processes/tmux sessions, read secrets from configured secret stores, and mutate a workstation when its installer is executed.

## Authority and work selection

- Current source code + current GitHub Issues/PRs establish mutable project state.
- `AGENTS.md` carries durable operating rules only.
- `README.md` is user-facing setup/usage documentation, not a task queue.
- `CHANGELOG.md` is accepted history.
- `STATE.md`, old generated handoffs, and proposed Claude guidance are snapshots/reference only.
- Do not encode a permanent "next action" here. Use current GitHub Issues for current work.

Use current machine/project context sources when available. Absence of an optional memory/context connector is not a blocker to ordinary repository work.

## Environment boundary

This is cross-environment tooling, but individual scripts may contain platform assumptions.

- Inspect the current host before installing or executing.
- `install.sh` is currently macOS/Homebrew-oriented and mutates the machine.
- `~/.ai-conductor/` is local runtime/config state, not repository truth.
- Do not claim a checkout, host, or model provider is current merely because an older doc names it.

## Entry points

- `ai-conductor.sh` — interactive multi-model debate/review runner.
- `launch.sh` — launches one or more conductor instances in tmux.
- `score-ui-audit.sh` — Score-specific multi-model UI audit pipeline.
- `install.sh` — machine setup/install script.

## Side-effect and cost boundaries

Ordinary source/policy review must **not** automatically run debates, provider probes, installers, or tmux sessions.

Before execution, know that:

- model calls are network/external side effects and may incur provider cost or quota;
- preflight/provider availability checks are real provider calls, not pure local validation;
- `launch.sh` creates tmux sessions/processes;
- `install.sh` may install Homebrew, packages/plugins, Google Cloud SDK, change executable bits, and create a Desktop launcher;
- `ai-conductor.sh` and `score-ui-audit.sh` read configured secret-manager values into process environment;
- model/provider availability and aliases are runtime state; verify current source/runtime instead of assuming old README tables are accurate;
- fallback behavior must be read from current source before describing it as guaranteed;
- a debate/synthesis verdict is advisory output. It does not authorize mutations in another project.

## Secret handling

- Never print, paste, commit, or attach API keys or secret-manager values to transcripts, logs, GitHub issues, PRs, or documentation.
- Do not convert secret-store values into checked-in config.
- When investigating provider failures, report provider/model/error class without exposing credential material.

## Completion

Provide a concise completion receipt in the active issue/PR/task. Use a current machine-wide closeout mechanism only when one is explicitly available and required. Do not write arbitrary memory systems, Linear boards, or legacy close-log files merely because historical prose once required it.

## Validation for policy/source-only changes

Prefer non-side-effect checks:
- verify referenced paths exist;
- shell syntax validation where an execution environment is available;
- secret scan where available;
- `git diff --check`;
- no debate/model calls;
- no installer execution;
- no tmux/session creation.

