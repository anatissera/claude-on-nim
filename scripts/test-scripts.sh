#!/usr/bin/env bash
# Tests for the shell scripts in this directory. The TypeScript agent has
# vitest; these cover the parts of the system written in bash, which is where
# the proxy wiring and key handling actually live.
#
# Usage: ./scripts/test-scripts.sh
set -uo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }

assert_eq()       { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "expected to contain '$3'"; fi; }
assert_missing()  { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "expected NOT to contain '$3'"; fi; }

# --- helpers ---------------------------------------------------------------

# Renders the config from a throwaway env file. Echoes the output path.
render_with() {
  local envbody="$1" out dir
  dir="$(mktemp -d "$TMPROOT/render.XXXXXX")"
  printf '%s\n' "$envbody" > "$dir/.env"
  out="$dir/config.yaml"
  CLIPROXY_ENV_FILE="$dir/.env" CLIPROXY_CONFIG_OUT="$out" \
    "$REPO_DIR/scripts/render-cliproxy-config.sh" >"$dir/stdout" 2>"$dir/stderr"
  echo "$?|$out|$dir"
}

# Resolves a model shortcut using the real case block from claude-nim.sh,
# extracted rather than reimplemented so this test follows the script.
resolve_shortcut() {
  local input="$1" block
  block="$(sed -n '/^case "\$MODEL_SHORTCUT" in$/,/^esac$/p' "$REPO_DIR/scripts/claude-nim.sh")"
  if [[ -z "$block" ]]; then
    echo "__NO_CASE_BLOCK__"
    return
  fi
  ( set +u
    MODEL_SHORTCUT="$input"
    set -- "$input"
    eval "$block"
    echo "$MODEL_NAME" )
}

echo "render-cliproxy-config.sh"

# --- validation ------------------------------------------------------------

result="$(render_with 'NVIDIA_NIM_API_KEY=nvapi-replace-me
PROXY_MASTER_KEY=sk-real-key-here')"
assert_eq "rejects the placeholder NIM key" "${result%%|*}" "1"

result="$(render_with 'NVIDIA_NIM_API_KEY=nvapi-real
PROXY_MASTER_KEY=sk-replace-me')"
assert_eq "rejects the placeholder master key" "${result%%|*}" "1"

result="$(render_with 'NVIDIA_NIM_API_KEY=nvapi-real')"
assert_eq "rejects a missing master key" "${result%%|*}" "1"

dir="$(mktemp -d "$TMPROOT/noenv.XXXXXX")"
CLIPROXY_ENV_FILE="$dir/absent.env" CLIPROXY_CONFIG_OUT="$dir/out.yaml" \
  "$REPO_DIR/scripts/render-cliproxy-config.sh" >/dev/null 2>&1
assert_eq "rejects a missing env file" "$?" "1"

# --- single key ------------------------------------------------------------

result="$(render_with 'NVIDIA_NIM_API_KEY=nvapi-key-one
PROXY_MASTER_KEY=sk-master')"
code="${result%%|*}"; rest="${result#*|}"; out="${rest%%|*}"; dir="${rest#*|}"
assert_eq "renders successfully with one key" "$code" "0"
body="$(cat "$out" 2>/dev/null)"
assert_contains "substitutes the NIM key" "$body" 'api-key: "nvapi-key-one"'
assert_contains "substitutes the master key" "$body" '- "sk-master"'
assert_missing  "leaves no unsubstituted placeholder" "$body" '${'
assert_eq "writes the file 0600" "$(stat -c '%a' "$out")" "600"
assert_contains "hints at adding a second key" "$(cat "$dir/stderr")" "NVIDIA_NIM_API_KEY_2"

# --- multiple keys ---------------------------------------------------------

result="$(render_with 'NVIDIA_NIM_API_KEY=nvapi-one
NVIDIA_NIM_API_KEY_2=nvapi-two
NVIDIA_NIM_API_KEY_3=nvapi-three
PROXY_MASTER_KEY=sk-master')"
rest="${result#*|}"; out="${rest%%|*}"; dir="${rest#*|}"
body="$(cat "$out")"
assert_eq "expands all three keys" "$(grep -c 'api-key: "nvapi-' <<<"$body")" "3"
assert_contains "keeps key order" "$(grep 'api-key: "nvapi-' <<<"$body" | head -1)" "nvapi-one"
assert_contains "reports the pool size" "$(cat "$dir/stderr")" "3 NIM keys"

result="$(render_with 'NVIDIA_NIM_API_KEY=nvapi-one
NVIDIA_NIM_API_KEY_3=nvapi-three
PROXY_MASTER_KEY=sk-master')"
rest="${result#*|}"; out="${rest%%|*}"
assert_eq "stops at a numbering gap rather than skipping it" \
  "$(grep -c 'api-key: "nvapi-' "$out")" "1"

result="$(render_with 'NVIDIA_NIM_API_KEY=nvapi-one
NVIDIA_NIM_API_KEY_2=nvapi-replace-me
PROXY_MASTER_KEY=sk-master')"
rest="${result#*|}"; out="${rest%%|*}"
assert_eq "ignores a placeholder left in an extra key slot" \
  "$(grep -c 'api-key: "nvapi-' "$out")" "1"

