# NIM Self-Verifying Agent

An experimental implementation of an autonomous AI agent powered by the Claude Agent SDK, running inference on NVIDIA's free NIM endpoints instead of Anthropic, with automated code verification (linting, type-checking, testing) wired into the agent's execution loop.

## Interactive use: persistent sessions with tmux + ttyd + model switching

The three-part solution replaces the single-session CLI with persistent, remotely-controllable, multi-model workflows:

### 1. Global commands (any directory)

First-time setup:
```bash
cd /path/to/nim-self-verifying-agent
./scripts/install.sh    # symlinks cc-up, cc-remote, cc-switch into ~/.local/bin
```

Then from any directory:
```bash
cc-up demo glm                  # start persistent session "demo" on glm-5.1
cc-remote demo                  # expose that session over ttyd on Tailscale (same terminal, attach to the ttyd URL from your phone/laptop)
cc-switch demo kimi             # (in another terminal) switch that session to kimi without losing context
```

### 2. Slash commands (inside a running `cc-up` session)

Once you have a Claude session running (via `cc-up`), use these slash commands *within that session itself* (not needing a separate terminal):

- **`/cc-switch kimi`** — Write your handoff summary naturally as your response, then this command relaunches your pane on the new model with `--continue` (full transcript replay). The switch happens ~1 second after you run it.
- **`/cc-remote [port]`** — Expose this session over ttyd on Tailscale in the background. The pane stays open, you get the URL to open on another device.

### 3. Model shortcuts

All available on NIM (`proxy/litellm-config.yaml`):

| Shortcut            | NIM model                  |
| -------------------- | --------------------------- |
| `glm`                | `z-ai/glm-5.1`              |
| `deepseek`           | `deepseek-ai/deepseek-v4-pro` |
| `kimi`               | `moonshotai/kimi-k2.6`      |
| `gpt-oss`            | `openai/gpt-oss-120b`       |

Or pass any raw `litellm` model name: `cc-up work my-custom-endpoint-alias`.

### What's different from the old single-session CLI

| Old (`claude-nim.sh`) | New (`cc-up` + `/cc-switch`) |
|---|---|
| Exits on disconnect → lose conversation | Persists in tmux → survives SSH drops, terminal closes |
| To switch models: exit + relaunch (context replayed) | Switch models mid-conversation with `/cc-switch`, context preserved |
| Only you can see/control the session | `/cc-remote` exposes it over Tailscale → control from phone/laptop |

## Overview

This project explores:

- **Endpoint redirection:** Using `ANTHROPIC_BASE_URL` plus a protocol-translation proxy to route Claude Agent SDK requests to NVIDIA NIM (OpenAI-compatible endpoints).
- **Self-verifying execution:** A `PostToolUse` hook that runs linters, type checkers, and test suites on generated code and feeds failures back into the agent loop for self-correction.
- **Containerized autonomy:** The entire agent runs in Docker with Git credentials injected at startup, enabling true autonomous commits and pushes (within guardrails).

## Key design decisions

1. **No SDK fork.** The endpoint is swapped via environment variables; verification is injected via hooks. Both are sanctioned, supported extensions.
2. **Translation proxy required.** The Claude Agent SDK speaks the Anthropic Messages API; NVIDIA NIM speaks OpenAI. A proxy (LiteLLM or custom) translates between them.
3. **Hooks enforce verification deterministically.** Unlike system prompts (advisory), `PostToolUse` hooks guarantee that code is linted/typed/tested before the model sees it.

## Agent hardening (safety guardrails)

The headless agent runs in a Docker container with git credentials and can execute arbitrary Bash commands. Three layers prevent misuse:

1. **Denylist (PreToolUse hook)** — Blocks destructive Bash commands at execution time:
   - Credential theft: `cat ~/.ssh/id_rsa`, `.aws/credentials`, `/etc/shadow`
   - Filesystem destruction: `rm -rf /`, `mkfs`, `dd of=/dev`, fork bombs
   - SCM sabotage: `git push --force`, `git reset --hard`
   - Code injection: `curl | bash`
   
   Failures feed back to the agent as permission denials, not silent blocks.

2. **Path confinement (PreToolUse hook)** — Write/Edit/MultiEdit/NotebookEdit tools can only write to files inside the project root (`AGENT_CWD`). Prevents escaping `/workspace` to clobber system files or credentials.

3. **Proxy preflight (startup check)** — If the NIM proxy is unreachable, the agent fails loudly with a clear error message instead of hanging or timing out opaquely.

All hooks are deterministic (no AI-in-the-loop decisions) and fire regardless of `permissionMode` setting, making them the true backstop for an agent that otherwise has `bypassPermissions` + git credentials.

## Repo layout

```
agent/        Claude Agent SDK driver, hooks, verification runners (TypeScript)
proxy/        LiteLLM config that translates Anthropic <-> NVIDIA NIM (OpenAI)
scripts/      validate-proxy.sh, smoke-tests the proxy before wiring up the agent
workspace/    mounted target repo the agent edits (gitignored, empty by default)
docker-compose.yml   proxy + agent services
```

## Quick start

1. **Get a free NVIDIA NIM API key** at [build.nvidia.com](https://build.nvidia.com) (no credit card).
2. Copy `.env.example` to `.env` and fill in `NVIDIA_NIM_API_KEY`, `PROXY_MASTER_KEY` (any random string), and `GITHUB_TOKEN` (scoped to one repo) if you want the agent to push.
3. **Validate the proxy first** (PRD Step 1: nothing else works until this passes):
   ```bash
   docker compose up -d proxy
   set -a; source .env; set +a
   ./scripts/validate-proxy.sh
   ```
   This confirms the proxy returns Anthropic-shaped responses, including a real `tool_use` block that the Agent SDK actually depends on.
4. **Run the agent against a workspace** (PRD Step 2: minimal SDK run):
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
