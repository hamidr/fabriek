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
  it("given FABRIEK_SESSION_COMMAND, the words are the argv prefix; without it the machine program is", () => {
    assert.deepEqual(sessionCommand({ FABRIEK_SESSION_COMMAND: "/tmp/session --verbose" }), ["/tmp/session", "--verbose"]);
    assert.deepEqual(sessionCommand({}), ["fabriek-container"]);
    assert.deepEqual(sessionCommand({ FABRIEK_SESSION_COMMAND: "  " }), ["fabriek-container"]);
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

  /** A program that records each start and exits at once. */
  function exiting(dir: string) {
    const starts = join(dir, "starts");
    return { starts, command: ["sh", "-c", `echo start >>"${starts}"`, "session"] };
  }
  const startsIn = (file: string) => (existsSync(file) ? readFileSync(file, "utf8").trim().split("\n").length : 0);

  it("given a session that exits and a restart that is allowed, the session is started again", async () => {
    const { starts, command } = exiting(mkdtempSync(join(tmpdir(), "sessions-")));
    const sessions = new RoleSessions({ factory: "acme", command, restartDelayMs: 10, mayRestart: async () => true });
    await sessions.start("decider");
    for (let i = 0; i < 50 && startsIn(starts) < 2; i++) await settle(20);
    await sessions.stop("decider");
    assert.ok(startsIn(starts) >= 2);
    assert.deepEqual([...sessions.held()], []);
  });

  it("given a session that exits and a restart that is refused, the session is held and not started again", async () => {
    const { starts, command } = exiting(mkdtempSync(join(tmpdir(), "sessions-")));
    const sessions = new RoleSessions({ factory: "acme", command, restartDelayMs: 10, mayRestart: async () => false });
    await sessions.start("decider");
    for (let i = 0; i < 50 && !sessions.held().has("decider"); i++) await settle(20);
    await settle(100);
    assert.equal(startsIn(starts), 1);
    assert.deepEqual([...sessions.held()], ["decider"]);
    await sessions.stop("decider");
  });

  it("given a held session, start begins it again and it is held no longer", async () => {
    const { starts, command } = exiting(mkdtempSync(join(tmpdir(), "sessions-")));
    let allowed = false;
    const sessions = new RoleSessions({ factory: "acme", command, restartDelayMs: 10, mayRestart: async () => allowed });
    await sessions.start("decider");
    for (let i = 0; i < 50 && !sessions.held().has("decider"); i++) await settle(20);
    allowed = true;
    await sessions.start("decider");
    assert.deepEqual([...sessions.held()], []);
    for (let i = 0; i < 50 && startsIn(starts) < 2; i++) await settle(20);
    await sessions.stop("decider");
    assert.ok(startsIn(starts) >= 2);
  });

  it("given a stopped session, its exit asks nothing and holds nothing", async () => {
    const { command } = exiting(mkdtempSync(join(tmpdir(), "sessions-")));
    let asked = 0;
    const sessions = new RoleSessions({ factory: "acme", command, restartDelayMs: 10, mayRestart: async () => { asked++; return false; } });
    await sessions.start("decider");
    await sessions.stop("decider");
    await settle(200);
    assert.equal(asked, 0);
    assert.deepEqual([...sessions.held()], []);
  });

  // Found on a host (2026-09-25): a session's own stop runs after it is
  // signalled, and an executor that exited first let systemd end the unit
  // under it, so a role's cage outlived the executor. stopAll ends every
  // session and waits for each to finish its own stop.
  it("stopAll signals every session and resolves only once each has finished its stop", async () => {
    const dir = mkdtempSync(join(tmpdir(), "sessions-"));
    const done = join(dir, "done");
    const command = ["sh", "-c", `trap 'sleep 0.3; echo "$3" >>"${done}"; exit 0' TERM; while :; do sleep 0.05; done`, "session"];
    const sessions = new RoleSessions({ factory: "acme", command, restartDelayMs: 60000 });
    await sessions.start("builder");
    await sessions.start("reviewer");
    await settle(200);
    await sessions.stopAll(5000);
    assert.deepEqual(readFileSync(done, "utf8").trim().split("\n").sort(), ["builder", "reviewer"]);
    assert.deepEqual([...sessions.running()], []);
  });

  it("stopAll resolves at its bound when a session will not end", async () => {
    const command = ["sh", "-c", "trap '' TERM; while :; do sleep 0.05; done", "session"];
    const sessions = new RoleSessions({ factory: "acme", command, restartDelayMs: 60000 });
    await sessions.start("stuck");
    await settle(100);
    const t0 = Date.now();
    await sessions.stopAll(300);
    assert.ok(Date.now() - t0 < 2000);
  });
});
