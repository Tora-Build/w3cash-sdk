#!/usr/bin/env node
import "dotenv/config";
/**
 * HTTP entrypoint — an Express server exposing the MCP Streamable-HTTP transport
 * at POST /mcp, so a remote agent can add the server over the network:
 *
 *   claude mcp add --transport http w3cash https://asp.w3.cash/mcp
 *
 * Designed to sit behind a path-preserving reverse proxy (Caddy) at
 * https://asp.w3.cash/mcp, so the route is /mcp here too. GET /health is a
 * plain reachability probe.
 *
 * Stateless mode: `sessionIdGenerator: undefined` and a fresh McpServer +
 * transport per request. No session state is kept between requests, which is
 * correct for a stateless JSON proxy and safe behind a load-balanced proxy.
 * `enableJsonResponse: true` makes POST /mcp answer with a single JSON body
 * instead of an SSE stream — simpler for proxies and curl checks, and fully
 * compatible with MCP HTTP clients.
 */

import { pathToFileURL } from "node:url";
import express, { type Request, type Response } from "express";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { createMcpServer } from "./tools.js";
import { ASP_BASE_URL } from "./asp.js";
import { SERVER_NAME, SERVER_VERSION } from "./meta.js";

const PORT = Number(process.env.PORT ?? 4100);

/** JSON-RPC error body for methods the stateless transport doesn't serve (GET/DELETE /mcp). */
function methodNotAllowed(res: Response): void {
  res.status(405).set("Allow", "POST").json({
    jsonrpc: "2.0",
    error: { code: -32000, message: "Method not allowed. Use POST for the MCP Streamable HTTP transport." },
    id: null,
  });
}

export function createHttpApp(): express.Express {
  const app = express();
  app.disable("x-powered-by");
  app.use(express.json({ limit: "256kb" }));

  // Reachability probe for the reverse proxy / uptime checks.
  app.get("/health", (_req: Request, res: Response) => {
    res.status(200).json({ ok: true, service: "w3cash-mcp" });
  });

  // MCP Streamable HTTP — one server + transport per request (stateless).
  app.post("/mcp", async (req: Request, res: Response) => {
    const server = createMcpServer();
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });
    res.on("close", () => {
      void transport.close();
      void server.close();
    });
    try {
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
    } catch (err) {
      console.error(`[${SERVER_NAME}] /mcp request failed:`, err);
      if (!res.headersSent) {
        res.status(500).json({
          jsonrpc: "2.0",
          error: { code: -32603, message: "Internal server error" },
          id: null,
        });
      }
    }
  });

  // Stateless mode serves no standalone SSE stream or session teardown.
  app.get("/mcp", (_req: Request, res: Response) => methodNotAllowed(res));
  app.delete("/mcp", (_req: Request, res: Response) => methodNotAllowed(res));

  return app;
}

export function start(port: number = PORT): import("node:http").Server {
  const app = createHttpApp();
  return app.listen(port, () => {
    console.log(
      `[${SERVER_NAME}@${SERVER_VERSION}] HTTP transport on http://localhost:${port}/mcp ` +
        `(health: /health) — proxying ASP ${ASP_BASE_URL}`,
    );
  });
}

// Only listen when run directly (`node dist/http.js`), not when imported by a test.
const isEntrypoint =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href;
if (isEntrypoint) {
  start();
}
