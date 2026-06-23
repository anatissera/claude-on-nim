# NIM Self-Verifying Agent

An experimental implementation of an autonomous AI agent powered by the Claude Agent SDK, running inference on NVIDIA's free NIM endpoints instead of Anthropic, with automated code verification (linting, type-checking, testing) wired into the agent's execution loop.

## Overview

This project explores:

- **Endpoint redirection:** Using `ANTHROPIC_BASE_URL` + a protocol-translation proxy to route Claude Agent SDK requests to NVIDIA NIM (OpenAI-compatible endpoints).
- **Self-verifying execution:** A `PostToolUse` hook that runs linters, type checkers, and test suites on generated code and feeds failures back into the agent loop for self-correction.
- **Containerized autonomy:** The entire agent runs in Docker with Git credentials injected at startup, enabling true autonomous commits and pushes (within guardrails).

## Key design decisions

1. **No SDK fork.** The endpoint is swapped via environment variables; verification is injected via hooks — both are sanctioned, supported extensions.
2. **Translation proxy required.** The Claude Agent SDK speaks the Anthropic Messages API; NVIDIA NIM speaks OpenAI. A proxy (LiteLLM or custom) translates between them.
3. **Hooks enforce verification deterministically.** Unlike system prompts (advisory), `PostToolUse` hooks guarantee that code is linted/typed/tested before the model sees it.

## Project status

🚧 **Implementation in progress.** See [`PRD.md`](PRD.md) for detailed findings, architecture, and implementation roadmap. The agent driver, verification hooks, and Docker setup below exist; end-to-end validation against a real NVIDIA NIM key has not been run yet (see Step 1 below — this is the first thing to do with real credentials).

## Repo layout

```
agent/        Claude Agent SDK driver, hooks, verification runners (TypeScript)
proxy/        LiteLLM config that translates Anthropic <-> NVIDIA NIM (OpenAI)
scripts/      validate-proxy.sh — smoke-tests the proxy before wiring up the agent
workspace/    mounted target repo the agent edits (gitignored, empty by default)
docker-compose.yml   proxy + agent services
```

## Quick start

1. **Get a free NVIDIA NIM API key** at [build.nvidia.com](https://build.nvidia.com) (no credit card).
2. Copy `.env.example` to `.env` and fill in `NVIDIA_NIM_API_KEY`, `PROXY_MASTER_KEY` (any random string), and `GITHUB_TOKEN` (scoped to one repo) if you want the agent to push.
3. **Validate the proxy first** (PRD Step 1 — nothing else works until this passes):
   ```bash
   docker compose up -d proxy
   set -a; source .env; set +a
   ./scripts/validate-proxy.sh
   ```
   This confirms the proxy returns Anthropic-shaped responses, including a real `tool_use` block — the part the Agent SDK actually depends on.
4. **Run the agent against a workspace** (PRD Step 2 — minimal SDK run):
   ```bash
   cp -r /path/to/your/repo/* workspace/
   docker compose run --rm agent "List the files in this repo and summarize what it does"
   ```
5. Iterate per the PRD's order of implementation: prove tool-calling works on your chosen NIM model, then deliberately break a file to confirm the verification hook reports the failure back to the model, then move to a real edit/commit/push task.

### Local (non-Docker) development

```bash
cd agent
npm install
npm run build
ANTHROPIC_BASE_URL=http://localhost:4000 \
ANTHROPIC_AUTH_TOKEN=$PROXY_MASTER_KEY \
AGENT_CWD=$(pwd)/../workspace \
node dist/main.js "your prompt here"
```

Run `npm run lint && npm run typecheck && npm test` inside `agent/` before committing changes to the driver itself.

## References

- [Claude Agent SDK docs](https://code.claude.com/docs/en/agent-sdk/)
- [NVIDIA NIM API](https://docs.nvidia.com/nim/large-language-models/latest/api-reference.html)
- [LiteLLM](https://github.com/BerriAI/litellm)
