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

## Current State
- Functional — launches and runs debates
- 3 known bugs tracked:
  - C1: Context compression issue
  - C2: Lossy board compression (fix this first)
  - C3: Third bug (see ~/.claude/CHANGELOG.md for details)
- Status: Active, functional but buggy

## Key Files
- `ai-conductor.sh` — main entry point
- `launch.sh` — launch script
- `score-ui-audit.sh` — Score-specific audit runner
- `install.sh` — setup script

## Next Action
Fix C2 (lossy board compression) first, then C1 and C3.

## Machine
Mac. Hidden config at ~/.ai-conductor/
---

### Recent Context (Auto-generated 2026-05-10)
**AI Conductor Relevance:** No direct logs found referencing `ai-conductor` in the last 7 days. The session logs focus on OpenClaw migrations (Gemini/DeepSeek API updates), Hermes/Tangle Trove infrastructure consolidation, and portfolio site deployments. Key infrastructure changes (LiteLLM model routing, brain MCP server updates) may indirectly affect multi-agent orchestration tools but no specific `ai-conductor` modifications were documented. The primary bugs (C1: context compression, C2: lossy board compression) remain unresolved in the logs. No new action items for `ai-conductor` were generated.
