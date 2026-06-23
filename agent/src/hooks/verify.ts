import path from "node:path";
import type { HookCallback, PostToolUseHookInput } from "@anthropic-ai/claude-agent-sdk";
import { runTestSuite, verifyFile } from "../verify/runners.js";
import { formatTestFailure, formatVerifyReport } from "../verify/format.js";

const EDIT_TOOLS = new Set(["Write", "Edit", "MultiEdit"]);

type VerifyHookOptions = {
  projectRoot: string;
  timeoutMs: number;
  maxOutputChars: number;
};

/**
 * PostToolUse hook: lints/type-checks a single file immediately after the
 * model edits it. Failures are appended as additionalContext so the model
 * sees them on its very next turn, before it moves on to other work.
 */
export function createVerifyFileHook(options: VerifyHookOptions): HookCallback {
  return async (input) => {
    if (input.hook_event_name !== "PostToolUse") return {};
    const postInput = input as PostToolUseHookInput;
    if (!EDIT_TOOLS.has(postInput.tool_name)) return {};

    const toolInput = postInput.tool_input as Record<string, unknown> | undefined;
    const filePath = toolInput?.file_path as string | undefined;
    if (!filePath) return {};

    const absoluteFile = path.isAbsolute(filePath) ? filePath : path.join(options.projectRoot, filePath);
    const report = await verifyFile(absoluteFile, options.projectRoot, options.timeoutMs);
    const additionalContext = formatVerifyReport(report, options.maxOutputChars);
    if (!additionalContext) return {};

    return {
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext,
      },
    };
  };
}

/**
 * PostToolBatch hook: runs the full test suite once after a batch of tool
 * calls resolves, rather than after every single edit. Debouncing this way
 * matters against NVIDIA NIM's free-tier ~40 requests/minute cap and finite
 * credit pool — running pytest/npm test per-keystroke would burn both fast.
 */
export function createVerifyBatchHook(options: VerifyHookOptions): HookCallback {
  return async (input) => {
    if (input.hook_event_name !== "PostToolBatch") return {};

    const result = await runTestSuite(options.projectRoot, options.timeoutMs);
    if (!result || result.passed) return {};

    return {
      hookSpecificOutput: {
        hookEventName: "PostToolBatch",
        additionalContext: formatTestFailure(result, options.maxOutputChars),
      },
    };
  };
}
