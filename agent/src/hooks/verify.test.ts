import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createVerifyBatchHook, createVerifyFileHook } from "./verify.js";

const roots: string[] = [];

async function makeProject(): Promise<string> {
  const root = await mkdtemp(path.join(tmpdir(), "verifyhook-"));
  roots.push(root);
  return root;
}

async function fakeBin(root: string, name: string, script: string): Promise<void> {
  const dir = path.join(root, "node_modules", ".bin");
  await mkdir(dir, { recursive: true });
  const file = path.join(dir, name);
  await writeFile(file, `#!/bin/sh\n${script}\n`);
  await chmod(file, 0o755);
}

function options(root: string) {
  return { projectRoot: root, timeoutMs: 5000, maxOutputChars: 2000 };
}

/** Minimal PostToolUse hook input; the hooks only read a few fields. */
function postToolUse(toolName: string, toolInput: unknown) {
  return {
    hook_event_name: "PostToolUse",
    tool_name: toolName,
    tool_input: toolInput,
    session_id: "s",
    cwd: "/workspace",
    transcript_path: "/tmp/t",
    permission_mode: "bypassPermissions",
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any;
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("createVerifyFileHook", () => {
  it("ignores events that are not PostToolUse", async () => {
    const root = await makeProject();
    const hook = createVerifyFileHook(options(root));

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = await hook({ hook_event_name: "PreToolUse", tool_name: "Write" } as any, undefined, {
      signal: new AbortController().signal,
    });

    expect(result).toEqual({});
  });

  it("ignores tools that do not edit files", async () => {
    const root = await makeProject();
    const hook = createVerifyFileHook(options(root));

    const result = await hook(postToolUse("Bash", { command: "ls" }), undefined, {
      signal: new AbortController().signal,
    });

    expect(result).toEqual({});
  });

  it("ignores an edit with no file_path", async () => {
    const root = await makeProject();
    const hook = createVerifyFileHook(options(root));

    const result = await hook(postToolUse("Edit", {}), undefined, {
      signal: new AbortController().signal,
    });

    expect(result).toEqual({});
  });

  it("stays silent when every checker passes", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.js"), "const x = 1;");
    await fakeBin(root, "eslint", "exit 0");
    const hook = createVerifyFileHook(options(root));

    const result = await hook(postToolUse("Write", { file_path: path.join(root, "a.js") }), undefined, {
      signal: new AbortController().signal,
    });

    // Silence matters: a passing check must not spend context or credits.
    expect(result).toEqual({});
  });

  it("feeds failures back as additionalContext so the model self-corrects", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.js"), "const x = 1;");
    await fakeBin(root, "eslint", 'echo "a.js:1:7  error  no-unused-vars"; exit 1');
    const hook = createVerifyFileHook(options(root));

    const result = await hook(postToolUse("Edit", { file_path: path.join(root, "a.js") }), undefined, {
      signal: new AbortController().signal,
    });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const output = (result as any).hookSpecificOutput;
    expect(output.hookEventName).toBe("PostToolUse");
    expect(output.additionalContext).toContain("no-unused-vars");
    expect(output.additionalContext).toContain("FAILED");
  });

  it("resolves a relative file_path against the project root", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.js"), "x");
    await fakeBin(root, "eslint", 'echo "relative-ok"; exit 1');
    const hook = createVerifyFileHook(options(root));

    const result = await hook(postToolUse("Write", { file_path: "a.js" }), undefined, {
      signal: new AbortController().signal,
    });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect((result as any).hookSpecificOutput.additionalContext).toContain("relative-ok");
  });

  it("handles MultiEdit the same as Write and Edit", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.js"), "x");
    await fakeBin(root, "eslint", 'echo "multi"; exit 1');
    const hook = createVerifyFileHook(options(root));

    const result = await hook(postToolUse("MultiEdit", { file_path: path.join(root, "a.js") }), undefined, {
      signal: new AbortController().signal,
    });

    expect(result).not.toEqual({});
  });

  it("truncates very long checker output to the configured cap", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.js"), "x");
    await fakeBin(root, "eslint", 'for i in $(seq 1 500); do echo "error line $i"; done; exit 1');
    const hook = createVerifyFileHook({ projectRoot: root, timeoutMs: 5000, maxOutputChars: 200 });

    const result = await hook(postToolUse("Write", { file_path: path.join(root, "a.js") }), undefined, {
      signal: new AbortController().signal,
    });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const context = (result as any).hookSpecificOutput.additionalContext as string;
    expect(context).toContain("truncated");
    expect(context.length).toBeLessThan(1000);
  });
});

describe("createVerifyBatchHook", () => {
  it("ignores events that are not PostToolBatch", async () => {
    const root = await makeProject();
    const hook = createVerifyBatchHook(options(root));

    const result = await hook(postToolUse("Write", { file_path: "a.js" }), undefined, {
      signal: new AbortController().signal,
    });

    expect(result).toEqual({});
  });

  it("stays silent when lint and tests both pass", async () => {
    const root = await makeProject();
    await fakeBin(root, "eslint", "exit 0");
    await writeFile(
      path.join(root, "package.json"),
      JSON.stringify({ name: "t", scripts: { test: "exit 0" } }),
    );
    const hook = createVerifyBatchHook(options(root));

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = await hook({ hook_event_name: "PostToolBatch" } as any, undefined, {
      signal: new AbortController().signal,
    });

    expect(result).toEqual({});
  }, 60_000);

  it("reports a project-wide lint failure", async () => {
    const root = await makeProject();
    await fakeBin(root, "eslint", 'echo "batch-lint-broke"; exit 1');
    const hook = createVerifyBatchHook(options(root));

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = await hook({ hook_event_name: "PostToolBatch" } as any, undefined, {
      signal: new AbortController().signal,
    });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const context = (result as any).hookSpecificOutput.additionalContext as string;
    expect(context).toContain("batch-lint-broke");
    // This is the path that catches edits made through Bash, which the
    // per-file hook never sees.
    expect(context).toContain("Bash");
  });

  it("reports a failing test suite", async () => {
    const root = await makeProject();
    await writeFile(
      path.join(root, "package.json"),
      JSON.stringify({ name: "t", scripts: { test: "echo suite-broke >&2; exit 1" } }),
    );
    const hook = createVerifyBatchHook(options(root));

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = await hook({ hook_event_name: "PostToolBatch" } as any, undefined, {
      signal: new AbortController().signal,
    });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const context = (result as any).hookSpecificOutput.additionalContext as string;
    expect(context).toContain("test suite FAILED");
  }, 60_000);

  it("combines lint and test failures into one report", async () => {
    const root = await makeProject();
    await fakeBin(root, "eslint", 'echo "lint-side"; exit 1');
    await writeFile(
      path.join(root, "package.json"),
      JSON.stringify({ name: "t", scripts: { test: "echo test-side >&2; exit 1" } }),
    );
    const hook = createVerifyBatchHook(options(root));

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = await hook({ hook_event_name: "PostToolBatch" } as any, undefined, {
      signal: new AbortController().signal,
    });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const context = (result as any).hookSpecificOutput.additionalContext as string;
    expect(context).toContain("lint-side");
    expect(context).toContain("test-side");
  }, 60_000);

  it("stays silent in a project with neither a linter nor a test suite", async () => {
    const root = await makeProject();
    const hook = createVerifyBatchHook(options(root));

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = await hook({ hook_event_name: "PostToolBatch" } as any, undefined, {
      signal: new AbortController().signal,
    });

    expect(result).toEqual({});
  });
});
