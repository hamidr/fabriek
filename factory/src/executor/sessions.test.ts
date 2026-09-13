// A role's session is one process the executor starts, and the line it starts
// is the machine program's; what a harness may substitute is the program, never
// the line.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RoleSessions, sessionCommand } from "./sessions.js";

const settle = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe("role sessions", () => {
  it("given CAGEWORKS_SESSION_COMMAND, the words are the argv prefix; without it the machine program is", () => {
    assert.deepEqual(sessionCommand({ CAGEWORKS_SESSION_COMMAND: "/tmp/session --verbose" }), ["/tmp/session", "--verbose"]);
    assert.deepEqual(sessionCommand({}), ["cageworks-container"]);
    assert.deepEqual(sessionCommand({ CAGEWORKS_SESSION_COMMAND: "  " }), ["cageworks-container"]);
  });

  it("given a substituted program, a session is started with it and the same role-enter line the machine would get", async () => {
    const dir = mkdtempSync(join(tmpdir(), "sessions-"));
    const argv = join(dir, "argv");
    const sessions = new RoleSessions({ factory: "acme", command: ["sh", "-c", `printf '%s\\n' "$@" >"${argv}"`, "session"], restartDelayMs: 60000 });
    await sessions.start("builder");
    for (let i = 0; i < 50 && !existsSync(argv); i++) await settle(20);
    assert.deepEqual(readFileSync(argv, "utf8").trim().split("\n"), ["role-enter", "--signing-key", "builder", "acme", "builder"]);
    await sessions.stop("builder");
  });
});
