import { describe, expect, it } from "vitest";
import { formatLintFailure, formatTestFailure, formatVerifyReport } from "./format.js";
import type { VerifyReport } from "./runners.js";

describe("formatVerifyReport", () => {
  it("returns null when every check passed", () => {
    const report: VerifyReport = {
      file: "src/foo.ts",
      allPassed: true,
      checks: [{ name: "eslint", passed: true, output: "" }],
    };
    expect(formatVerifyReport(report, 1000)).toBeNull();
  });

  it("includes only failing checks in the rendered context", () => {
    const report: VerifyReport = {
      file: "src/foo.ts",
      allPassed: false,
      checks: [
        { name: "eslint", passed: true, output: "" },
        { name: "tsc", passed: false, output: "src/foo.ts:1:1 - error TS2304" },
      ],
    };
    const text = formatVerifyReport(report, 1000);
    expect(text).toContain("src/foo.ts");
    expect(text).toContain("tsc");
    expect(text).toContain("TS2304");
    expect(text).not.toContain("eslint");
  });

  it("truncates output longer than the configured limit", () => {
    const report: VerifyReport = {
      file: "src/foo.ts",
      allPassed: false,
      checks: [{ name: "ruff", passed: false, output: "x".repeat(50) }],
    };
    const text = formatVerifyReport(report, 10)!;
    expect(text).toContain("...[truncated");
    expect(text).not.toContain("x".repeat(50));
  });
});

describe("formatTestFailure", () => {
  it("renders the failing test command output", () => {
    const text = formatTestFailure({ name: "npm test", passed: false, output: "1 failing" }, 1000);
    expect(text).toContain("Automated test suite FAILED");
    expect(text).toContain("1 failing");
  });
});

describe("formatVerifyReport edge cases", () => {
  it("returns null for a report with no checks at all", () => {
    // An unrecognised file type produces zero checks; that is not a failure
    // and must not put anything in front of the model.
    expect(formatVerifyReport({ file: "notes.md", allPassed: true, checks: [] }, 100)).toBeNull();
  });

  it("names the file so the model knows what to fix", () => {
    const context = formatVerifyReport(
      {
        file: "/workspace/src/a.ts",
        allPassed: false,
        checks: [{ name: "tsc", passed: false, output: "error TS2322" }],
      },
      500,
    );
    expect(context).toContain("/workspace/src/a.ts");
  });

  it("renders every failing check, not just the first", () => {
    const context = formatVerifyReport(
      {
        file: "a.ts",
        allPassed: false,
        checks: [
          { name: "eslint", passed: false, output: "lint-problem" },
          { name: "tsc", passed: false, output: "type-problem" },
        ],
      },
      500,
    );
    expect(context).toContain("lint-problem");
    expect(context).toContain("type-problem");
  });

  it("keeps passing checks out of the report even when a sibling fails", () => {
    const context = formatVerifyReport(
      {
        file: "a.ts",
        allPassed: false,
        checks: [
          { name: "eslint", passed: true, output: "all good, nothing to see" },
          { name: "tsc", passed: false, output: "type-problem" },
        ],
      },
      500,
    );
    expect(context).toContain("type-problem");
    expect(context).not.toContain("nothing to see");
  });

  it("substitutes a placeholder for a checker that failed silently", () => {
    const context = formatVerifyReport(
      { file: "a.ts", allPassed: false, checks: [{ name: "tsc", passed: false, output: "   " }] },
      500,
    );
    expect(context).toContain("(no output)");
  });

  it("does not truncate output that exactly fits the limit", () => {
    const output = "x".repeat(50);
    const context = formatVerifyReport(
      { file: "a.ts", allPassed: false, checks: [{ name: "tsc", passed: false, output }] },
      50,
    );
    expect(context).not.toContain("truncated");
  });

  it("reports how much was dropped when truncating", () => {
    const context = formatVerifyReport(
      { file: "a.ts", allPassed: false, checks: [{ name: "tsc", passed: false, output: "y".repeat(120) }] },
      100,
    );
    expect(context).toContain("truncated 20 chars");
  });
});

describe("formatLintFailure", () => {
  it("explains that project lint catches edits made outside Write/Edit", () => {
    // This is the whole reason the batch hook lints the project as well as the
    // per-file hook linting the file: a model that edits via `sed` in Bash
    // never triggers PostToolUse on Write/Edit.
    const section = formatLintFailure({ name: "eslint .", passed: false, output: "2 problems" }, 200);
    expect(section).toContain("Bash");
    expect(section).toContain("2 problems");
  });

  it("truncates a huge project-wide lint dump", () => {
    const section = formatLintFailure(
      { name: "eslint .", passed: false, output: "z".repeat(5000) },
      100,
    );
    expect(section).toContain("truncated");
    expect(section.length).toBeLessThan(400);
  });
});

describe("formatTestFailure", () => {
  it("tells the model the failure blocks further work", () => {
    const section = formatTestFailure({ name: "npm test", passed: false, output: "1 failing" }, 200);
    expect(section).toContain("FAILED");
    expect(section).toContain("before continuing");
    expect(section).toContain("1 failing");
  });
});
