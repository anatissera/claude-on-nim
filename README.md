# Claude on NIM

Interactive Claude CLI with flexible inference backends: Anthropic or NVIDIA's free NIM endpoints.
Persistent tmux sessions (survive disconnects), mid-conversation model switching, and remote control
via Tailscale. Includes optional autonomous agent mode with code verification for unattended tasks.

## What you can do with this

**Interactive Claude with NIM models:**
```bash
cd /path/to/your-random-repo
claude-nim                      # fresh session, default model (glm-5.1)
claude-nim gpt-oss              # fresh session on gpt-oss-120b
claude-nim kimi --continue      # continue last conversation, switch to kimi
```

**Inside the session, use slash commands:**
```
/cc-switch kimi                 # switch to a different model mid-conversation
/cc-remote                      # expose this session to your phone/laptop over Tailscale
```

**Optional: manual session management (multiple named sessions):**
```bash
cc-up work glm                  # start named session "work"
cc-switch work kimi             # switch that session to kimi
cc-remote work                  # expose that session to Tailscale
```

**Autonomous agent mode (Docker):**
```bash
docker compose run --rm agent "your task here"
```

That's it. Keep reading to set it up.

## Quick start: interactive Claude on NIM

### Prerequisites
- Free NVIDIA NIM API key at [build.nvidia.com](https://build.nvidia.com) (no credit card)
- `tmux` and `ttyd` installed: `sudo apt install -y tmux ttyd`

### Setup (one-time)
```bash
cd /path/to/claude-on-nim
cp .env.example .env
# Fill in NVIDIA_NIM_API_KEY and PROXY_MASTER_KEY (any random string) in .env
./scripts/install.sh            # symlinks commands into ~/.local/bin
```

After this, `claude-nim` works from anywhere.

## How it works

`claude-nim` is just `claude` CLI but with flexible backends (Anthropic or NIM). It auto-wraps your session in tmux so it stays open when you close the terminal. You can switch models and expose to other devices without leaving the session.

**What you get:**
- All your skills, MCPs, settings, `.claude/CLAUDE.md` (uses your cwd, not the repo's)
- Persistent: survives SSH disconnect, terminal close, etc.
- Switch models mid-conversation with `/cc-switch <model>`
- Expose to phone/laptop with `/cc-remote`

## Slash commands (inside a `claude-nim` session)

### `/cc-switch <model>`
Switch to a different model mid-conversation without losing context.

```
# You're on glm, the conversation is going well...
/cc-switch kimi
# Write a brief handoff summary as your response
# Then this command relaunches your session on kimi with --continue
# (full transcript replayed, handoff summary included)
```

Supported models: `glm`, `deepseek`, `kimi`, `gpt-oss`, or any raw `litellm` model name.

### `/cc-remote [port]`
Expose this running session over ttyd on Tailscale, so you can control it from another device.

```
/cc-remote
# Output: "INFO: exposing this session on http://100.114.145.73:7681"
# Open that URL in your phone's browser to control the session
```

## Advanced: manual session management

If you want to manage multiple named, persistent sessions:

```bash
# Start a named session
cc-up work glm                          # persistent session "work" on glm-5.1

# In another terminal, switch its model
cc-switch work kimi                     # asks work session for handoff, relaunches on kimi

# In another terminal, expose it
cc-remote work                          # expose "work" session to Tailscale

# Or multiple sessions on different ports
cc-remote work 7682
cc-remote personal 7683
```

## Autonomous agent: Docker headless mode

For unattended tasks, the Docker container runs an autonomous agent with verified code execution and Git credentials.

### Setup

1. **Get prerequisites:** NVIDIA NIM API key, `docker compose`
2. **Config:** Copy `.env.example` to `.env` and fill in `NVIDIA_NIM_API_KEY`, `PROXY_MASTER_KEY`, and `GITHUB_TOKEN` (optional)
3. **Validate the proxy first:**
   ```bash
   docker compose up -d proxy
   set -a; source .env; set +a
   ./scripts/validate-proxy.sh
   ```
   This confirms the proxy translates Anthropic to NIM correctly.

4. **Run the agent:**
   ```bash
   cp -r /path/to/your/repo/* workspace/
   docker compose run --rm agent "List files and explain what this repo does"
   ```

### How it works

The agent runs the Claude Agent SDK in a container and:
- Routes inference through the LiteLLM proxy onto NIM instead of Anthropic
- Has a `PostToolUse` hook that runs linters, type-checkers, tests on generated code
- Reports failures back to the model loop so it can self-correct
- Has Git credentials injected, can commit and push within guardrails (see Agent hardening below)

### Local development (non-Docker)

```bash
cd agent
npm install
npm run build
ANTHROPIC_BASE_URL=http://localhost:4000 \
ANTHROPIC_AUTH_TOKEN=$PROXY_MASTER_KEY \
AGENT_CWD=$(pwd)/../workspace \
node dist/main.js "your prompt here"
```

Run `npm run lint && npm run typecheck && npm test` before committing.

## Architecture

### Endpoint redirection
The Claude Agent SDK speaks the Anthropic Messages API. NVIDIA NIM speaks OpenAI-compatible endpoints. A proxy (LiteLLM) translates between them. We route via `ANTHROPIC_BASE_URL` environment variable, no SDK fork needed.

### Self-verifying execution
A `PostToolUse` hook runs linters, type-checkers, and test suites on generated code and feeds failures back into the agent loop for self-correction. Unlike system prompts, hooks are deterministic and always fire.

### Containerized autonomy
The agent runs in Docker with Git credentials, enabling true autonomous commits and pushes. Safety guardrails (denylist and path confinement) prevent misuse.

## Agent hardening (safety guardrails)

The headless agent runs with Git credentials in a container and can execute arbitrary Bash. Three layers prevent misuse:

1. **Denylist (PreToolUse hook)** - Blocks destructive Bash at execution:
   - Credential theft: `cat ~/.ssh/id_rsa`, `.aws/credentials`, `/etc/shadow`
   - Filesystem destruction: `rm -rf /`, `mkfs`, `dd of=/dev`, fork bombs
   - SCM sabotage: `git push --force`, `git reset --hard`, `git clean -f`
   - Code injection: `curl | bash`

2. **Path confinement (PreToolUse hook)** - Write/Edit/MultiEdit/NotebookEdit tools can only write inside the project root. Prevents escaping `/workspace`.

3. **Proxy preflight (startup check)** - If NIM is unreachable, agent fails loudly instead of hanging.

All hooks are deterministic and fire regardless of permission mode, making them the true backstop.

## Repo layout

```
agent/              Claude Agent SDK driver, hooks, verification (TypeScript)
proxy/              LiteLLM config that translates Anthropic to NIM (OpenAI)
scripts/            claude-nim.sh, cc-up, cc-remote, cc-switch, validate-proxy.sh
workspace/          mounted target repo the agent edits (empty, gitignored)
docker-compose.yml  proxy + agent services
```

## References

[Claude Agent SDK docs](https://code.claude.com/docs/en/agent-sdk/)
[NVIDIA NIM API](https://docs.nvidia.com/nim/large-language-models/latest/api-reference.html)
[LiteLLM](https://github.com/BerriAI/litellm)
