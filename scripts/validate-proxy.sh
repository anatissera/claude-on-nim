#!/usr/bin/env bash
# Validates that the proxy speaks the Anthropic Messages protocol to NVIDIA NIM
# correctly -- a plain-text round trip plus, more importantly, a tool-call round
# trip, since the Agent SDK lives or dies on tool-use fidelity.
#
# Run it against a running `docker compose up -d cliproxy`. Override the target
# with PROXY_URL to check a proxy on another port.
set -euo pipefail

MODEL="${1:-claude-sonnet-4-6}"
AUTH_TOKEN="${PROXY_MASTER_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}"
if [[ -z "$AUTH_TOKEN" ]]; then
  echo "FAIL: set PROXY_MASTER_KEY (or ANTHROPIC_AUTH_TOKEN) before running this script." >&2
  exit 1
fi

# ANTHROPIC_BASE_URL is written for the agent container, where the proxy is a
# compose service name. From the host that name does not resolve, so anything
# that is not a loopback address is remapped to the published port. An explicit
# PROXY_URL always wins, for pointing at a proxy somewhere else.
if [[ -n "${PROXY_URL:-}" ]]; then
  : # caller pinned the target explicitly
elif [[ -z "${ANTHROPIC_BASE_URL:-}" ]]; then
  PROXY_URL="http://localhost:8317"
elif [[ "${ANTHROPIC_BASE_URL}" =~ ^https?://(localhost|127\.0\.0\.1|\[::1\])(:|/|$) ]]; then
  PROXY_URL="${ANTHROPIC_BASE_URL}"
else
  echo "INFO: ANTHROPIC_BASE_URL (${ANTHROPIC_BASE_URL}) is a container-internal address; using http://localhost:8317 from the host." >&2
  echo "      Set PROXY_URL to override." >&2
  PROXY_URL="http://localhost:8317"
fi

TEXT_RESPONSE="${TMPDIR:-/tmp}/proxy-text-response.json"
TOOL_RESPONSE="${TMPDIR:-/tmp}/proxy-tool-response.json"
MAX_ATTEMPTS="${VALIDATE_PROXY_ATTEMPTS:-12}"
RETRY_DELAY_SECONDS="${VALIDATE_PROXY_RETRY_DELAY_SECONDS:-5}"

post_messages() {
  local output_file="$1"
  local payload="$2"
  local attempt
  local http_status

  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    if http_status="$(curl -sS -o "$output_file" -w "%{http_code}" "$PROXY_URL/v1/messages" \
      -H "x-api-key: $AUTH_TOKEN" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d "$payload")"; then
      break
    fi

    if ((attempt == MAX_ATTEMPTS)); then
      echo "FAIL: could not reach $PROXY_URL/v1/messages after $MAX_ATTEMPTS attempts" >&2
      return 1
    fi

    echo "WARN: proxy is not ready yet; retrying in ${RETRY_DELAY_SECONDS}s ($attempt/$MAX_ATTEMPTS)" >&2
    sleep "$RETRY_DELAY_SECONDS"
  done

  if ! python3 -m json.tool "$output_file"; then
    echo "FAIL: proxy response was not valid JSON. Raw response:" >&2
    sed -n '1,120p' "$output_file" >&2
    return 1
  fi

  if [[ "$http_status" != 2* ]]; then
    echo "FAIL: proxy returned HTTP $http_status" >&2
    return 1
  fi
}

echo "== 1/2: plain text round-trip =="
post_messages "$TEXT_RESPONSE" "{
  \"model\": \"$MODEL\",
  \"max_tokens\": 64,
  \"messages\": [{\"role\": \"user\", \"content\": \"Reply with exactly: PROXY_OK\"}]
}"

echo
echo "== 2/2: tool-call round-trip (the part that actually matters for the agent) =="
post_messages "$TOOL_RESPONSE" "{
  \"model\": \"$MODEL\",
  \"max_tokens\": 256,
  \"tools\": [{
    \"name\": \"get_weather\",
    \"description\": \"Get the current weather for a city\",
    \"input_schema\": {
      \"type\": \"object\",
      \"properties\": {\"city\": {\"type\": \"string\"}},
      \"required\": [\"city\"]
    }
  }],
  \"messages\": [{\"role\": \"user\", \"content\": \"What is the weather in Buenos Aires? Use the tool.\"}]
}"

echo
if grep -q '"type": *"tool_use"' "$TOOL_RESPONSE"; then
  echo "PASS: proxy returned a valid Anthropic-shaped tool_use block."
else
  echo "FAIL: no tool_use block in the response -- check 'docker compose logs cliproxy' and the model's tool-calling support." >&2
  exit 1
fi
