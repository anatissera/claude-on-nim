#!/usr/bin/env bash
# Switches the model running inside a cc-up.sh tmux session.
#
# The real `claude` CLI can't flip backends mid-process -- it reads
# ANTHROPIC_BASE_URL/ANTHROPIC_MODEL once at startup (see claude-nim.sh).
# This does the best available approximation: kill and relaunch the pane on
# the new model with --continue, which replays the full transcript.
#
# Usage (after ./scripts/install.sh, runnable from any directory as `cc-switch`):
#   cc-switch work kimi                       # from outside: asks the
#                                              # outgoing model for a brief
#                                              # handoff via tmux send-keys,
#                                              # then relaunches.
#   cc-switch work sonnet --dangerously-skip-permissions
#
#   cc-switch --self kimi                     # from INSIDE a running
#                                              # session's own Claude session
#                                              # (e.g. via a /cc-switch slash
#                                              # command): write your own
#                                              # handoff as your response,
#                                              # then this schedules the
#                                              # relaunch ~1s later so the
#                                              # response has time to save.
set -euo pipefail

if ! command -v tmux >/dev/null 2>&1; then
  echo "FAIL: tmux is not installed. Install it first: sudo apt install tmux" >&2
  exit 1
fi

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"

if [[ "${1:-}" == "--self" ]]; then
  MODEL="${2:-}"
  if [[ -z "$MODEL" ]]; then
    echo "Usage: $0 --self <model> [claude flags...]" >&2
    exit 1
  fi
  shift 2
  PANE="${TMUX_PANE:-}"
  if [[ -z "$PANE" ]]; then
    echo "FAIL: --self must run inside a tmux pane (TMUX_PANE is not set)." >&2
    exit 1
  fi
  echo "INFO: scheduling relaunch of this pane on model '$MODEL' in ~1s (--continue will replay this transcript, handoff included)..." >&2
  setsid bash -c "sleep 1; tmux respawn-pane -k -t '$PANE' '$REPO_DIR/scripts/claude-nim.sh $MODEL --continue $*'" </dev/null >/tmp/cc-switch-self.log 2>&1 &
  disown
  exit 0
fi

SESSION_NAME="${1:-}"
MODEL="${2:-}"
if [[ -z "$SESSION_NAME" || -z "$MODEL" ]]; then
  echo "Usage: $0 <session-name> <model> [claude flags...]" >&2
  echo "       $0 --self <model> [claude flags...]" >&2
  exit 1
fi
shift 2

TMUX_SESSION="cc-${SESSION_NAME}"

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "FAIL: tmux session '$TMUX_SESSION' is not running. Start it first: cc-up $SESSION_NAME" >&2
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
