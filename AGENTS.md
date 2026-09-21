---
schema: agents-md/v1
project: ai-conductor
initiative: agent-infra
family: tooling
what: >-
  Shell-based multi-agent debate orchestrator that runs structured model
  debates for brainstorming, decisions, and reviews, then synthesizes an
  advisory scored verdict.
status: active
stack: [bash]
entrypoints:
  - ai-conductor.sh
  - launch.sh
modules:
  - name: Conductor
    path: ai-conductor.sh
    does: Runs debate rounds, model/provider calls, transcript handling, and synthesis.
  - name: Score UI audit
    path: score-ui-audit.sh
    does: Purpose-built audit runner for the Score UI.
  - name: Installer
    path: install.sh
    does: New-machine setup that mutates local dependencies/configuration.
updated: 2026-09-21 17:48 UTC
---

# AGENTS.md — ai-conductor

## Project identity

AI Conductor is a shell-based orchestration tool for structured multi-model
debates. Its synthesized verdict is advisory evidence, not authority to mutate
another repository, deploy a system, or make external-state changes.

Canonical project ID: `ai-conductor`.

Before editing, verify the current checkout, branch, dirty state, and current
provider configuration.

## Context sources

Use current project/machine context sources when they are available and relevant.

An optional memory, Brain, MCP, or orientation connector is not a mandatory
dependency for ordinary repository work. Do not block routine source inspection
because a legacy context service is unavailable.

When prior decisions materially affect the task, prefer current durable project
evidence such as source, issues/PRs, current plans, and available operator
context over stale session boilerplate.

## Machine and runtime assumptions

This repository is cross-environment tooling.

Do not encode a permanent claim that the active machine is macOS, Linux, or any
specific host. Check the effective environment before installation or runtime
work.

`~/.ai-conductor/` is local runtime/configuration state, not repository truth.

`install.sh` contains machine-setup behavior and may have platform/tooling
assumptions. Inspect it before execution.

## External model/provider boundary

Running a debate is an external/network action.

The conductor can call multiple model/provider CLIs or APIs. Those calls may:

- consume provider quota or incur cost;
- send the debate prompt/transcript to external services;
- fail because credentials, aliases, models, or provider CLIs have changed;
- produce nondeterministic output.

Do not run a debate merely to validate documentation.

Do not hard-code old provider/model aliases as guaranteed current. Current
source plus current provider/runtime evidence outranks historical AGENTS or
session notes.

Never expose API keys, access tokens, credential-store output, or secret values
in transcripts, issues, logs, or receipts.

## Command classes

### Read-only/static inspection

Examples:

```bash
bash -n ai-conductor.sh launch.sh score-ui-audit.sh install.sh
git diff --check
```

These inspect syntax/diffs without intentionally invoking providers.

### Debate/provider execution

Running `ai-conductor.sh` may make external model calls and create/update
transcripts or result artifacts.

`score-ui-audit.sh` independently invokes the `llm` CLI/provider models and may
load provider credentials while writing audit outputs. Its documented `--dry-run`
path is the appropriate no-model-call planning mode only where current source
continues to enforce that behavior.

Treat preflight/provider probes as external calls unless current source proves
they are purely local.

### Process/session mutation

`launch.sh` creates/manages tmux-backed execution sessions.

Starting or killing sessions is runtime/process mutation, not static
validation.

### Machine mutation

`install.sh` installs/configures dependencies and local machine state.

Do not run it for an AGENTS-only change.

## Verdict authority

A synthesized debate verdict is a recommendation/evidence artifact.

It does not itself authorize:

- editing another project;
- merging a PR;
- deploying software;
- changing credentials;
- mutating production/runtime state;
- changing operator-owned configuration.

Those actions require the controlling task/project scope.

## Current work authority

Do not keep a permanent “next action” queue in AGENTS.md.

Current priorities belong in current issues, PRs, TODO/status documents, or
explicit operator instructions. Historical C1/C2/C3 or similar labels are not
evergreen execution authority unless a current controlling record says so.

## Completion and closeout

Provide the completion evidence requested by the active task/issue/PR.

Use a machine-wide closeout/memory mechanism only when the current environment
explicitly requires and provides it. Do not write arbitrary memory files,
Linear issues, or external tracking state solely because historical AGENTS
prose once required it.

## Validation for policy-only changes

For an AGENTS-only change:

- run the current worktree-aware frontmatter validator when locally available;
- verify module/entrypoint paths exist;
- run Bash syntax checks on the shell entrypoints;
- run a secret scan;
- run `git diff --check`;
- do not invoke model providers;
- do not create tmux sessions;
- do not run the installer;
- do not mutate external memory/project-management systems.

## Completion receipt

For substantive work, report:

```text
TASK_STATUS=<PASS|FAIL|BLOCKED>
BASE_SHA=<sha>
HEAD_SHA=<sha>
CHANGED_FILES=<count>
MODEL_PROVIDER_CALLS=<YES|NO>
TMUX_OR_RUNTIME_STATE_CHANGED=<YES|NO>
INSTALLER_EXECUTED=<YES|NO>
EXTERNAL_TRACKER_STATE_CHANGED=<YES|NO>
SECRET_EXPOSURE=<NONE|DETECTED>
BLOCKERS=<NONE|description>
```
