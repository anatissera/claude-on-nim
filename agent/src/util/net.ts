import { connect } from "node:net";

/** True if a TCP connection to host:port succeeds within timeoutMs. */
export function tcpReachable(host: string, port: number, timeoutMs = 3000): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect({ host, port });
    const fail = () => {
      socket.destroy();
      resolve(false);
    };
    const timer = setTimeout(fail, timeoutMs);
    socket.once("connect", () => {
      clearTimeout(timer);
      socket.destroy();
      resolve(true);
    });
    socket.once("error", () => {
      clearTimeout(timer);
      fail();
    });
  });
}

/** Checks that `url`'s host:port accepts TCP connections. Returns null if `url` isn't a valid URL. */
export async function urlReachable(url: string, timeoutMs = 3000): Promise<boolean | null> {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  const port = parsed.port ? Number(parsed.port) : parsed.protocol === "https:" ? 443 : 80;
  return tcpReachable(parsed.hostname, port, timeoutMs);
}
