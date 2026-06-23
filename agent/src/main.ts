import { query } from "@anthropic-ai/claude-agent-sdk";
import { config } from "./config.js";
import { createVerifyBatchHook, createVerifyFileHook } from "./hooks/verify.js";
import { guardBashHook } from "./hooks/guard.js";

const prompt = process.argv.slice(2).join(" ").trim();
if (!prompt) {
  console.error("Usage: node dist/main.js <prompt>");
  process.exit(1);
}

const verifyOptions = {
  projectRoot: config.cwd,
  timeoutMs: config.verifyTimeoutMs,
  maxOutputChars: config.verifyMaxOutputChars,
};

async function main(): Promise<void> {
  const stream = query({
    prompt,
    options: {
      cwd: config.cwd,
      model: config.model,
      fallbackModel: config.fallbackModel,
      permissionMode: config.permissionMode,
      maxTurns: config.maxTurns,
      // Load only the project-level .claude/ (the CLAUDE.md entrypoint.sh
      // seeds into /workspace). Excludes 'user', so this headless agent never
      // inherits the operating user's global ~/.claude settings/CLAUDE.md/skills.
      settingSources: ["project"],
      // Options.env REPLACES the subprocess env wholesale, so we must spread
      // process.env ourselves to keep PATH/HOME/etc. and forward the
      // NIM-proxy endpoint the SDK's bundled binary reads at startup.
      env: {
        ...process.env,
        ANTHROPIC_BASE_URL: config.anthropicBaseUrl,
        ANTHROPIC_AUTH_TOKEN: config.anthropicAuthToken,
      },
      hooks: {
        PreToolUse: [{ matcher: "Bash", hooks: [guardBashHook] }],
        PostToolUse: [{ matcher: "Write|Edit|MultiEdit", hooks: [createVerifyFileHook(verifyOptions)] }],
        PostToolBatch: [{ hooks: [createVerifyBatchHook(verifyOptions)] }],
      },
    },
  });

  const verbose = process.env.AGENT_VERBOSE === "1";

  for await (const message of stream) {
    if (message.type === "assistant") {
      for (const block of message.message.content) {
        if (block.type === "text") process.stdout.write(block.text);
        else if (verbose && block.type === "tool_use") {
          console.error(`\n[tool_use] ${block.name} ${JSON.stringify(block.input)}`);
        }
      }
    } else if (verbose && message.type === "user") {
      const content = message.message.content;
      if (Array.isArray(content)) {
        for (const block of content) {
          if (block.type === "tool_result") {
            console.error(`[tool_result] ${JSON.stringify(block.content).slice(0, 2000)}`);
          }
        }
      }
    } else if (message.type === "result") {
      console.log(`\n\n[result] ${message.subtype} (${message.num_turns} turns)`);
      if (message.subtype !== "success") {
        process.exitCode = 1;
      }
    }
  }
}

main().catch((error) => {
  console.error("Agent run failed:", error);
  process.exit(1);
});