# --- rendered output is usable --------------------------------------------

result="$(render_with 'NVIDIA_NIM_API_KEY=nvapi-one
PROXY_MASTER_KEY=sk-master')"
rest="${result#*|}"; out="${rest%%|*}"
if python3 -c "
import sys, yaml
cfg = yaml.safe_load(open('$out'))
assert cfg['port'] == 8317, cfg.get('port')
assert cfg['api-keys'] == ['sk-master'], cfg.get('api-keys')
compat = cfg['openai-compatibility'][0]
assert compat['base-url'].startswith('https://integrate.api.nvidia.com'), compat['base-url']
assert compat['api-key-entries'][0]['api-key'] == 'nvapi-one'
assert cfg['request-log'] is True
aliases = {m['alias'] for m in compat['models']}
for required in ('claude-sonnet-4-6', 'claude-opus-4-8', 'claude-haiku-4-5', 'glm', 'kimi'):
    assert required in aliases, required
statuses = [r['status'] for r in compat['request-scoped-errors']]
assert 410 in statuses and 404 in statuses, statuses
" 2>"$TMPROOT/yamlerr"; then
  ok "rendered config parses as YAML with the expected shape"
else
  bad "rendered config parses as YAML with the expected shape" "$(head -3 "$TMPROOT/yamlerr")"
fi

# The template must not carry a real-looking key, since it is committed.
tpl="$(cat "$REPO_DIR/proxy/cliproxy-config.yaml.template")"
if grep -qE 'api-key: *"nvapi-[A-Za-z0-9_-]{12,}"' <<<"$tpl"; then
  bad "committed template holds no real key"
else
  ok "committed template holds no real key"
fi

# --- management API wiring ---------------------------------------------------

result="$(render_with 'NVIDIA_NIM_API_KEY=nvapi-one
PROXY_MASTER_KEY=sk-master
MANAGEMENT_SECRET_KEY=mgmt-secret-value')"
rest="${result#*|}"; out="${rest%%|*}"; dir="${rest#*|}"
assert_contains "substitutes the management secret" "$(cat "$out")" 'secret-key: "mgmt-secret-value"'
assert_contains "reports the API as enabled" "$(cat "$dir/stderr")" "Management API enabled"

result="$(render_with 'NVIDIA_NIM_API_KEY=nvapi-one
PROXY_MASTER_KEY=sk-master')"
rest="${result#*|}"; out="${rest%%|*}"; dir="${rest#*|}"
assert_contains "leaves the secret empty when unset" "$(cat "$out")" 'secret-key: ""'
assert_contains "reports the API as disabled" "$(cat "$dir/stderr")" "Management API disabled"

result="$(render_with 'NVIDIA_NIM_API_KEY=nvapi-one
PROXY_MASTER_KEY=sk-master
MANAGEMENT_SECRET_KEY=mgmt-secret')"
rest="${result#*|}"; out="${rest%%|*}"
if python3 -c "
import yaml
cfg = yaml.safe_load(open('$out'))
rm = cfg['remote-management']
assert rm['secret-key'] == 'mgmt-secret', rm['secret-key']
assert rm['allow-remote'] is True, rm['allow-remote']
assert rm['disable-control-panel'] is True, rm['disable-control-panel']
assert cfg['usage-statistics-enabled'] is True
" 2>/dev/null; then
  ok "management block renders with the expected shape"
else
  bad "management block renders with the expected shape"
fi

# Security invariant: the proxy holds the NIM key and, with allow-remote true,
# serves an API that can rewrite its own config. The loopback bind is what
# keeps both off the network, so it must not quietly become 0.0.0.0 again.
compose="$(cat "$REPO_DIR/docker-compose.yml")"
if grep -qE '^\s*-\s*"127\.0\.0\.1:8317:8317"' <<<"$compose"; then
  ok "proxy port is published on loopback only"
else
  bad "proxy port is published on loopback only" "found: $(grep -E '8317:8317' <<<"$compose" | tr -d ' ')"
fi
if grep -qE '^\s*-\s*"8317:8317"' <<<"$compose"; then
  bad "no bare 0.0.0.0 port publish remains"
else
  ok "no bare 0.0.0.0 port publish remains"
fi

echo
echo "cpa-admin.sh"

admindir="$(mktemp -d "$TMPROOT/admin.XXXXXX")"
printf 'PROXY_MASTER_KEY=sk-master\n' > "$admindir/.env"
adminout="$(CLIPROXY_ENV_FILE="$admindir/.env" "$REPO_DIR/scripts/cpa-admin.sh" status 2>&1)"
admincode=$?
assert_eq "refuses to run without a management secret" "$admincode" "1"
assert_contains "explains how to enable the API" "$adminout" "MANAGEMENT_SECRET_KEY"
assert_contains "names the command to generate one" "$adminout" "openssl rand"

