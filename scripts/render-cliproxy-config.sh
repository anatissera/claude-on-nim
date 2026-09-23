#!/usr/bin/env bash
# Renders proxy/cliproxy-config.yaml.template -> proxy/cliproxy-config.yaml,
# substituting secrets from .env.
#
# CLIProxyAPI parses its config with a plain yaml.Unmarshal and has no
# `os.environ/VAR` equivalent, so the keys have to be literal in the file. The
# rendered output is gitignored for that reason -- treat it like .env.
#
# Multiple NIM keys: set NVIDIA_NIM_API_KEY plus NVIDIA_NIM_API_KEY_2,
# NVIDIA_NIM_API_KEY_3, ... in .env. Each becomes an api-key-entries item that
# CPA rotates between per `routing.strategy`. Free NIM keys are per-account and
# each carries its own ~40 RPM allowance and credit pool, so a second key is the
# most direct way to raise the ceiling.
#
# Usage: ./scripts/render-cliproxy-config.sh
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
TEMPLATE="$REPO_DIR/proxy/cliproxy-config.yaml.template"
OUTPUT="$REPO_DIR/proxy/cliproxy-config.yaml"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL: $ENV_FILE not found. Copy .env.example to .env and fill it in first." >&2
  exit 1
fi
if [[ ! -f "$TEMPLATE" ]]; then
  echo "FAIL: $TEMPLATE not found." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

placeholder_or_empty() {
  case "$1" in
    ""|nvapi-replace-me|sk-replace-me) return 0 ;;
    *) return 1 ;;
  esac
}

if placeholder_or_empty "${PROXY_MASTER_KEY:-}"; then
  echo "FAIL: set a real PROXY_MASTER_KEY in $ENV_FILE before rendering." >&2
  exit 1
fi
if placeholder_or_empty "${NVIDIA_NIM_API_KEY:-}"; then
  echo "FAIL: set a real NVIDIA_NIM_API_KEY in $ENV_FILE before rendering." >&2
  exit 1
fi

# Collect NVIDIA_NIM_API_KEY, then _2, _3, ... stopping at the first gap so a
# typo'd suffix can't silently drop a key that comes after it.
nim_keys=("$NVIDIA_NIM_API_KEY")
index=2
while true; do
  var="NVIDIA_NIM_API_KEY_${index}"
  value="${!var:-}"
  if placeholder_or_empty "$value"; then
    break
  fi
  nim_keys+=("$value")
  index=$((index + 1))
done

# Built at the indentation the template's api-key-entries block expects.
entries=""
for key in "${nim_keys[@]}"; do
  entries+="      - api-key: \"${key}\""$'\n'
done
entries="${entries%$'\n'}"

rendered="$(cat "$TEMPLATE")"
rendered="${rendered//\$\{NIM_API_KEY_ENTRIES\}/$entries}"
rendered="${rendered//\$\{PROXY_MASTER_KEY\}/$PROXY_MASTER_KEY}"

# The template mentions $NVIDIA_NIM_API_KEY inside a shell snippet in a comment,
# which is intentionally left as-is; only dollar-brace markers are substituted.
if [[ "$rendered" == *'${'* ]]; then
  echo "WARN: the rendered config still contains a '\${' marker -- check the template for a placeholder this script doesn't know about." >&2
fi

umask 077
printf '%s\n' "$rendered" > "$OUTPUT"

if (( ${#nim_keys[@]} > 1 )); then
  echo "INFO: wrote $OUTPUT (0600, gitignored) with ${#nim_keys[@]} NIM keys in the pool." >&2
else
  echo "INFO: wrote $OUTPUT (0600, gitignored) with 1 NIM key." >&2
  echo "INFO: add NVIDIA_NIM_API_KEY_2 to $ENV_FILE to start rotating across a pool." >&2
fi
