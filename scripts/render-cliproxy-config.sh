#!/usr/bin/env bash
# Renders proxy/cliproxy-config.yaml.template -> proxy/cliproxy-config.yaml,
# substituting secrets from .env.
#
# CLIProxyAPI parses its config with a plain yaml.Unmarshal and has no
# `os.environ/VAR` equivalent, so the keys have to be literal in the file. The
# rendered output is gitignored for that reason -- treat it like .env.
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

# Only these markers are substituted. Anything else stays literal, so a stray
# ${...} in a comment can't silently pull in an unrelated environment variable.
REQUIRED_VARS=(NVIDIA_NIM_API_KEY PROXY_MASTER_KEY)

for var in "${REQUIRED_VARS[@]}"; do
  value="${!var:-}"
  case "$value" in
    ""|nvapi-replace-me|sk-replace-me)
      echo "FAIL: set a real $var in $ENV_FILE before rendering." >&2
      exit 1
      ;;
  esac
done

rendered="$(cat "$TEMPLATE")"
for var in "${REQUIRED_VARS[@]}"; do
  # Bash replacement rather than sed, so the secret never lands in a process
  # argument list, and so characters special to sed can't corrupt the output.
  rendered="${rendered//\$\{$var\}/${!var}}"
done

if [[ "$rendered" == *'${'* ]]; then
  echo "WARN: the rendered config still contains a '\${' marker -- check the template for a variable this script doesn't know about." >&2
fi

umask 077
printf '%s\n' "$rendered" > "$OUTPUT"

echo "INFO: wrote $OUTPUT (0600, gitignored)." >&2
echo "INFO: next: docker compose up -d cliproxy && PROXY_URL=http://localhost:8317 ./scripts/validate-proxy.sh" >&2
