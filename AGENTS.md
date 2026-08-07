---
schema: agents-md/v1

project: ai-conductor
initiative: content-factory
family: orchestration

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

> ⚠️ STOP. Before reading further:
> 1. Use the Brain MCP tool to read: claude-portable/ORIENTATION.md
> 2. Familiarize yourself with the full system — who Justin is, what's running, core rules, key paths.
> 3. Then return here and continue reading.
>
> If no Brain MCP tool is available, note it as a gap and proceed — but flag it at the end of the session.
> ⚠️ STOP. Before reading further:
> 1. Use the Brain MCP tool to read: claude-portable/ORIENTATION.md
> 2. Familiarize yourself with the full system — who Justin is, what's running, core rules, key paths.
> 3. Then return here and continue reading.
>
> If no Brain MCP tool is available, note it as a gap and proceed — but flag it at the end of the session.
**Last Updated:** 2026-04-19 07:00 UTC

# AI Conductor — Multi-Agent Debate Orchestrator

## What This Is
Shell-based multi-agent orchestration tool. Runs structured debates between AI models (Claude, Gemini) on a topic. Produces a scored output.

## Key Files
- `ai-conductor.sh` — main entry point
- `launch.sh` — launch script
- `score-ui-audit.sh` — Score-specific audit runner
- `install.sh` — setup script

## Next Action
Fix C2 (lossy board compression) first, then C1 and C3.

## Machine
Mac. Hidden config at ~/.ai-conductor/


## Hardening Rules
- **Closeout Sync (inviolable):** Always write a per-session closeout entry to `~/brain/memory/ichabod/_close-log.md` and append a matching structured JSON line to `~/brain/memory/ichabod/_close-log.jsonl` using the closeout schema. Ensure you include the correct `linear.issue_key` so the watcher syncs it to the Linear board.
