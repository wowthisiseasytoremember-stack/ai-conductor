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
