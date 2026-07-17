#!/usr/bin/env node
import "dotenv/config";
/**
 * stdio entrypoint — for installing the W3Cash MCP server locally into an agent
 * (Claude Code / Cursor / Claude Desktop) that spawns it as a subprocess and
 * talks MCP over stdin/stdout.
 *
 *   node dist/stdio.js            # after `npm run build`
 *   npx @w3cash/mcp               # via the package `bin`
 *
 * ASP target is configurable via ASP_BASE_URL (default https://asp.w3.cash).
 * Nothing is written to stdout except the MCP protocol stream — all logging
 * goes to stderr so it can't corrupt the JSON-RPC framing.
 */

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createMcpServer } from "./tools.js";
import { ASP_BASE_URL } from "./asp.js";
import { SERVER_NAME, SERVER_VERSION } from "./meta.js";

async function main(): Promise<void> {
  const server = createMcpServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(
    `[${SERVER_NAME}@${SERVER_VERSION}] stdio transport ready — proxying ASP ${ASP_BASE_URL}`,
  );
}

main().catch((err: unknown) => {
  console.error(`[${SERVER_NAME}] fatal:`, err);
  process.exit(1);
});
