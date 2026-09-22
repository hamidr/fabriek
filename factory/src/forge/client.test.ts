// The forge as an actor and the executor reach it (ADR-036): issues,
// comments, labels, pull requests, over its API with a token read from a
// file. Driven against a small HTTP server standing in for Forgejo.
import { describe, it, after, before } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server, type IncomingMessage } from "node:http";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ForgeClient } from "./client.js";

interface Seen {
  method: string;
  path: string;
  auth: string | undefined;
  body: unknown;
}

let server: Server;
let base: string;
const seen: Seen[] = [];
let answer: (req: Seen) => [number, unknown] = () => [200, {}];

before(async () => {
  server = createServer((req: IncomingMessage, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      const s: Seen = { method: req.method ?? "", path: req.url ?? "", auth: req.headers.authorization, body: raw ? JSON.parse(raw) : undefined };
      seen.push(s);
      const [status, body] = answer(s);
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const a = server.address();
  base = `http://127.0.0.1:${typeof a === "object" && a ? a.port : 0}/api/v1`;
});
after(() => new Promise<void>((r) => server.close(() => r())));

function client(): ForgeClient {
  const dir = mkdtempSync(join(tmpdir(), "forge-"));
  const tokenFile = join(dir, "token");
  writeFileSync(tokenFile, "tok-123\n");
  return new ForgeClient({ base, owner: "acme-operator", repo: "acme", factory: "acme", tokenFile });
}

describe("a forge client", () => {
  it("sends the token from the file as a header and reads an issue with its labels", async () => {
    answer = () => [200, { number: 7, title: "Do it", body: "how", labels: [{ name: "build" }], assignees: [{ login: "acme-builder" }] }];
    const issue = await client().issue(7);
    assert.deepEqual(issue, { number: 7, title: "Do it", body: "how", labels: ["build"], assignee: "builder" });
    const last = seen.at(-1);
    assert.equal(last?.auth, "token tok-123");
    assert.equal(last?.path, "/api/v1/repos/acme-operator/acme/issues/7");
  });

  it("reads a thread as who said what, oldest first, the owner's words as the executor's and every other login as its bare role", async () => {
    // The executor writes with the operator's token, so the forge shows its
    // comments as the owner's; every reader of a thread looks for the
    // executor by that name. Found on a host: attempts counted zero and a
    // stale outcome was read as fresh, because nothing was ever "executor".
    answer = () => [200, [{ user: { login: "acme-operator" }, body: "brief", created_at: "2026-09-12T10:00:00Z" }, { user: { login: "acme-builder" }, body: "outcome: done", created_at: "2026-09-12T11:00:00Z" }]];
    const thread = await client().thread(7);
    assert.deepEqual(thread, [{ by: "executor", body: "brief" }, { by: "builder", body: "outcome: done" }]);
  });

  it("comments with a body and nothing else", async () => {
    answer = () => [201, { id: 1 }];
    await client().comment(7, "outcome: done\n\nall green");
    const last = seen.at(-1);
    assert.equal(last?.method, "POST");
    assert.equal(last?.path, "/api/v1/repos/acme-operator/acme/issues/7/comments");
    assert.deepEqual(last?.body, { body: "outcome: done\n\nall green" });
  });

  it("finds a role's memory issue by label and by the account the role posts under, and rewrites its body", async () => {
    answer = (r) =>
      r.method === "GET" ? [200, [{ number: 3, body: "old", user: { login: "acme-builder" }, labels: [{ name: "memory" }] }]] : [201, { number: 3 }];
    const c = client();
    const memory = await c.memory("builder");
    assert.deepEqual(memory, { number: 3, body: "old" });
    await c.rewriteMemory(3, "new");
    const last = seen.at(-1);
    assert.equal(last?.method, "PATCH");
    assert.equal(last?.path, "/api/v1/repos/acme-operator/acme/issues/3");
    assert.deepEqual(last?.body, { body: "new" });
  });

  it("finds the issue a role is blocked on by label and assignee, and none when there is none", async () => {
    answer = () => [200, [{ number: 9, assignees: [{ login: "acme-builder" }] }, { number: 4, assignees: [{ login: "acme-reviewer" }] }]];
    assert.equal(await client().blockedOn("builder"), 9);
    assert.equal(await client().blockedOn("tester"), null);
  });

  it("when the forge refuses, the call rejects with the status and the path", async () => {
    answer = () => [403, { message: "no" }];
    await assert.rejects(client().comment(7, "x"), /403.*issues\/7\/comments/);
  });
});