printf 'PROXY_MASTER_KEY=sk-master\nMANAGEMENT_SECRET_KEY=irrelevant\n' > "$admindir/.env"
adminout="$(CLIPROXY_ENV_FILE="$admindir/.env" CPA_ADMIN_URL="http://127.0.0.1:1" \
  "$REPO_DIR/scripts/cpa-admin.sh" status 2>&1)"
assert_contains "reports an unreachable proxy rather than hanging" "$adminout" "NOT RESPONDING"

adminout="$(CLIPROXY_ENV_FILE="$admindir/.env" "$REPO_DIR/scripts/cpa-admin.sh" nonsense 2>&1)"
assert_contains "rejects an unknown subcommand" "$adminout" "Unknown command"

adminout="$(CLIPROXY_ENV_FILE="$admindir/.env" "$REPO_DIR/scripts/cpa-admin.sh" --help 2>&1)"
assert_contains "prints usage for --help" "$adminout" "cpa-admin.sh status"

echo
echo "claude-nim.sh model shortcuts"

assert_eq "sonnet -> glm"          "$(resolve_shortcut sonnet)"    "glm"
assert_eq "glm -> glm"             "$(resolve_shortcut glm)"       "glm"
assert_eq "opus -> kimi"           "$(resolve_shortcut opus)"      "kimi"
assert_eq "kimi -> kimi"           "$(resolve_shortcut kimi)"      "kimi"
assert_eq "haiku -> glm-flash"     "$(resolve_shortcut haiku)"     "glm-flash"
assert_eq "glm-flash -> glm-flash" "$(resolve_shortcut glm-flash)" "glm-flash"
assert_eq "deepseek passes through" "$(resolve_shortcut deepseek)" "deepseek"
assert_eq "gpt-oss passes through"  "$(resolve_shortcut gpt-oss)"  "gpt-oss"
assert_eq "an unknown word is treated as a raw alias" \
  "$(resolve_shortcut some-new-alias)" "some-new-alias"
assert_eq "a claude flag is not consumed as a model" "$(resolve_shortcut -- --continue)" ""
assert_eq "no argument means no model override" "$(resolve_shortcut '')" ""

# The tier words must agree with the aliases the headless agent uses, or an
# interactive session and the agent silently land on different models.
tier_upstream() {
  python3 - "$1" <<'PY'
import re, sys
alias = sys.argv[1]
text = open('proxy/cliproxy-config.yaml.template').read()
# Match the "- name: X\n  alias: Y" pairs without needing the placeholders resolved.
pairs = re.findall(r'-\s*name:\s*"([^"]+)"\s*\n\s*alias:\s*"([^"]+)"', text)
print(next((n for n, a in pairs if a == alias), ""))
PY
}
cd "$REPO_DIR"
for pair in "sonnet:claude-sonnet-4-6" "opus:claude-opus-4-8" "haiku:claude-haiku-4-5"; do
  word="${pair%%:*}"; tier="${pair#*:}"
  short_alias="$(resolve_shortcut "$word")"
  a="$(tier_upstream "$short_alias")"
  b="$(tier_upstream "$tier")"
  if [[ -n "$a" && "$a" == "$b" ]]; then
    ok "$word and $tier resolve to the same upstream ($a)"
  else
    bad "$word and $tier resolve to the same upstream" "got '$a' vs '$b'"
  fi
done

echo
echo "validate-proxy.sh target resolution"

resolve_target() {
  ( set +u
    unset PROXY_URL
    ANTHROPIC_BASE_URL="$1"
    [[ -n "${2:-}" ]] && PROXY_URL="$2"
    block="$(sed -n '/^# ANTHROPIC_BASE_URL is written for the agent container/,/^fi$/p' \
      "$REPO_DIR/scripts/validate-proxy.sh")"
    eval "$block" 2>/dev/null
    echo "$PROXY_URL" )
}

assert_eq "a compose service name maps to the published port" \
  "$(resolve_target 'http://cliproxy:8317')" "http://localhost:8317"
assert_eq "the removed litellm service name also maps cleanly" \
  "$(resolve_target 'http://proxy:4000')" "http://localhost:8317"
assert_eq "an unset base URL defaults to the published port" \
  "$(resolve_target '')" "http://localhost:8317"
assert_eq "a loopback base URL is kept as-is" \
  "$(resolve_target 'http://localhost:8317')" "http://localhost:8317"
assert_eq "127.0.0.1 is kept as-is" \
  "$(resolve_target 'http://127.0.0.1:9999')" "http://127.0.0.1:9999"
assert_eq "an explicit PROXY_URL wins over everything" \
  "$(resolve_target 'http://cliproxy:8317' 'http://elsewhere:1234')" "http://elsewhere:1234"

echo
echo "script hygiene"
for f in "$REPO_DIR"/scripts/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "$(basename "$f") parses"; else bad "$(basename "$f") parses"; fi
done
for f in "$REPO_DIR"/scripts/*.sh; do
  if [[ -x "$f" ]]; then ok "$(basename "$f") is executable"; else bad "$(basename "$f") is executable"; fi
done

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
