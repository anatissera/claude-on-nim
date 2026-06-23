FROM node:22-bookworm-slim

# git: credential injection at startup. python3/pip + ruff/mypy: verification
# checkers for Python workspaces. The TS/JS checkers (eslint/tsc) come from
# the target workspace's own node_modules, not this image.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates gosu python3 python3-pip \
    && pip3 install --no-cache-dir --break-system-packages ruff mypy \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev
COPY claude-template ./claude-template

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
