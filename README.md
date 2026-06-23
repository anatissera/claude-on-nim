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

🔬 **Research phase complete.** See [`PRD.md`](PRD.md) for detailed findings, architecture, and implementation roadmap.

## Quick start

(Placeholder — coming in implementation phase.)

## References

- [Claude Agent SDK docs](https://code.claude.com/docs/en/agent-sdk/)
- [NVIDIA NIM API](https://docs.nvidia.com/nim/large-language-models/latest/api-reference.html)
- [LiteLLM](https://github.com/BerriAI/litellm)
