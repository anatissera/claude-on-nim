# PRD: Self-Verifying Agent on NVIDIA NIM via the Claude Agent SDK

> Research-first design document. **No production code in this repo yet** — this file
> defines what we will build and the order to build it.
>
> Goal: replicate a setup where (1) the Claude Agent SDK routes inference to NVIDIA's
> free model endpoints instead of Anthropic, (2) every chunk of generated code is
> automatically linted / type-checked / tested inside the agent loop, and (3) the whole
> thing runs in an isolated Docker container with Git credentials injected at startup.

---

## Research findings

### 1. The Claude Agent SDK — architecture

The product formerly called the "Claude Code SDK" is now the **Claude Agent SDK**, shipped as:

- TypeScript: `npm install @anthropic-ai/claude-agent-sdk`
- Python: `pip install claude-agent-sdk` (3.10+)

Key architectural facts (from the official docs):

- **The TypeScript SDK bundles a native Claude Code binary** for the host platform as an
  optional dependency. The library you import is a thin wrapper that **spawns / drives
  that binary as a subprocess**; it does not re-implement the agent loop in JS. This
  matters enormously for "where do I change the endpoint" (see below).
- The entry point is `query({ prompt, options })`, an **async generator** that yields a
  stream of typed messages (`system`/`init`, `assistant`, `result`, etc.). There is also
  a stateful `ClaudeSDKClient` (Python) / streaming-input form for multi-turn sessions.
- **The agent loop (model call → tool_use → tool execution → tool_result → repeat) runs
  inside the binary**, not in your code. The SDK gives you built-in tools out of the box:
  `Read`, `Write`, `Edit`, `Bash`, `Glob`, `Grep`, `WebSearch`, `WebFetch`, `Agent`
  (subagents), `Monitor`, `AskUserQuestion`.
- This is the explicit contrast with the **Client SDK** (`@anthropic-ai/sdk`): with the
  Client SDK *you* write `while (stop_reason === "tool_use") {...}`; with the Agent SDK
  the loop is handled for you.
- `ClaudeAgentOptions` (TS: the `options` object) exposes, among others: `model`,
  `allowedTools`, `permissionMode` (`default` / `acceptEdits` / `bypassPermissions` /
  `plan`), `hooks`, `mcpServers`, `agents` (subagent definitions), `settingSources`
  (`user` / `project` / `local`), `resume` (session id), `env`, `cwd`, `maxTurns`,
  `systemPrompt`.
- Filesystem config is honored just like the CLI: `.claude/` in cwd and `~/.claude/`
  (skills, slash commands, `CLAUDE.md`, `settings.json`). `settingSources` controls
  which of those load.

### 2. Where the model endpoint is configured — the critical finding

The SDK (and the bundled binary) **honor the same environment variables as Claude Code**:

| Variable | Effect |
| --- | --- |
| `ANTHROPIC_BASE_URL` | Root URL for every API call instead of `https://api.anthropic.com`. |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token sent on requests (use instead of, or with, `ANTHROPIC_API_KEY`). |
| `ANTHROPIC_API_KEY` | Standard API key auth. |
| `ANTHROPIC_MODEL` / `options.model` | Model string passed through to the endpoint. |
| `CLAUDE_CODE_USE_BEDROCK / _VERTEX / _FOUNDRY` | First-party alternate providers. |

Crucial nuance: **`ANTHROPIC_BASE_URL` only changes the host. It does NOT change the
wire protocol.** The SDK still sends **Anthropic Messages API** requests:
`POST /v1/messages` (plus `POST /v1/messages/count_tokens`), with `anthropic-version`
and `anthropic-beta` headers, and the Anthropic content-block / tool-use JSON shape.
The variable is read **once at process start** and never re-checked.

➡️ **Therefore: you can point the SDK at any server, but that server must speak the
Anthropic Messages protocol.** This is the single most important design constraint in
this whole project.

### 3. NVIDIA `build.nvidia.com` / NIM — what the API actually is

