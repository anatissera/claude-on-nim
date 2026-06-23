#!/usr/bin/env bash
# Switches the model running inside a cc-up.sh tmux session.
#
# The real `claude` CLI can't flip backends mid-process -- it reads
# ANTHROPIC_BASE_URL/ANTHROPIC_MODEL once at startup (see claude-nim.sh).
# This does the best available approximation: ask the outgoing model for a
# short handoff briefing, then kill and relaunch the pane on the new model
# with --continue, which replays the full transcript (briefing included).
#
# Usage:
#   ./scripts/cc-switch.sh work kimi
#   ./scripts/cc-switch.sh work sonnet --dangerously-skip-permissions
#
# If the outgoing model doesn't answer within ~2 minutes (proxy down, rate
# limited, etc.) this proceeds anyway -- --continue's transcript replay is
# the fallback, the briefing is just a head start.
set -euo pipefail

if ! command -v tmux >/dev/null 2>&1; then
  echo "FAIL: tmux is not installed. Install it first: sudo apt install tmux" >&2
  exit 1
fi

SESSION_NAME="${1:-}"
MODEL="${2:-}"
if [[ -z "$SESSION_NAME" || -z "$MODEL" ]]; then
  echo "Usage: $0 <session-name> <model> [claude flags...]" >&2
  exit 1
fi
shift 2

TMUX_SESSION="cc-${SESSION_NAME}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "FAIL: tmux session '$TMUX_SESSION' is not running. Start it first: ./scripts/cc-up.sh $SESSION_NAME" >&2
  exit 1
fi

HANDOFF_MARKER="===HANDOFF-$$==="
HANDOFF_PROMPT="Before we switch models: write a brief handoff summary (under 150 words) of the current task, what's done, and what's next. Prefix it with the exact line ${HANDOFF_MARKER} on its own line."
HANDOFF_LOG="/tmp/cc-switch-handoff-${SESSION_NAME}.txt"

echo "INFO: requesting handoff briefing from the outgoing model..." >&2
tmux send-keys -t "$TMUX_SESSION" "$HANDOFF_PROMPT" Enter

FOUND=0
for _ in $(seq 1 60); do
  if tmux capture-pane -t "$TMUX_SESSION" -p -S -200 | grep -qF "$HANDOFF_MARKER"; then
    FOUND=1
    break
  fi
  sleep 2
done

tmux capture-pane -t "$TMUX_SESSION" -p -S -200 > "$HANDOFF_LOG" || true
if [[ "$FOUND" == "1" ]]; then
  echo "INFO: handoff briefing captured -- saved to $HANDOFF_LOG" >&2
else
  echo "WARN: no handoff briefing within timeout; relying on --continue's transcript replay instead." >&2
fi

echo "INFO: relaunching session '$TMUX_SESSION' on model '$MODEL' with --continue..." >&2
tmux respawn-pane -k -t "$TMUX_SESSION" "$REPO_DIR/scripts/claude-nim.sh $MODEL --continue $*"
