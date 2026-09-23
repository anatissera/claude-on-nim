#!/usr/bin/env bash
# Launches your normal, interactive `claude` CLI — same skills, MCPs,
# settings, CLAUDE.md — but redirected to run inference through the
# CLIProxyAPI proxy onto NVIDIA NIM instead of Anthropic.
#
# Auto-tmux mode: If you're not already in tmux, this script will relaunch
# itself inside a new persistent session. This way your Claude session
# survives terminal disconnects and can be switched mid-conversation with
# /cc-switch without needing to open another terminal or use cc-up.
#
# Usage (from anywhere, with your repo's .claude/ and cwd):
#   claude-nim                      # fresh session, default model (glm-5.3)
#   claude-nim gpt-oss              # fresh session on gpt-oss-20b
#   claude-nim kimi --continue      # continue your last conversation on kimi-k3
#   claude-nim deepseek --resume <session_id>
#
# Model shortcuts: sonnet|glm, opus|kimi, haiku|glm-flash, deepseek, gpt-oss.
# Only glm (z-ai/glm-5.3) is reliably warm on NIM's free tier; the others can
# take minutes to return on a cold start.
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
# The sonnet/opus/haiku words map to the same upstream models as the
# claude-sonnet-4-6 / claude-opus-4-8 / claude-haiku-4-5 aliases in
# proxy/cliproxy-config.yaml.template, so an interactive session and the headless agent
# land on the same model when asked for the same tier.
case "$MODEL_SHORTCUT" in
  sonnet|glm) MODEL_NAME="glm" ; shift ;;
  opus|kimi) MODEL_NAME="kimi" ; shift ;;
  haiku|glm-flash) MODEL_NAME="glm-flash" ; shift ;;
  deepseek) MODEL_NAME="deepseek" ; shift ;;
  gpt-oss) MODEL_NAME="gpt-oss" ; shift ;;
  -*|"") MODEL_NAME="" ;; # looks like a claude flag, or nothing given -- don't consume it
  *) MODEL_NAME="$MODEL_SHORTCUT" ; shift ;; # assume it's a raw alias from cliproxy-config.yaml.template
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

PROXY_URL="http://localhost:8317"

if ! curl -sS -o /dev/null -w '' "$PROXY_URL/healthz" 2>/dev/null; then
  # CLIProxyAPI reads literal keys from a rendered config, so on a fresh clone
  # that file does not exist yet -- and compose would silently bind-mount a
  # directory in its place. Render it before starting anything.
  if [[ ! -f "$REPO_DIR/proxy/cliproxy-config.yaml" ]]; then
    echo "INFO: proxy config not rendered yet, generating it from .env..." >&2
    "$REPO_DIR/scripts/render-cliproxy-config.sh"
  fi

  echo "INFO: proxy not reachable at $PROXY_URL, starting it via docker compose..." >&2
  (cd "$REPO_DIR" && docker compose up -d cliproxy)

  for attempt in $(seq 1 12); do
    if curl -sS -o /dev/null -w '' "$PROXY_URL/healthz" 2>/dev/null; then
      break
    fi
    if [[ "$attempt" == 12 ]]; then
      echo "FAIL: proxy did not become healthy in time. Check 'docker compose logs cliproxy'." >&2
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