- NVIDIA NIM exposes an **OpenAI-compatible** REST API.
  - Base URL: `https://integrate.api.nvidia.com/v1`
  - Endpoint: `POST /v1/chat/completions` (the OpenAI shape — `messages`, `tools`,
    `tool_calls`), **not** `/v1/messages`.
  - Auth: `Authorization: Bearer nvapi-...`. Key is created free at `build.nvidia.com`
    (NVIDIA Developer Program, no credit card).
  - Model string format: `vendor/model`, e.g. `deepseek-ai/deepseek-v3.2`,
    `moonshotai/kimi-k2.5`, `zai/glm-...`, `openai/gpt-oss-...`,
    `meta/llama-3.3-70b-instruct`. The exact catalog is at `build.nvidia.com/models`.
- **Free tier limits (as of 2026):** ~**40 requests/minute**, a starting pool of ~**1,000
  inference credits** (requestable up to ~5,000), credits consumed per request scaled by
  model size. Limits are **not officially raisable** via forum request and vary per model;
  the real ceiling is visible in the build.nvidia.com UI.
- **Tool/function calling support varies by model.** NIM forwards OpenAI-style `tools` /
  `tool_calls`, but not every open model is reliably good at it. The Agent SDK is
  *entirely* dependent on high-quality tool calling (Read/Edit/Bash are tools), so model
  choice is a correctness issue, not a preference. DeepSeek-V3/R1, Kimi-K2, GLM and
  GPT-OSS variants advertise function calling; quality and JSON-schema adherence differ.

