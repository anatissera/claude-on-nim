#!/usr/bin/env bash
set -euo pipefail

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Create a non-root user matching the host UID/GID so files written into the
# mounted /workspace volume aren't root-owned on the host.
if ! getent group "$HOST_GID" >/dev/null; then
  groupadd -g "$HOST_GID" agent
fi
if ! getent passwd "$HOST_UID" >/dev/null; then
  useradd -m -u "$HOST_UID" -g "$HOST_GID" -s /bin/bash agent
fi
AGENT_HOME="$(getent passwd "$HOST_UID" | cut -d: -f6)"
export HOME="$AGENT_HOME"

# Git identity + credential injection. Token comes from the environment
# (never baked into the image) and is written with 0600 perms via the
# credential store helper, scoped to this container's filesystem only.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  gosu "$HOST_UID:$HOST_GID" git config --global user.name "${GIT_USER_NAME:-nim-self-verifying-agent}"
  gosu "$HOST_UID:$HOST_GID" git config --global user.email "${GIT_USER_EMAIL:-agent@example.invalid}"
  gosu "$HOST_UID:$HOST_GID" git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "$GITHUB_TOKEN" > "$AGENT_HOME/.git-credentials"
  chown "$HOST_UID:$HOST_GID" "$AGENT_HOME/.git-credentials"
  chmod 600 "$AGENT_HOME/.git-credentials"
fi

# Seed the mounted workspace with default verification instructions unless
# it already has its own .claude/ config (never clobber an existing target repo).
if [ -d /workspace ] && [ ! -d /workspace/.claude ]; then
  cp -r /app/claude-template /workspace/.claude
fi

cd /workspace
exec gosu "$HOST_UID:$HOST_GID" node /app/dist/main.js "$@"
