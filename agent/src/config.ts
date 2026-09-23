function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

/**
 * Reads an optional setting, treating an empty or whitespace-only value as
 * unset. A plain `??` would not: `AGENT_MODEL=` exports an empty string, which
 * is not nullish, so it would sail through and hand the SDK an empty model
 * name. Compose hides this (`${AGENT_MODEL:-default}` substitutes on empty
 * too), but a host-side run does not.
 */
function optional(name: string, fallback: string): string {
  const value = process.env[name];
  return value !== undefined && value.trim() !== "" ? value : fallback;
}

/** Same emptiness rule as `optional`, for settings with no default. */
function optionalOrUndefined(name: string): string | undefined {
  const value = process.env[name];
  return value !== undefined && value.trim() !== "" ? value : undefined;
}

function numeric(name: string, fallback: number): number {
  const raw = optionalOrUndefined(name);
  if (raw === undefined) return fallback;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) {
    throw new Error(`Environment variable ${name} must be a number, got: ${raw}`);
  }
  return parsed;
}

export const config = {
  anthropicBaseUrl: required("ANTHROPIC_BASE_URL"),
  anthropicAuthToken: required("ANTHROPIC_AUTH_TOKEN"),
  model: optional("AGENT_MODEL", "claude-sonnet-4-6"),
  fallbackModel: optionalOrUndefined("AGENT_FALLBACK_MODEL"),
  cwd: optional("AGENT_CWD", "/workspace"),
  permissionMode: optional("AGENT_PERMISSION_MODE", "bypassPermissions") as
    | "default"
    | "acceptEdits"
    | "bypassPermissions"
    | "plan",
  maxTurns: numeric("AGENT_MAX_TURNS", 40),
  verifyTimeoutMs: numeric("VERIFY_TIMEOUT_MS", 120_000),
  verifyMaxOutputChars: numeric("VERIFY_MAX_OUTPUT_CHARS", 4_000),
};
