#!/usr/bin/env bash
# Step 1 of the implementation plan (PRD.md): validate the LiteLLM -> NVIDIA
# NIM proxy speaks the Anthropic Messages protocol correctly *before* wiring
# up the Agent SDK. Run this against a running `docker compose up proxy`.
set -euo pipefail

PROXY_URL="${ANTHROPIC_BASE_URL:-http://localhost:4000}"
AUTH_TOKEN="${PROXY_MASTER_KEY:?Set PROXY_MASTER_KEY (matches docker-compose's proxy master key)}"
MODEL="${1:-claude-sonnet-4-6}"

echo "== 1/2: plain text round-trip =="
curl -sS "$PROXY_URL/v1/messages" \
  -H "x-api-key: $AUTH_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "{
    \"model\": \"$MODEL\",
    \"max_tokens\": 64,
    \"messages\": [{\"role\": \"user\", \"content\": \"Reply with exactly: PROXY_OK\"}]
  }" | tee /tmp/proxy-text-response.json | python3 -m json.tool

echo
echo "== 2/2: tool-call round-trip (the part that actually matters for the agent) =="
curl -sS "$PROXY_URL/v1/messages" \
  -H "x-api-key: $AUTH_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "{
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
  }" | tee /tmp/proxy-tool-response.json | python3 -m json.tool

echo
if grep -q '"type": *"tool_use"' /tmp/proxy-tool-response.json; then
  echo "PASS: proxy returned a valid Anthropic-shaped tool_use block."
else
  echo "FAIL: no tool_use block in the response — check litellm logs and the model's tool-calling support." >&2
  exit 1
fi
