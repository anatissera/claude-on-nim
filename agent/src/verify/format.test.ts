import { describe, expect, it } from "vitest";
import { formatTestFailure, formatVerifyReport } from "./format.js";
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
