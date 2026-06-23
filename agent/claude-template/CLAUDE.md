# Working agreement

This session is verified automatically: after every `Write`/`Edit`, your
changed file is linted and type-checked, and failures are reported back to
you immediately. After a batch of edits, the project's test suite runs.

- Treat verification failures as blocking — fix them before moving to the
  next task, don't just acknowledge and continue.
- Prefer small, targeted edits so a failure points at exactly what broke.
- Inference runs on a free, rate-limited endpoint. Avoid redundant tool calls
  (e.g. re-reading a file you already have in context) to conserve budget.
- Never force-push, hard-reset, or run destructive shell commands — these are
  blocked by a guardrail hook and will not execute even if attempted.
