import type { HookCallback, PreToolUseHookInput } from "@anthropic-ai/claude-agent-sdk";

/**
 * Commands the agent must never run unattended, regardless of permissionMode.
 * This is the deterministic backstop for an agent that otherwise has Git
 * credentials and bypassPermissions-level autonomy in the container.
 */
const DENY_PATTERNS: { pattern: RegExp; reason: string }[] = [
  { pattern: /\brm\s+-rf\s+\/(?!workspace)/, reason: "Refusing to recursively delete outside /workspace." },
  { pattern: /\bgit\s+push\s+.*--force\b/, reason: "Force-push is not allowed; resolve conflicts instead." },
  { pattern: /\bgit\s+reset\s+--hard\b/, reason: "Hard reset can discard work; use a safer alternative." },
  { pattern: /\bgit\s+clean\s+-[a-z]*f/, reason: "git clean -f can delete untracked work; not allowed." },
  { pattern: /\bcurl\b.*\|\s*(sh|bash)\b/, reason: "Piping a remote script into a shell is not allowed." },
  { pattern: /\bchmod\s+-R\s+777\b/, reason: "Recursively opening permissions to 777 is not allowed." },
];

/**
 * PreToolUse hook: denies destructive Bash commands before they execute.
 * Returning `deny` blocks the call and feeds permissionDecisionReason back
 * to the model, so it can adapt rather than retry blindly.
 */
export const guardBashHook: HookCallback = async (input) => {
  if (input.hook_event_name !== "PreToolUse") return {};
  const preInput = input as PreToolUseHookInput;
  if (preInput.tool_name !== "Bash") return {};

  const command = (preInput.tool_input as Record<string, unknown> | undefined)?.command;
  if (typeof command !== "string") return {};

  const match = DENY_PATTERNS.find((entry) => entry.pattern.test(command));
  if (!match) return {};

  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: match.reason,
    },
  };
};
