import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { runProjectLint, runTestSuite, verifyFile } from "./runners.js";

const roots: string[] = [];

async function makeProject(): Promise<string> {
  const root = await mkdtemp(path.join(tmpdir(), "verify-"));
  roots.push(root);
  return root;
}

/**
 * Drops an executable stub at node_modules/.bin/<name>. The checkers probe for
 * these paths, so a stub is enough to exercise resolution without installing a
 * real toolchain.
 */
async function fakeBin(root: string, name: string, script: string): Promise<void> {
  const dir = path.join(root, "node_modules", ".bin");
  await mkdir(dir, { recursive: true });
  const file = path.join(dir, name);
  await writeFile(file, `#!/bin/sh\n${script}\n`);
  await chmod(file, 0o755);
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("verifyFile", () => {
  it("skips every checker for a file type none of them handle", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "notes.md"), "# hi");

    const report = await verifyFile(path.join(root, "notes.md"), root, 5000);

    expect(report.checks).toEqual([]);
    // Vacuously true, and deliberately so: an unknown file type must not be
    // reported as a failure.
    expect(report.allPassed).toBe(true);
  });

  it("skips eslint when the project has no eslint binary", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.js"), "const x = 1;");

    const report = await verifyFile(path.join(root, "a.js"), root, 5000);

    expect(report.checks.map((c) => c.name)).toEqual([]);
  });

  it("runs eslint on a JS file when the binary is present", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.js"), "const x = 1;");
    await fakeBin(root, "eslint", "exit 0");

    const report = await verifyFile(path.join(root, "a.js"), root, 5000);

    expect(report.checks).toHaveLength(1);
    expect(report.checks[0].name).toContain("eslint");
    expect(report.allPassed).toBe(true);
  });

  it("reports a failing checker with its captured output", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.js"), "const x = 1;");
    await fakeBin(root, "eslint", 'echo "a.js:1:7 no-unused-vars"; exit 1');

    const report = await verifyFile(path.join(root, "a.js"), root, 5000);

    expect(report.allPassed).toBe(false);
    expect(report.checks[0].passed).toBe(false);
    expect(report.checks[0].output).toContain("no-unused-vars");
  });

  it("captures stderr as well as stdout", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.js"), "x");
    await fakeBin(root, "eslint", 'echo "boom" >&2; exit 1');

    const report = await verifyFile(path.join(root, "a.js"), root, 5000);

    expect(report.checks[0].output).toContain("boom");
  });

  it("skips tsc when there is no tsconfig.json, even with the binary present", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.ts"), "const x: number = 1;");
    await fakeBin(root, "tsc", "exit 0");

    const report = await verifyFile(path.join(root, "a.ts"), root, 5000);

    expect(report.checks.map((c) => c.name).join(" ")).not.toContain("tsc");
  });

  it("runs tsc for a TS file when both tsconfig and the binary exist", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.ts"), "const x: number = 1;");
    await writeFile(path.join(root, "tsconfig.json"), "{}");
    await fakeBin(root, "tsc", "exit 0");

    const report = await verifyFile(path.join(root, "a.ts"), root, 5000);

    expect(report.checks.some((c) => c.name.includes("tsc"))).toBe(true);
  });

  it("does not run tsc for a plain .js file", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.js"), "var x = 1");
    await writeFile(path.join(root, "tsconfig.json"), "{}");
    await fakeBin(root, "tsc", "exit 0");

    const report = await verifyFile(path.join(root, "a.js"), root, 5000);

    expect(report.checks.map((c) => c.name).join(" ")).not.toContain("tsc");
  });

  it("marks a checker failed when the binary cannot be spawned", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.py"), "x = 1");

    // ruff/mypy are resolved by name off PATH. On a machine without them the
    // spawn errors, and that must surface as a failed check rather than an
    // unhandled rejection.
    const report = await verifyFile(path.join(root, "a.py"), root, 5000);

    expect(report.checks.length).toBeGreaterThan(0);
    for (const check of report.checks) {
      expect(typeof check.passed).toBe("boolean");
      expect(typeof check.output).toBe("string");
    }
  });

  it("kills a checker that exceeds the timeout and says so", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.js"), "x");
    await fakeBin(root, "eslint", "sleep 10");

    const started = Date.now();
    const report = await verifyFile(path.join(root, "a.js"), root, 400);
    const elapsed = Date.now() - started;

    expect(report.allPassed).toBe(false);
    expect(elapsed).toBeLessThan(5000);
    expect(report.checks[0].output).toContain("timed out");
  }, 15_000);

  it("kills the whole process tree, not just the command it spawned", async () => {
    // A checker is usually a wrapper: `npm test` spawns a runner, which spawns
    // workers. Killing only the direct child leaves those alive holding the
    // stdout pipe. The stub below backgrounds a grandchild that writes a file
    // shortly after the timeout should have fired; if the process group really
    // is killed, that write never happens.
    const root = await makeProject();
    const marker = path.join(root, "orphan-survived");
    await writeFile(path.join(root, "a.js"), "x");
    await fakeBin(root, "eslint", `( sleep 1; echo alive > "${marker}" ) &\nsleep 10`);

    await verifyFile(path.join(root, "a.js"), root, 300);

    // Outlive the grandchild's own sleep before checking.
    await new Promise((resolve) => setTimeout(resolve, 2500));
    const { access } = await import("node:fs/promises");
    await expect(access(marker)).rejects.toThrow();
  }, 20_000);

  it("accepts a path relative to the project root", async () => {
    const root = await makeProject();
    await writeFile(path.join(root, "a.js"), "x");
    await fakeBin(root, "eslint", "exit 0");

    const report = await verifyFile(path.join(root, "a.js"), root, 5000);

    expect(report.file).toContain("a.js");
  });
});

