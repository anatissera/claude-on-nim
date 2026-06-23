#!/usr/bin/env bash
# Launches your normal, interactive `claude` CLI — same skills, MCPs,
# settings, CLAUDE.md — but redirected to run inference through the
# LiteLLM proxy onto NVIDIA NIM instead of Anthropic.
#
# IMPORTANT: this can only pick the model for a *new* `claude` process.
# ANTHROPIC_BASE_URL/ANTHROPIC_MODEL are read once at startup -- there is no
# way to flip the backend inside an already-running session. To "switch
# mid-conversation," exit (or open a new terminal) and relaunch with
# --continue (last conversation in this dir) or --resume <session_id>, which
# replays the existing history into the new process.
#
# Usage:
#   ./scripts/claude-nim.sh                   # fresh session, default model (glm-5.1)
#   ./scripts/claude-nim.sh gpt-oss            # fresh session on gpt-oss-120b
#   ./scripts/claude-nim.sh kimi --continue    # continue your last conversation, now on kimi-k2.6
#   ./scripts/claude-nim.sh deepseek --resume <session_id>
#
# Recognized shortcuts: sonnet|glm, opus|deepseek, haiku|kimi, gpt-oss.
# Anything else as $1 is treated as a raw litellm model_name. All remaining
# arguments are passed straight through to `claude`.
set -euo pipefail

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
