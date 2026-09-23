#!/usr/bin/env bash
# Talks to CLIProxyAPI's Management API so you can inspect and adjust the
# running proxy without restarting it or hand-writing curl.
#
# Requires MANAGEMENT_SECRET_KEY in .env. Without it the proxy returns 404 on
# every management route, which is the default.
#
# The API is bound to localhost: it can rewrite the proxy config and read
# request logs, which hold full prompts and replies. To reach it from another
# device, tunnel it the way scripts/cc-remote.sh does rather than opening it up.
#
# Usage:
#   cpa-admin.sh status              # health, models, key pool, cooldowns
#   cpa-admin.sh usage               # per-key / per-model usage counters
#   cpa-admin.sh models              # aliases the proxy currently serves
#   cpa-admin.sh keys                # NIM keys in the pool (masked)
#   cpa-admin.sh logs [n]            # n most recent request logs (default 10)
#   cpa-admin.sh log <name>          # one request log, credentials masked
#   cpa-admin.sh debug [on|off]      # read or flip upstream debug logging
#   cpa-admin.sh config              # live config as JSON (secrets redacted)
#   cpa-admin.sh raw <METHOD> <path> # escape hatch, e.g. raw GET /v0/management/logs
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
ENV_FILE="${CLIPROXY_ENV_FILE:-$REPO_DIR/.env}"
BASE_URL="${CPA_ADMIN_URL:-http://localhost:8317}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

if [[ -z "${MANAGEMENT_SECRET_KEY:-}" ]]; then
  echo "FAIL: MANAGEMENT_SECRET_KEY is not set in $ENV_FILE." >&2
  echo "      The Management API is opt-in; without it the proxy 404s every" >&2
  echo "      /v0/management route. Generate one with: openssl rand -hex 32" >&2
  echo "      then re-run ./scripts/render-cliproxy-config.sh and restart the proxy." >&2
  exit 1
fi

# Returns the HTTP status on stdout's last line, body above it.
api() {
  local method="$1" path="$2"
  shift 2
  curl -sS --max-time 20 -X "$method" "$BASE_URL$path" \
    -H "Authorization: Bearer $MANAGEMENT_SECRET_KEY" \
    -H "content-type: application/json" \
    -w '\n%{http_code}' "$@"
}

# Runs `api`, prints the body pretty-printed, and fails loudly on a non-2xx.
call() {
  local out status body
  out="$(api "$@")" || { echo "FAIL: could not reach $BASE_URL — is the proxy up? (docker compose ps)" >&2; return 1; }
  status="$(tail -n1 <<<"$out")"
  body="$(sed '$d' <<<"$out")"

  case "$status" in
    2*) ;;
    401|403)
      echo "FAIL: proxy rejected the management key (HTTP $status)." >&2
      echo "      MANAGEMENT_SECRET_KEY in $ENV_FILE must match the rendered config." >&2
      echo "      After changing it: ./scripts/render-cliproxy-config.sh && docker compose restart cliproxy" >&2
      return 1 ;;
    404)
      echo "FAIL: management route not found (HTTP 404)." >&2
      echo "      Most likely the running proxy has no secret-key configured." >&2
      echo "      Re-render and restart so it picks up MANAGEMENT_SECRET_KEY." >&2
      return 1 ;;
    *)
      echo "FAIL: HTTP $status" >&2
      printf '%s\n' "$body" >&2
      return 1 ;;
  esac

  if [[ -n "$body" ]]; then
    python3 -m json.tool <<<"$body" 2>/dev/null || printf '%s\n' "$body"
  fi
}

# Fetches a management endpoint into a temp file and echoes its path, so the
# Python below can read it from argv instead of fighting nested shell quoting.
fetch_json() {
  local path="$1" tmp out status
  tmp="$(mktemp)"
  out="$(api GET "$path")"
  status="$(tail -n1 <<<"$out")"
  # Fail loudly: swallowing a 403 here once made `status` print defaults as if
  # it had read them from the live config.
  if [[ "$status" != 2* ]]; then
    rm -f "$tmp"
    printf '%s\n' "$out" | sed '$d' >&2
    case "$status" in
      401|403) echo "FAIL: management key rejected or remote access refused (HTTP $status)." >&2 ;;
      404)     echo "FAIL: management routes disabled (HTTP 404) -- no secret-key in the running config." >&2 ;;
      *)       echo "FAIL: HTTP $status from $path" >&2 ;;
    esac
    return 1
  fi
  sed '$d' <<<"$out" > "$tmp"
  echo "$tmp"
}

cmd_status() {
  local health tmp
  health="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$BASE_URL/healthz" 2>/dev/null || echo "000")"
  if [[ "$health" == "200" ]]; then
    echo "proxy:   up at $BASE_URL"
  else
    echo "proxy:   NOT RESPONDING at $BASE_URL (healthz -> ${health})" >&2
    return 1
  fi

  tmp="$(fetch_json /v0/management/config)" || return 1
  python3 - "$tmp" <<'PY'
