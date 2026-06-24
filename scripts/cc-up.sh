#!/usr/bin/env bash
# Launches (or re-attaches to) a persistent tmux session running
# claude-nim.sh. This makes the interactive `claude` CLI survive
# terminal/SSH disconnects, and is the session that cc-remote.sh exposes
# over ttyd for control from another device (e.g. your phone).
#
# Usage (after ./scripts/install.sh, runnable from any directory as `cc-up`):
#   cc-up                      # session "default", default model
#   cc-up work kimi            # session "work" on kimi
#   cc-up work kimi --continue # ...continuing its last conversation
#
# Re-running with the same session name attaches to the existing session
# instead of relaunching, so you don't lose it by accident. To force a fresh
# process, kill it first: tmux kill-session -t cc-<name>
set -euo pipefail

if ! command -v tmux >/dev/null 2>&1; then
  echo "FAIL: tmux is not installed. Install it first: sudo apt install tmux" >&2
  exit 1
fi

SESSION_NAME="${1:-default}"
shift || true

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
TMUX_SESSION="cc-${SESSION_NAME}"

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "INFO: session '$TMUX_SESSION' already running -- attaching." >&2
  exec tmux attach-session -t "$TMUX_SESSION"
fi

echo "INFO: starting new session '$TMUX_SESSION'." >&2
exec tmux new-session -s "$TMUX_SESSION" -c "$REPO_DIR" "$REPO_DIR/scripts/claude-nim.sh" "$@"
