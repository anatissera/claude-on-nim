/**
 * Outcome of the startup proxy probe. The variants exist so the caller can
 * tell the operator which thing to go fix, rather than just "not reachable".
 */
export type ProxyProbeResult =
  | { ok: true }
  | { ok: false; reason: "invalid-url"; detail: string }
  | { ok: false; reason: "unreachable"; detail: string }
  | { ok: false; reason: "unauthorized"; status: number }
  | { ok: false; reason: "unhealthy"; status: number };

/**
 * Checks that the proxy is up AND that our auth token is accepted, by asking
 * it to list models.
 *
 * `/v1/models` is deliberate: both LiteLLM and CLIProxyAPI serve it, and it is
 * authenticated, so a wrong ANTHROPIC_AUTH_TOKEN fails here instead of on the
 * first real turn. A health endpoint would not catch that -- and the paths
 * differ between the two proxies anyway (`/health/liveliness` vs `/healthz`).
 *
 * What this still cannot catch is an invalid upstream NIM key: the proxy
 * answers happily and only the first inference request fails. That is a
 * per-request condition, not a startup one.
 */
export async function probeProxy(
  baseUrl: string,
  authToken: string,
  timeoutMs = 5000,
): Promise<ProxyProbeResult> {
  let url: string;
  try {
    url = new URL("/v1/models", baseUrl).toString();
  } catch {
    return { ok: false, reason: "invalid-url", detail: baseUrl };
  }

  let response: Response;
  try {
    response = await fetch(url, {
      headers: { authorization: `Bearer ${authToken}` },
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (error) {
    // Connection refused, DNS failure, or the timeout firing.
    return {
      ok: false,
      reason: "unreachable",
      detail: error instanceof Error ? error.message : String(error),
    };
  }

  if (response.status === 401 || response.status === 403) {
    return { ok: false, reason: "unauthorized", status: response.status };
  }
  if (!response.ok) {
    return { ok: false, reason: "unhealthy", status: response.status };
  }
  return { ok: true };
}

/** Operator-facing explanation of a failed probe, including what to check. */
export function describeProbeFailure(
  result: Extract<ProxyProbeResult, { ok: false }>,
  baseUrl: string,
): string {
  switch (result.reason) {
    case "invalid-url":
      return `ANTHROPIC_BASE_URL is not a valid URL: ${result.detail}`;
    case "unreachable":
      return (
        `Proxy at ${baseUrl} is not reachable (${result.detail}). ` +
        `Check that it is up: docker compose ps`
      );
    case "unauthorized":
      return (
        `Proxy at ${baseUrl} rejected our credentials (HTTP ${result.status}). ` +
        `Check that ANTHROPIC_AUTH_TOKEN matches the proxy's configured key.`
      );
    case "unhealthy":
      return (
        `Proxy at ${baseUrl} answered HTTP ${result.status} when listing models. ` +
        `Check its logs: docker compose logs`
      );
  }
}