import json, sys

try:
    with open(sys.argv[1]) as handle:
        cfg = json.load(handle)
except Exception:
    print("config:  <unreadable — is MANAGEMENT_SECRET_KEY correct?>")
    raise SystemExit(0)

for provider in cfg.get("openai-compatibility") or []:
    models = provider.get("models") or []
    aliases = sorted({m.get("alias") or m.get("name") for m in models})
    joined = ", ".join(aliases)
    print("provider:", provider.get("name", "?"))
    print("keys:    ", len(provider.get("api-key-entries") or []), "in the pool")
    print("aliases: ", len(aliases), "->", joined)
    rules = provider.get("request-scoped-errors") or []
    if rules:
        print("err rules:", ", ".join(str(r.get("status")) for r in rules))

routing = (cfg.get("routing") or {}).get("strategy", "round-robin")
print("routing: ", routing)
print("req log: ", "on" if cfg.get("request-log") else "off")
print("usage:   ", "on" if cfg.get("usage-statistics-enabled") else "off")
PY
  rm -f "$tmp"
}

cmd_usage()  { call GET /v0/management/usage-queue; }
cmd_config() { call GET /v0/management/config; }

cmd_models() {
  curl -sS --max-time 20 "$BASE_URL/v1/models" \
    -H "Authorization: Bearer ${PROXY_MASTER_KEY:-}" |
    python3 -c 'import json,sys; [print(" ", m["id"]) for m in sorted(json.load(sys.stdin)["data"], key=lambda m: m["id"])]'
}

cmd_keys() {
  local tmp
  tmp="$(fetch_json /v0/management/config)" || return 1
  python3 - "$tmp" <<'PY'
import json, sys

with open(sys.argv[1]) as handle:
    cfg = json.load(handle)

for provider in cfg.get("openai-compatibility") or []:
    print(provider.get("name", "?") + ":")
    entries = provider.get("api-key-entries") or []
    if not entries:
        print("  (none)")
    for index, entry in enumerate(entries, 1):
        key = str(entry.get("api-key", ""))
        masked = key[:8] + "..." + key[-4:] if len(key) > 14 else "<short>"
        weight = entry.get("weight")
        suffix = "  weight=" + str(weight) if weight else ""
        print("  " + str(index) + ". " + masked + suffix)
PY
  rm -f "$tmp"
}

cmd_logs() {
  local limit="${1:-10}"
  local dir="$REPO_DIR/proxy/logs"
  if [[ ! -d "$dir" ]]; then
    echo "no log directory at $dir" >&2
    return 1
  fi
  # Read from disk rather than the API: these are plain files, and going
  # through the API would only add a hop.
  find "$dir" -name '*.log' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | head -n "$limit" |
    while read -r _ path; do
      printf '%s  %s\n' "$(date -d "@$(stat -c %Y "$path")" '+%Y-%m-%d %H:%M:%S')" "$(basename "$path")"
    done
}

cmd_log() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "Usage: cpa-admin.sh log <name>   (see: cpa-admin.sh logs)" >&2; return 1; }
  local path="$REPO_DIR/proxy/logs/$name"
  [[ -f "$path" ]] || { echo "no such log: $name" >&2; return 1; }
  # CPA already redacts credentials; this is belt-and-braces for anything
  # pasted into an issue.
  sed -E 's/(nvapi-|sk-)[A-Za-z0-9_-]{6,}/\1<redacted>/g' "$path"
}

cmd_debug() {
  case "${1:-}" in
    "")     call GET /v0/management/debug ;;
    on)     call PUT /v0/management/debug -d '{"debug":true}' ;;
    off)    call PUT /v0/management/debug -d '{"debug":false}' ;;
    *)      echo "Usage: cpa-admin.sh debug [on|off]" >&2; return 1 ;;
  esac
}

cmd_raw() {
  local method="${1:-}" path="${2:-}"
  [[ -z "$method" || -z "$path" ]] && { echo "Usage: cpa-admin.sh raw <METHOD> <path>" >&2; return 1; }
  shift 2
  call "$method" "$path" "$@"
}

case "${1:-}" in
  status)  shift; cmd_status "$@" ;;
  usage)   shift; cmd_usage "$@" ;;
  models)  shift; cmd_models "$@" ;;
  keys)    shift; cmd_keys "$@" ;;
  logs)    shift; cmd_logs "$@" ;;
  log)     shift; cmd_log "$@" ;;
  debug)   shift; cmd_debug "$@" ;;
  config)  shift; cmd_config "$@" ;;
  raw)     shift; cmd_raw "$@" ;;
  ""|-h|--help|help)
    sed -n '2,23p' "$SCRIPT_PATH" | sed 's/^# \?//'
    ;;
  *)
    echo "Unknown command: $1" >&2
    echo "Try: cpa-admin.sh --help" >&2
    exit 1 ;;
esac
