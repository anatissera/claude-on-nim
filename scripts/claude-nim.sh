#!/usr/bin/env bash
# Launches your normal, interactive `claude` CLI — same skills, MCPs,
# settings, CLAUDE.md — but redirected to run inference through the
# LiteLLM proxy onto NVIDIA NIM instead of Anthropic.
#
# Auto-tmux mode: If you're not already in tmux, this script will relaunch
# itself inside a new persistent session. This way your Claude session
# survives terminal disconnects and can be switched mid-conversation with
# /cc-switch without needing to open another terminal or use cc-up.
#
# Usage (from anywhere, with your repo's .claude/ and cwd):
#   claude-nim                      # fresh session, default model (glm-5.1)
#   claude-nim gpt-oss              # fresh session on gpt-oss-120b
#   claude-nim kimi --continue      # continue your last conversation on kimi-k2.6
#   claude-nim deepseek --resume <session_id>
#
# Model shortcuts: sonnet|glm, opus|deepseek, haiku|kimi, gpt-oss.
# Inside tmux: /cc-switch <model> to switch models mid-conversation.
#             /cc-remote [port] to expose this session over Tailscale.
set -euo pipefail

# If not already in tmux, relaunch inside a new session.
if [[ -z "${TMUX:-}" ]]; then
  if ! command -v tmux >/dev/null 2>&1; then
    echo "WARN: tmux is not installed; running without persistence. Install it with: sudo apt install tmux" >&2
  else
    TMUX_SESSION="claude-$(date +%s)"
    exec tmux new-session -s "$TMUX_SESSION" "$0" "$@"
  fi
fi

MODEL_SHORTCUT="${1:-}"
case "$MODEL_SHORTCUT" in
  sonnet|glm) MODEL_NAME="glm" ; shift ;;
  opus|deepseek) MODEL_NAME="deepseek" ; shift ;;
  haiku|kimi) MODEL_NAME="kimi" ; shift ;;
  gpt-oss) MODEL_NAME="gpt-oss" ; shift ;;
  -*|"") MODEL_NAME="" ;; # looks like a claude flag, or nothing given -- don't consume it
  *) MODEL_NAME="$MODEL_SHORTCUT" ; shift ;; # assume it's a raw model_name from litellm-config.yaml
esac

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL: $ENV_FILE not found. Copy .env.example to .env and fill in NVIDIA_NIM_API_KEY / PROXY_MASTER_KEY first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "${PROXY_MASTER_KEY:-}" || "$PROXY_MASTER_KEY" == "sk-replace-me" ]]; then
  echo "FAIL: set a real PROXY_MASTER_KEY in $ENV_FILE." >&2
  exit 1
fi

PROXY_URL="http://localhost:4000"

if ! curl -sS -o /dev/null -w '' "$PROXY_URL/health/liveliness" 2>/dev/null; then
  echo "INFO: proxy not reachable at $PROXY_URL, starting it via docker compose..." >&2
  (cd "$REPO_DIR" && docker compose up -d proxy)

  for attempt in $(seq 1 12); do
    if curl -sS -o /dev/null -w '' "$PROXY_URL/health/liveliness" 2>/dev/null; then
      break
    fi
    if [[ "$attempt" == 12 ]]; then
      echo "FAIL: proxy did not become healthy in time. Check 'docker compose logs proxy'." >&2
      exit 1
    fi
    sleep 5
  done
fi

export ANTHROPIC_BASE_URL="$PROXY_URL"
export ANTHROPIC_AUTH_TOKEN="$PROXY_MASTER_KEY"
export ANTHROPIC_MODEL="${MODEL_NAME:-${AGENT_MODEL:-glm}}"

echo "INFO: claude CLI -> $ANTHROPIC_BASE_URL -> NIM model behind alias '$ANTHROPIC_MODEL'" >&2

exec claude "$@"
