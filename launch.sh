#!/usr/bin/env bash
# launch.sh — open N independent AI Conductor sessions in tmux
#
# Usage: ./launch.sh [count]   (default: 2)
#
# Each instance gets its own named tmux session and its own debate working dir.
# Attach to any session with: tmux attach -t <session-name>
# Kill all conductor sessions:
#   tmux ls | grep '^conductor-' | awk -F: '{print $1}' | xargs -I{} tmux kill-session -t {}

set -euo pipefail

COUNT="${1:-2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required. Install with: brew install tmux"
  exit 1
fi

echo "Launching ${COUNT} AI Conductor instance(s)..."
echo ""

for i in $(seq 1 "$COUNT"); do
  SESSION="conductor-${i}-$(date +%s)"
  tmux new-session -d -s "$SESSION" -x 220 -y 50 \
    "bash '${SCRIPT_DIR}/ai-conductor.sh'; exec bash"
  echo "  Session: ${SESSION}"
  echo "  Attach:  tmux attach -t ${SESSION}"
  echo ""
done

echo "All ${COUNT} instance(s) running."
echo ""
echo "View all:   tmux ls"
echo "Kill all:   tmux ls | grep '^conductor-' | awk -F: '{print \$1}' | xargs -I{} tmux kill-session -t {}"
