import type { CheckResult, VerifyReport } from "./runners.js";

function truncate(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text;
  return `${text.slice(0, maxChars)}\n...[truncated ${text.length - maxChars} chars]`;
}

/**
 * Renders a verification report as the additionalContext string fed back to
 * the model. Only failing checks are included to keep the model's context
 * (and our NIM credit budget) focused on what actually needs fixing.
 */
export function formatVerifyReport(report: VerifyReport, maxChars: number): string | null {
  const failures = report.checks.filter((c) => !c.passed);
  if (failures.length === 0) return null;

  const sections = failures.map((c) => formatCheck(c, maxChars));
  return [
    `Automated verification FAILED for ${report.file}. Fix these issues before continuing:`,
    ...sections,
  ].join("\n\n");
}

function formatCheck(check: CheckResult, maxChars: number): string {
  return `### ${check.name}\n${truncate(check.output.trim() || "(no output)", maxChars)}`;
}

export function formatTestFailure(check: CheckResult, maxChars: number): string {
  return [
    "Automated test suite FAILED after this batch of edits. Fix before continuing:",
    formatCheck(check, maxChars),
  ].join("\n\n");
}
