#!/usr/bin/env bash
# Exposes a running cc-up.sh tmux session over ttyd (writable by default),
# bound to the Tailscale interface only -- reachable from your other
# Tailscale devices (e.g. your phone's browser) but never from the public
# internet.
#
# Usage:
#   ./scripts/cc-remote.sh                 # session "default" on port 7681
#   ./scripts/cc-remote.sh work 7682       # session "work" on port 7682
#
# Requires: tailscale already up on this machine, and the target session
# already started via ./scripts/cc-up.sh <name>.
set -euo pipefail

if ! command -v ttyd >/dev/null 2>&1; then
  echo "FAIL: ttyd is not installed. Install it first: sudo apt install ttyd" >&2
  exit 1
fi
if ! command -v tmux >/dev/null 2>&1; then
  echo "FAIL: tmux is not installed. Install it first: sudo apt install tmux" >&2
  exit 1
fi

SESSION_NAME="${1:-default}"
PORT="${2:-${TTYD_BASE_PORT:-7681}}"
IFACE="${TTYD_IFACE:-tailscale0}"
TMUX_SESSION="cc-${SESSION_NAME}"

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "FAIL: tmux session '$TMUX_SESSION' is not running. Start it first: ./scripts/cc-up.sh $SESSION_NAME" >&2
  exit 1
fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  echo "FAIL: network interface '$IFACE' not found. Is Tailscale up? (tailscale up / tailscale status)." >&2
  echo "      Override the interface with TTYD_IFACE=<iface> if yours is named differently." >&2
  exit 1
fi

TS_IP="$(tailscale ip -4 2>/dev/null || true)"
echo "INFO: serving tmux session '$TMUX_SESSION' (writable) on http://${TS_IP:-<tailscale-ip>}:$PORT" >&2

# ttyd is writable by default (pass -R/--readonly to disable it); there is no
# -W flag on the 1.x line shipped in Ubuntu's repos.
exec ttyd -i "$IFACE" -p "$PORT" tmux attach-session -t "$TMUX_SESSION"
