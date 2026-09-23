import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * config.ts builds its export at module load, so every case here has to reset
 * the module registry and re-import with a fresh environment.
 */
async function loadConfig(env: Record<string, string | undefined>) {
  vi.resetModules();
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) vi.stubEnv(key, "");
    else vi.stubEnv(key, value);
  }
  const module = await import("./config.js");
  return module.config;
}

const MINIMAL = {
  ANTHROPIC_BASE_URL: "http://cliproxy:8317",
  ANTHROPIC_AUTH_TOKEN: "sk-test",
};

beforeEach(() => {
  // Start every case from a clean slate so a stray host env var cannot make a
  // "default" assertion pass for the wrong reason.
  for (const key of [
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "AGENT_MODEL",
    "AGENT_FALLBACK_MODEL",
    "AGENT_CWD",
    "AGENT_PERMISSION_MODE",
    "AGENT_MAX_TURNS",
    "VERIFY_TIMEOUT_MS",
    "VERIFY_MAX_OUTPUT_CHARS",
  ]) {
    vi.stubEnv(key, "");
  }
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

describe("required environment variables", () => {
  it("throws when ANTHROPIC_BASE_URL is missing", async () => {
    await expect(loadConfig({ ANTHROPIC_AUTH_TOKEN: "sk-test" })).rejects.toThrow(
      /ANTHROPIC_BASE_URL/,
    );
  });

  it("throws when ANTHROPIC_AUTH_TOKEN is missing", async () => {
    await expect(loadConfig({ ANTHROPIC_BASE_URL: "http://x" })).rejects.toThrow(
      /ANTHROPIC_AUTH_TOKEN/,
    );
  });

  it("treats an empty string as missing, not as a valid value", async () => {
    await expect(
      loadConfig({ ANTHROPIC_BASE_URL: "http://x", ANTHROPIC_AUTH_TOKEN: "" }),
    ).rejects.toThrow(/ANTHROPIC_AUTH_TOKEN/);
  });

  it("loads once both are present", async () => {
    const config = await loadConfig(MINIMAL);
    expect(config.anthropicBaseUrl).toBe("http://cliproxy:8317");
    expect(config.anthropicAuthToken).toBe("sk-test");
  });
});

describe("defaults", () => {
  it("defaults the model to the primary tier alias", async () => {
    const config = await loadConfig(MINIMAL);
    expect(config.model).toBe("claude-sonnet-4-6");
  });

  it("leaves the fallback model unset when not configured", async () => {
    const config = await loadConfig(MINIMAL);
    expect(config.fallbackModel).toBeFalsy();
  });

  it("defaults cwd to the container's mounted workspace", async () => {
    const config = await loadConfig(MINIMAL);
    expect(config.cwd).toBe("/workspace");
  });

  it("defaults maxTurns, verify timeout and output cap", async () => {
    const config = await loadConfig(MINIMAL);
    expect(config.maxTurns).toBe(40);
    expect(config.verifyTimeoutMs).toBe(120_000);
    expect(config.verifyMaxOutputChars).toBe(4_000);
  });

  it("defaults the permission mode to bypassPermissions", async () => {
    // The headless agent is expected to run unattended; the guard hook, not
    // the permission mode, is what actually contains it.
    const config = await loadConfig(MINIMAL);
    expect(config.permissionMode).toBe("bypassPermissions");
  });
});

describe("overrides", () => {
  it("takes the model and fallback from the environment", async () => {
    const config = await loadConfig({
      ...MINIMAL,
      AGENT_MODEL: "glm",
      AGENT_FALLBACK_MODEL: "glm-flash",
    });
    expect(config.model).toBe("glm");
    expect(config.fallbackModel).toBe("glm-flash");
  });

  it("takes cwd and permission mode from the environment", async () => {
    const config = await loadConfig({
      ...MINIMAL,
      AGENT_CWD: "/srv/repo",
      AGENT_PERMISSION_MODE: "acceptEdits",
    });
    expect(config.cwd).toBe("/srv/repo");
    expect(config.permissionMode).toBe("acceptEdits");
  });

  it("parses numeric settings", async () => {
    const config = await loadConfig({
      ...MINIMAL,
      AGENT_MAX_TURNS: "7",
      VERIFY_TIMEOUT_MS: "5000",
      VERIFY_MAX_OUTPUT_CHARS: "250",
    });
    expect(config.maxTurns).toBe(7);
    expect(config.verifyTimeoutMs).toBe(5_000);
    expect(config.verifyMaxOutputChars).toBe(250);
  });

  it("accepts zero rather than silently falling back to the default", async () => {
    const config = await loadConfig({ ...MINIMAL, AGENT_MAX_TURNS: "0" });
    // "0" is truthy as a string, so the ?? guard keeps it -- worth pinning,
    // since a `||` there would have turned an explicit 0 into 40.
    expect(config.maxTurns).toBe(0);
  });

  it("rejects a non-numeric override loudly instead of yielding NaN", async () => {
    // A typo used to become NaN and travel downstream into the SDK options,
    // where it is much harder to trace back to the .env line that caused it.
    await expect(loadConfig({ ...MINIMAL, AGENT_MAX_TURNS: "lots" })).rejects.toThrow(
      /AGENT_MAX_TURNS must be a number/,
    );
  });

  it("names the offending variable when a timeout is non-numeric", async () => {
    await expect(loadConfig({ ...MINIMAL, VERIFY_TIMEOUT_MS: "2 minutes" })).rejects.toThrow(
      /VERIFY_TIMEOUT_MS/,
    );
  });

  it("treats an empty optional override as unset rather than as a value", async () => {
    // The bug this pins: `??` only falls back on null/undefined, so an
    // exported-but-empty AGENT_MODEL used to reach the SDK as "".
    const config = await loadConfig({ ...MINIMAL, AGENT_MODEL: "", AGENT_CWD: "   " });
    expect(config.model).toBe("claude-sonnet-4-6");
    expect(config.cwd).toBe("/workspace");
  });
});
