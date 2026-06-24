import path from "node:path";
import type { HookCallback, PreToolUseHookInput } from "@anthropic-ai/claude-agent-sdk";

const MUTATING_TOOLS = new Set(["Write", "Edit", "MultiEdit", "NotebookEdit"]);

/**
 * Bash commands the agent must never run unattended, regardless of
 * permissionMode. This is the deterministic backstop for an agent that
 * otherwise has Git credentials and bypassPermissions-level autonomy in the
 * container.
 */
const DENY_PATTERNS: { pattern: RegExp; reason: string }[] = [
  { pattern: /\brm\s+-rf\s+\/(?!workspace)/, reason: "Refusing to recursively delete outside /workspace." },
  { pattern: /\bgit\s+push\s+.*--force\b/, reason: "Force-push is not allowed; resolve conflicts instead." },
  { pattern: /\bgit\s+reset\s+--hard\b/, reason: "Hard reset can discard work; use a safer alternative." },
  { pattern: /\bgit\s+clean\s+-[a-z]*f/, reason: "git clean -f can delete untracked work; not allowed." },
  { pattern: /\bcurl\b.*\|\s*(sh|bash)\b/, reason: "Piping a remote script into a shell is not allowed." },
  { pattern: /\bchmod\s+-R\s+[0-7]{3,4}\s+\/(\s|$)/i, reason: "Recursively opening permissions on / is not allowed." },
  { pattern: /\bmkfs\b/i, reason: "Filesystem formatting is not allowed." },
  { pattern: /\bdd\b[^\n]*\bof=\/dev\//i, reason: "Writing directly to a block device is not allowed." },
  { pattern: /:\s*\(\s*\)\s*\{.*\}\s*;/, reason: "Fork bombs are not allowed." },
  {
    pattern: /(\.ssh\/|\bid_rsa\b|\bid_ed25519\b|\.aws\/credentials|\/etc\/shadow)/i,
    reason: "Reading credential or secret files is not allowed.",
  },
];

function bashLooksDangerous(command: string): boolean {
  return DENY_PATTERNS.some((entry) => entry.pattern.test(command));
}

/** True if `targetPath` (resolved against `root`) is `root` itself or inside it. */
function isInside(targetPath: string, root: string): boolean {
  const abs = path.resolve(root, targetPath);
  return abs === root || abs.startsWith(root + path.sep);
}

function filePathOf(toolInput: unknown): string | null {
  if (!toolInput || typeof toolInput !== "object") return null;
  const o = toolInput as Record<string, unknown>;
  const p = o.file_path ?? o.notebook_path;
  return typeof p === "string" ? p : null;
}

/**
 * PreToolUse hook: denies destructive Bash commands and edits/writes that
 * target a path outside the project root, before they execute. Returning
 * `deny` blocks the call and feeds permissionDecisionReason back to the
 * model, so it can adapt rather than retry blindly.
 */
export function createGuardHook(projectRoot: string): HookCallback {
  const root = path.resolve(projectRoot);

  return async (input) => {
    if (input.hook_event_name !== "PreToolUse") return {};
    const preInput = input as PreToolUseHookInput;

    if (MUTATING_TOOLS.has(preInput.tool_name)) {
      const fp = filePathOf(preInput.tool_input);
      if (fp && !isInside(fp, root)) {
        return {
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: `Blocked: ${preInput.tool_name} targets a path outside the project directory (${fp}).`,
          },
        };
      }
    }

    if (preInput.tool_name === "Bash") {
      const command = (preInput.tool_input as Record<string, unknown> | undefined)?.command;
      if (typeof command === "string") {
        const match = DENY_PATTERNS.find((entry) => entry.pattern.test(command));
        if (match) {
          return {
            hookSpecificOutput: {
              hookEventName: "PreToolUse",
              permissionDecision: "deny",
              permissionDecisionReason: match.reason,
            },
          };
        }
      }
    }

    return {};
  };
}

export { bashLooksDangerous, isInside };