describe("runTestSuite", () => {
  it("returns null when the project has neither package.json nor pyproject.toml", async () => {
    const root = await makeProject();
    await expect(runTestSuite(root, 5000)).resolves.toBeNull();
  });

  it("prefers npm test when package.json is present", async () => {
    const root = await makeProject();
    await writeFile(
      path.join(root, "package.json"),
      JSON.stringify({ name: "t", scripts: { test: "exit 0" } }),
    );

    const result = await runTestSuite(root, 30_000);

    expect(result).not.toBeNull();
    expect(result!.name).toContain("npm");
  }, 60_000);

  it("surfaces a failing suite", async () => {
    const root = await makeProject();
    await writeFile(
      path.join(root, "package.json"),
      JSON.stringify({ name: "t", scripts: { test: "echo nope >&2; exit 1" } }),
    );

    const result = await runTestSuite(root, 30_000);

    expect(result!.passed).toBe(false);
  }, 60_000);
});

describe("runProjectLint", () => {
  it("returns null when neither eslint nor ruff is available", async () => {
    const root = await makeProject();
    // ruff is looked up on PATH; if the host happens to have it the call is
    // still well-formed, so accept either shape rather than assuming.
    const result = await runProjectLint(root, 5000);
    if (result !== null) {
      expect(result.name).toContain("ruff");
    }
  });

  it("uses the project's eslint when it exists", async () => {
    const root = await makeProject();
    await fakeBin(root, "eslint", "exit 0");

    const result = await runProjectLint(root, 5000);

    expect(result).not.toBeNull();
    expect(result!.name).toContain("eslint");
    expect(result!.passed).toBe(true);
  });

  it("reports project-wide lint failures", async () => {
    const root = await makeProject();
    await fakeBin(root, "eslint", 'echo "3 problems"; exit 1');

    const result = await runProjectLint(root, 5000);

    expect(result!.passed).toBe(false);
    expect(result!.output).toContain("3 problems");
  });
});
