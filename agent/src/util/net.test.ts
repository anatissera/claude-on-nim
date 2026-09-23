import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { describeProbeFailure, probeProxy } from "./net.js";

let server: Server | undefined;

/** Starts a throwaway HTTP server and returns its base URL. */
async function serve(handler: (path: string, auth: string | undefined) => { status: number; body?: string }): Promise<string> {
  server = createServer((req, res) => {
    const { status, body } = handler(req.url ?? "", req.headers.authorization);
    res.writeHead(status, { "content-type": "application/json" });
    res.end(body ?? "{}");
  });
  await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  return `http://127.0.0.1:${port}`;
}

afterEach(async () => {
  if (server) {
    await new Promise<void>((resolve) => server!.close(() => resolve()));
    server = undefined;
  }
});

describe("probeProxy", () => {
  it("succeeds when the proxy lists models", async () => {
    const baseUrl = await serve(() => ({ status: 200, body: '{"data":[]}' }));
    await expect(probeProxy(baseUrl, "token")).resolves.toEqual({ ok: true });
  });

  it("queries /v1/models and forwards the auth token", async () => {
    let seenPath = "";
    let seenAuth: string | undefined;
    const baseUrl = await serve((path, auth) => {
      seenPath = path;
      seenAuth = auth;
      return { status: 200 };
    });

    await probeProxy(baseUrl, "sk-secret");

    expect(seenPath).toBe("/v1/models");
    expect(seenAuth).toBe("Bearer sk-secret");
  });

  it("reports a bad token as unauthorized rather than unreachable", async () => {
    // The whole point of probing an authenticated endpoint: a wrong
    // ANTHROPIC_AUTH_TOKEN must fail here, not on the first inference turn.
    const baseUrl = await serve((_path, auth) =>
      auth === "Bearer right" ? { status: 200 } : { status: 401 },
    );

    await expect(probeProxy(baseUrl, "wrong")).resolves.toEqual({
      ok: false,
      reason: "unauthorized",
      status: 401,
    });
    await expect(probeProxy(baseUrl, "right")).resolves.toEqual({ ok: true });
  });

  it("treats 403 as unauthorized too", async () => {
    const baseUrl = await serve(() => ({ status: 403 }));
    await expect(probeProxy(baseUrl, "token")).resolves.toMatchObject({
      reason: "unauthorized",
      status: 403,
    });
  });

  it("reports a server error as unhealthy", async () => {
    const baseUrl = await serve(() => ({ status: 502 }));
    await expect(probeProxy(baseUrl, "token")).resolves.toMatchObject({
      ok: false,
      reason: "unhealthy",
      status: 502,
    });
  });

  it("reports a closed port as unreachable", async () => {
    // Bind and immediately release a port, so nothing is listening on it.
    const baseUrl = await serve(() => ({ status: 200 }));
    await new Promise<void>((resolve) => server!.close(() => resolve()));
    server = undefined;

    await expect(probeProxy(baseUrl, "token", 2000)).resolves.toMatchObject({
      ok: false,
      reason: "unreachable",
    });
  });

  it("rejects a malformed base URL without throwing", async () => {
    await expect(probeProxy("not-a-url", "token")).resolves.toMatchObject({
      ok: false,
      reason: "invalid-url",
    });
  });
});

describe("describeProbeFailure", () => {
  it("points at the auth token when the proxy rejects credentials", () => {
    const message = describeProbeFailure(
      { ok: false, reason: "unauthorized", status: 401 },
      "http://proxy:4000",
    );
    expect(message).toContain("ANTHROPIC_AUTH_TOKEN");
    expect(message).toContain("401");
  });

  it("points at the container when the proxy is down", () => {
    const message = describeProbeFailure(
      { ok: false, reason: "unreachable", detail: "ECONNREFUSED" },
      "http://proxy:4000",
    );
    expect(message).toContain("docker compose ps");
    expect(message).toContain("ECONNREFUSED");
  });

  it("points at the logs when the proxy answers badly", () => {
    const message = describeProbeFailure(
      { ok: false, reason: "unhealthy", status: 502 },
      "http://proxy:4000",
    );
    expect(message).toContain("docker compose logs");
  });
});