➡️ **Flag (per the task's instruction): the NVIDIA endpoint is OpenAI-compatible, NOT
Anthropic-compatible.** A naive `ANTHROPIC_BASE_URL=https://integrate.api.nvidia.com/v1`
will fail — the SDK will `POST /v1/messages` with Anthropic-shaped bodies that NIM does
not understand. **A protocol-translation layer is mandatory.**

### 4. The translation layer — how to bridge Anthropic ⇄ OpenAI

The clean, well-trodden solution is an **Anthropic-Messages-compatible proxy** that
accepts `/v1/messages`, translates to OpenAI `/v1/chat/completions`, calls NIM, and
translates the response (including streaming SSE and `tool_use`/`tool_calls`) back.

Two main options:

- **LiteLLM proxy / AI Gateway** (recommended). It explicitly supports:
  - A unified **`/v1/messages`** Anthropic endpoint (`docs.litellm.ai/docs/anthropic_unified`),
    including `/v1/messages/count_tokens`, and forwarding of `anthropic-*` headers — i.e.
    exactly what fronting the Agent SDK requires.
  - **NVIDIA NIM as a provider** out of the box.
  - Anthropic↔OpenAI request/response adapters
    (`translate_anthropic_to_openai` / `translate_openai_response_to_anthropic`).
  - The documented Claude Code recipe: run the proxy, then
    `export ANTHROPIC_BASE_URL=http://litellm:4000` and
    `export ANTHROPIC_AUTH_TOKEN=<proxy key>`.
  - ⚠️ **Supply-chain note:** LiteLLM PyPI **1.82.7 / 1.82.8 were compromised** with
    credential-stealing malware. Pin a known-clean version and verify before install.
- **`claude-code-router` / a custom thin proxy.** A small purpose-built FastAPI/Express
  service that does only Anthropic→OpenAI(NIM) translation. More code to own, but no
  heavyweight dependency and full control over edge cases (tool-call streaming, system
  prompt handling, reasoning-token models).

➡️ This reframes the developer's "I forked the SDK" story: **you almost never need to
fork the SDK.** The endpoint swap is an env var; the real work is the **proxy**. Forking
is only justified if you want to eliminate the proxy hop (see Gap analysis).

### 5. Hooking the agent lifecycle for automated verification

The SDK has a **first-class hooks system** — this is the intended, non-fork way to inject
verification. Hooks are callbacks (or shell commands from settings) registered per event:

Relevant events: `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`
(TS-only, fires once after a batch of tool calls resolves, before the next model call),
`UserPromptSubmit`, `Stop`, `SessionStart`/`SessionEnd` (TS), `SubagentStop`, etc.

How a hook influences the loop (the mechanism we exploit):

- A hook callback receives `{ tool_name, tool_input, session_id, cwd, hook_event_name }`
  and returns an output object.
- **`PreToolUse`** can return `hookSpecificOutput.permissionDecision` =
  `allow` / `deny` / `ask` / `defer`, plus `permissionDecisionReason` and `updatedInput`.
  `deny` blocks the tool call; the **reason is fed back to the model** so it adapts.
- **`PostToolUse`** can return `hookSpecificOutput.additionalContext` (appended to the
  tool result the model sees) or `updatedToolOutput` (replaces the tool output). This is
  the channel for **"here are your lint/type/test failures, fix them."**
- `deny > defer > ask > allow` precedence; any `deny` wins. Multiple hooks run in
  parallel. Hooks have a `timeout` (default 60s) — relevant because test suites are slow.

**Verification design:** register a `PostToolUse` hook matched to `Write|Edit` (and
optionally `MultiEdit`). On fire, run linter/type-checker/tests against the changed file
(or project), and:

- If clean → return `{}` (allow, no-op).
- If failing → return `additionalContext` containing the captured stderr/stdout so the
  model immediately sees the failure and self-corrects on the next turn. Optionally use
  `PreToolUse` on `Bash` to gate dangerous commands.

`PostToolBatch` (TS) is attractive for **debouncing**: run the full test suite once after
a batch of edits rather than after every single `Edit`, which matters for the 40 RPM /
credit budget and for slow suites.

### 6. Running in Docker with Git credentials at startup

Established patterns from the docs and community:

- **Base image:** `node:22-bookworm-slim` (TS SDK needs Node ≥ 18; the bundled binary is
  glibc-based, so prefer Debian over Alpine/musl). Add `git`, language toolchains
  (`python3`, `pip`, `ruff`/`mypy`/`pytest` or `eslint`/`tsc`/`vitest`), `ca-certificates`.
- **Don't bake secrets into layers.** Inject at `docker run` time via `-e` / `--env-file`:
  `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` (proxy key), `NVIDIA_API_KEY` (used by the
  proxy), `GIT_*`.
- **Git credentials at startup (entrypoint script):** options, least-leaky first:
  1. Mount the host `~/.gitconfig` read-only and use a **GitHub token** passed as env,
     written by the entrypoint to a `git credential.helper store` file with `0600` perms
     (or use the `store`/`cache` helper), then `git config --global user.name/email`.
  2. SSH: mount a deploy key read-only at `/root/.ssh/id_ed25519` (`0600`) + known_hosts.
  3. Most secure: a **git credential proxy / MCP git server on the host** so the
     container never sees the token (overkill for v1).
- **Run as non-root:** entrypoint creates a user from host `UID`/`GID` so files written to
  mounted volumes aren't root-owned.
- **Volumes:** mount the working repo at `/workspace` (`cwd` for the agent). Keep the
  agent's `permissionMode` aligned with the isolation level (see risks).
- **Compose:** two services — `proxy` (LiteLLM/custom, talks to NIM) and `agent` (SDK +
  verification), agent depends on proxy, `ANTHROPIC_BASE_URL=http://proxy:4000`.

---

## Gap analysis

### Straightforward vs. requires forking / heavy lifting

| Concern | Difficulty | Approach |
| --- | --- | --- |
| Point SDK at non-Anthropic host | **Trivial** | `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` env vars. No code. |
| Make NIM speak Anthropic protocol | **Medium** | Run a translation **proxy** (LiteLLM `/v1/messages` or custom). The bulk of integration effort lives here, esp. streaming + tool-call mapping. |
| Inject lint/type/test verification | **Easy–Medium** | `PostToolUse` / `PostToolBatch` hook callbacks. Official, supported, no fork. |
| Run in Docker w/ Git creds | **Easy** | Standard entrypoint + env injection patterns. |
| Eliminate the proxy hop (true in-process redirect) | **Hard / not recommended** | Would require **forking the SDK *and* the bundled binary**, or replacing the binary's HTTP client to emit OpenAI requests. The binary is closed/native and bundled; this is brittle and high-maintenance. Avoid. |

### Cleaner / official alternatives to "forking the SDK"

- **The developer's "fork" is best implemented as a proxy, not a fork.** A proxy is a
  thin, swappable, independently-testable wrapper; a fork of a bundled-binary SDK is a
  maintenance trap that breaks on every upstream release.
- **Verification via hooks, not patches.** Hooks are the sanctioned interception point; no
  need to modify the agent loop.
- **Model routing / fallback via the proxy's model_list** (LiteLLM) gives free
  multi-model routing, retries, and cost/credit tracking — useful against the 40 RPM cap.
- **System prompt / `CLAUDE.md` / skills** can steer behavior (e.g. "always run tests")
  but are *advisory*; hooks are *deterministic*. Use both: prompt to encourage, hooks to
  enforce.

### Risks & gotchas

1. **Tool-calling quality is the #1 risk.** The entire agent depends on the model
   emitting correct tool calls. Many free open models are weaker than Claude at
   multi-step tool use and strict JSON-schema adherence. Mitigation: pick strong
   tool-calling models (DeepSeek-V3/R1, Kimi-K2, GLM, GPT-OSS large), test early with a
   trivial Read→Edit task, keep a fallback model.
2. **Protocol-translation fidelity.** Streaming SSE, `tool_use`↔`tool_calls`, system
   blocks, `count_tokens`, reasoning/`<think>` tokens, and `anthropic-beta` headers must
   all map correctly or the loop stalls or loops. This is where most debugging time goes.
3. **Rate limits / credits.** 40 RPM + finite credits vs. an agent that fires many
   model+tool turns. Mitigations: `PostToolBatch` debounce, proxy-level retry/backoff,
   smaller models for cheap turns, `maxTurns` cap.
4. **Auth model.** Anthropic's terms disallow third-party "Claude login"; you must use
   API-key-style auth — which is exactly what we do (`ANTHROPIC_AUTH_TOKEN` = proxy key,
   `NVIDIA_API_KEY` for the upstream). Branding rules also restrict using "Claude Code"
   naming for a derived product.
5. **Docker security.** Running with `permissionMode: bypassPermissions` + Git creds +
   network = an autonomous agent that can push code and run arbitrary Bash. Contain it:
   non-root user, read-only mounts where possible, scoped GitHub token (single repo,
   minimal perms), egress allowlist (NIM + GitHub only), no host Docker socket.
6. **Supply chain.** Pin LiteLLM to a vetted version (avoid 1.82.7/1.82.8). Pin SDK and
   base image digests.
7. **Hook timeouts.** Test suites can exceed the default 60s hook timeout → raise
   `timeout`, or run long suites async / on a debounced batch rather than per-edit.
8. **Env vars read once at start.** Endpoint/model changes require restarting the agent
   process, not mutating env mid-run.

---

## Implementation plan

### Repo structure (proposed)

```
nim-self-verifying-agent/
├── PRD.md                      # this document
├── README.md
├── package.json                # @anthropic-ai/claude-agent-sdk + tooling
├── tsconfig.json
├── .env.example                # NVIDIA_API_KEY, proxy key, model ids, git token
├── docker-compose.yml          # proxy + agent services
├── proxy/
│   ├── litellm-config.yaml     # model_list mapping anthropic-name -> nim model
│   └── Dockerfile              # (if using custom proxy instead of upstream image)
├── agent/
│   ├── Dockerfile              # node + git + language/test toolchains
│   ├── entrypoint.sh           # git cred injection, user setup, exec agent
│   └── src/
│       ├── main.ts             # query() driver, options, session handling
│       ├── hooks/
│       │   ├── verify.ts       # PostToolUse/PostToolBatch lint+type+test hook
│       │   └── guard.ts        # PreToolUse Bash/path guardrails
│       └── verify/
│           ├── runners.ts      # spawn ruff/mypy/pytest or eslint/tsc/vitest
│           └── format.ts       # turn failures into additionalContext text
├── .claude/
│   ├── settings.json           # optional shell-hook + permission rules
│   └── CLAUDE.md               # "always keep code passing lint/types/tests"
└── workspace/                  # mounted target repo the agent edits (gitignored)
```

### Step 1 — Endpoint redirection (no fork)

- Install `@anthropic-ai/claude-agent-sdk`.
- Configure via env (passed through `options.env` or container env):
  - `ANTHROPIC_BASE_URL=http://proxy:4000`
  - `ANTHROPIC_AUTH_TOKEN=<proxy-key>`
  - `options.model = "deepseek-v3"` (an alias defined in the proxy model_list, see Step 2)
- **No SDK files are modified.** (Explicitly reject the "edit the SDK source" path; the TS
  SDK drives a bundled binary, so source edits won't take effect anyway.)

### Step 2 — NVIDIA NIM via translation proxy

Recommended: LiteLLM proxy. `proxy/litellm-config.yaml` sketch:

```yaml
model_list:
  - model_name: deepseek-v3                 # the name the SDK/agent requests
    litellm_params:
      model: nvidia_nim/deepseek-ai/deepseek-v3.2
      api_key: os.environ/NVIDIA_API_KEY
      api_base: https://integrate.api.nvidia.com/v1
  - model_name: kimi
    litellm_params:
      model: nvidia_nim/moonshotai/kimi-k2.5
      api_key: os.environ/NVIDIA_API_KEY
      api_base: https://integrate.api.nvidia.com/v1
general_settings:
  master_key: os.environ/PROXY_MASTER_KEY    # == ANTHROPIC_AUTH_TOKEN for the agent
litellm_settings:
  num_retries: 3
  request_timeout: 600
```

- Verify the proxy serves the **Anthropic** surface `/v1/messages` (+ `/v1/messages/count_tokens`)
  and forwards `anthropic-version` / `anthropic-beta`.
- Pin a clean LiteLLM version (NOT 1.82.7/1.82.8).
- If LiteLLM's Anthropic adapter mishandles tool-call streaming for a chosen model, fall
  back to a **custom thin proxy** (Express/FastAPI) implementing only the mappings we need.
- Validate independently with `curl` (Anthropic-shaped `/v1/messages` request → expect a
  valid Anthropic-shaped response) **before** wiring the SDK in.

### Step 3 — Verification hooks (the self-verifying core)

`agent/src/hooks/verify.ts` (pseudocode):

```ts
const verifyHook: HookCallback = async (input) => {
  if (input.hook_event_name !== "PostToolUse") return {};
  const file = (input.tool_input as any)?.file_path;
  if (!file || !isCodeFile(file)) return {};

  const results = await runCheckers(file);   // ruff/mypy/pytest OR eslint/tsc/vitest
  if (results.allPassed) return {};

  return {                                    // feed failures back into the loop
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext:
        `Automated verification FAILED for ${file}. Fix before continuing:\n` +
        results.formattedOutput,              // captured stderr/stdout, truncated
    },
  };
};
```

- Register: `hooks: { PostToolUse: [{ matcher: "Write|Edit", hooks: [verifyHook] }] }`.
- Consider `PostToolBatch` (TS) for the full **test suite** to debounce (run once per
  batch, not per edit) — saves credits/RPM.
- Add `agent/src/hooks/guard.ts` as `PreToolUse` on `Bash` to `deny` destructive commands
  (`rm -rf /`, `git push --force`, etc.) with a reason.
- Raise hook `timeout` above the suite runtime; truncate `additionalContext` so we don't
  blow the context window or credits.
- Belt-and-suspenders: also drop a `CLAUDE.md` instruction ("keep lint/types/tests green")
  so the model is primed, while the hook enforces it deterministically.

### Step 4 — Dockerfile & entrypoint

`agent/Dockerfile` outline:

```dockerfile
FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*
# language/test tooling (example: TS stack) — pin versions
WORKDIR /app
COPY agent/package*.json ./
RUN npm ci
COPY agent/ ./
COPY agent/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

`agent/entrypoint.sh` outline:

```sh
#!/usr/bin/env sh
set -e
# 1) create non-root user matching host UID/GID (if provided)
# 2) inject git identity + credentials at startup
git config --global user.name  "${GIT_USER_NAME}"
git config --global user.email "${GIT_USER_EMAIL}"
git config --global credential.helper store
printf "https://x-access-token:%s@github.com\n" "${GITHUB_TOKEN}" > "${HOME}/.git-credentials"
chmod 600 "${HOME}/.git-credentials"
# 3) hand off to the agent (cwd = mounted /workspace)
exec node /app/dist/main.js "$@"
```

`docker-compose.yml`: `proxy` service (LiteLLM, env `NVIDIA_API_KEY`, `PROXY_MASTER_KEY`)
+ `agent` service (`depends_on: proxy`, env `ANTHROPIC_BASE_URL=http://proxy:4000`,
`ANTHROPIC_AUTH_TOKEN=$PROXY_MASTER_KEY`, `GITHUB_TOKEN`, mounts `./workspace:/workspace`).
Harden: non-root, scoped token, egress allowlist (NIM + GitHub), no host docker socket.

### Suggested order of implementation (validate-as-you-go)

1. **Proxy first, in isolation.** Stand up LiteLLM → NIM. `curl` an Anthropic-shaped
   `/v1/messages` request and confirm a correct Anthropic-shaped reply (incl. streaming &
   a tool-call round-trip). *Nothing else works until this does.*
2. **Minimal SDK run, host-side.** `query()` with `ANTHROPIC_BASE_URL` at the proxy and a
   trivial prompt ("list files"). Confirm tool calls flow end-to-end on the chosen NIM
   model. This is the go/no-go test for model tool-calling quality.
3. **Add the verification hook.** Introduce a deliberate lint/type/test failure and prove
   the failure text reaches the model and it self-corrects.
4. **Add `PreToolUse` guardrails** and credit-saving debounce (`PostToolBatch`).
5. **Containerize.** Move the validated agent into Docker; wire compose with the proxy.
6. **Git credential injection + a real task** (clone, branch, edit until green, commit,
   push) in the sandbox with a scoped token.
7. **Harden & observe:** retries/backoff for 40 RPM, egress allowlist, non-root, secret
   hygiene, logging of hook decisions and credit usage.

---

## Open questions

1. **Language/stack of the target code** the agent edits — determines the verifier set
   (`ruff`/`mypy`/`pytest` vs `eslint`/`tsc`/`vitest` vs polyglot). Drives Step 3 & the
   Dockerfile toolchain.
2. **Which NIM model(s)** are primary/fallback? Need an early tool-calling shoot-out
   (DeepSeek-V3/R1 vs Kimi-K2 vs GLM vs GPT-OSS) since the SDK lives or dies on tool-use
   quality.
3. **LiteLLM vs custom proxy** — start with LiteLLM (faster), but is the team willing to
   own a small custom proxy if LiteLLM's Anthropic↔OpenAI tool-call streaming is lossy for
   the chosen model?
4. **Verification scope per edit:** changed file only (fast, cheap) vs whole project (more
   correct, more credits/time). Likely: lint+types on the file per-edit, full tests
   debounced via `PostToolBatch`.
5. **Git credential strategy:** PAT-in-credential-store (simple) vs SSH deploy key vs
   host-side credential proxy (most secure). Depends on required isolation level.
6. **Autonomy vs safety:** `bypassPermissions` for "never stop" autonomy conflicts with
   safe Bash/push. How aggressive should `PreToolUse` guardrails be, and is an egress
   allowlist required?
7. **Credit/RPM budget & multi-key strategy:** is 40 RPP / ~1–5k credits enough for the
   intended workloads, or do we need key rotation / model tiering / local NIM containers?
8. **Anthropic terms / branding:** confirm the derived product naming and that
   API-key-style auth (not Claude login) is acceptable for the intended distribution.

---

### Sources

- [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview)
- [Agent SDK hooks](https://code.claude.com/docs/en/agent-sdk/hooks)
- [Securely deploying AI agents](https://platform.claude.com/docs/en/agent-sdk/secure-deployment) · [Hosting the Agent SDK](https://code.claude.com/docs/en/agent-sdk/hosting)
- [ANTHROPIC_BASE_URL: what it really does](https://fazm.ai/blog/route-claude-api-through-custom-endpoint-anthropic-base-url) · [issue #195 (base URL behavior)](https://github.com/anthropics/claude-agent-sdk-typescript/issues/195)
- [NVIDIA NIM API reference](https://docs.nvidia.com/nim/large-language-models/latest/api-reference.html) · [NIM as OpenAI-compatible provider](https://ai-sdk.dev/providers/openai-compatible-providers/nim) · [build.nvidia.com](https://build.nvidia.com/models)
- [NVIDIA NIM free API: rate limits & keys (2026)](https://decodethefuture.org/en/nvidia-nim-api-explained/) · [NIM pricing & rate limits (2026)](https://decodethefuture.org/en/nvidia-nim-api-pricing-limits-guide/)
- [LiteLLM](https://github.com/BerriAI/litellm) · [LiteLLM unified `/v1/messages`](https://docs.litellm.ai/docs/anthropic_unified/) · [Claude Code + LiteLLM setup](https://www.morphllm.com/claude-code-litellm)
- [Claude Code Docker tutorial](https://www.datacamp.com/tutorial/claude-code-docker) · [claude-agent-sdk-container](https://github.com/receipting/claude-agent-sdk-container) · [Docker docs: Claude Code](https://docs.docker.com/ai/sandboxes/agents/claude-code/)
</content>
</invoke>
