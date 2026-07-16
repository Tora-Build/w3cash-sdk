/**
 * The W3Cash usage skill (SKILL.md), served as an MCP resource so `claude mcp add`
 * delivers the tools AND their how-to guide in one step. Read once at module load
 * from the package-root SKILL.md (co-located with this package); falls back to a
 * pointer if the file isn't present at runtime.
 */
import { readFileSync } from "node:fs";

let content: string;
try {
  // dist/skill.js -> ../SKILL.md is the package-root SKILL.md shipped with the MCP.
  content = readFileSync(new URL("../SKILL.md", import.meta.url), "utf8");
} catch {
  content =
    "# W3Cash Intent Compiler\n\nUsage skill unavailable at runtime. " +
    "Discover capabilities live at https://asp.w3.cash/capabilities and " +
    "call the `w3cash_*` tools (they are self-describing).";
}

export const SKILL_MD = content;
export const SKILL_URI = "w3cash://skill";
