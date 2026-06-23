function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

export const config = {
  anthropicBaseUrl: required("ANTHROPIC_BASE_URL"),
  anthropicAuthToken: required("ANTHROPIC_AUTH_TOKEN"),
  model: process.env.AGENT_MODEL ?? "claude-sonnet-4-6",
  fallbackModel: process.env.AGENT_FALLBACK_MODEL,
  cwd: process.env.AGENT_CWD ?? "/workspace",
  permissionMode: (process.env.AGENT_PERMISSION_MODE ?? "bypassPermissions") as
    | "default"
    | "acceptEdits"
    | "bypassPermissions"
    | "plan",
  maxTurns: process.env.AGENT_MAX_TURNS ? Number(process.env.AGENT_MAX_TURNS) : 40,
  verifyTimeoutMs: process.env.VERIFY_TIMEOUT_MS ? Number(process.env.VERIFY_TIMEOUT_MS) : 120_000,
  verifyMaxOutputChars: process.env.VERIFY_MAX_OUTPUT_CHARS
    ? Number(process.env.VERIFY_MAX_OUTPUT_CHARS)
    : 4_000,
};
