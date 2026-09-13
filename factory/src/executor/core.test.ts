// The executor (ADR-034): uncaged, holds every credential, decides nothing.
// It writes the board, sends work, validates every verb against the
// declaration, and judges an outcome by what is checkable. Driven against
// fakes for the board, the bus, the sessions, git and the proxy's count, so
// what is asserted is the protocol (ADR-033 point 4) and the refusals
// (ADR-034 point 3), including the cases the withdrawn routing model owed:
// a crash between the board write and the send, a stall, and a liar at
// reconciliation.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Executor, type Board, type BoardIssue, type Bus, type Git, type Sessions, type Spend } from "./core.js";
import { readDeclaration } from "../declaration.js";
import type { Message } from "../messages.js";

const declaration = readDeclaration(
  JSON.stringify({
    name: "acme",
    roles: {
      builder: { command: ["pi"], provides: ["build", "test"] },
      reviewer: { command: ["pi"], provides: ["review"] },
    },
    workflows: { ship: { stages: [{ needs: "build" }, { needs: "test" }, { needs: "review" }] } },
    resources: { taskAttempts: 2, tokens: 1000 },
  }),
);

function fakes() {
  const issues = new Map<number, BoardIssue>();
  let next = 1;
  const log: string[] = [];
  const board: Board = {
    async open() { return [...issues.values()].filter((i) => i.state === "open"); },
    async issue(n) { const i = issues.get(n); if (!i) throw new Error(`no issue ${n}`); return i; },
    async create(title, body, stage) {
      const n = next++;
      issues.set(n, { number: n, title, body, state: "open", labels: [stage], assignee: null, thread: [] });
      log.push(`create:${n}:${stage}`);
      return n;
    },
    async setLabels(n, labels) { issues.get(n)!.labels = [...labels]; log.push(`labels:${n}:${[...labels].sort().join(",")}`); },
    async assign(n, role) { issues.get(n)!.assignee = role; log.push(`assign:${n}:${role ?? "-"}`); },
    async comment(n, body) { issues.get(n)!.thread.push({ by: "executor", body }); log.push(`comment:${n}:${body.split("\n")[0]}`); },
    async close(n) { issues.get(n)!.state = "closed"; log.push(`close:${n}`); },
    async openPullRequest(branch, title) { log.push(`pr:${branch}:${title}`); return 1; },
  };
  const sent: { role: string; message: Message }[] = [];
  const bus: Bus & { inbox: Message[] } = {
    inbox: [],
    async send(role, message) { sent.push({ role, message }); log.push(`send:${role}:${message.kind}`); },
  };
  const started: string[] = [];
  const stopped: string[] = [];
  const sessions: Sessions = {
    async start(role) { started.push(role); },
    async stop(role) { stopped.push(role); },
    running: () => new Set(started),
  };
  let commits = 1;
  let tips = 0;
  const git: Git = {
    async tip() { return `tip${tips++}`; },
    async commitsSince() { return commits; },
    async push(branch) { log.push(`push:${branch}`); },
    async mirror() { log.push("mirror"); },
  };
  let total = 0;
  const spend: Spend = { async total() { return total; } };
  const roleComment = (n: number, by: string, body: string) => issues.get(n)!.thread.push({ by, body });
  return { board, bus, sessions, git, spend, issues, log, sent, started, stopped, roleComment, setCommits: (v: number) => (commits = v), setTotal: (v: number) => (total = v) };
}

async function executor(f = fakes()) {
  const x = new Executor({ declaration, workflow: "ship", ...f, reconcileTimeoutMs: 10 });
  return { x, f };
}

describe("the executor", () => {
  it("given a filed goal, it opens an issue at the workflow's first stage and nothing else", async () => {
    const { x, f } = await executor();
    const r = await x.apply({ verb: "file", titleFile: "/t", bodyFile: "/b", stage: "build" }, { readFile: async (p) => (p === "/t" ? "Add importer" : "handle empty files") });
    assert.equal(r.ok, true);
    assert.deepEqual(f.log, ["create:1:build"]);
    assert.equal(f.issues.get(1)?.title, "Add importer");
  });

  it("file at a stage the workflow lacks is refused by name", async () => {
    const { x } = await executor();
    const r = await x.apply({ verb: "file", titleFile: "/t", bodyFile: "/b", stage: "deploy" }, { readFile: async () => "x" });
    assert.equal(r.ok, false);
    assert.match(r.ok ? "" : r.reason, /deploy/);
  });

  it("assign writes assigning to the board before it sends, and assigned only on the ack", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    const r = await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.equal(r.ok, true);
    const i = f.log.indexOf("labels:1:assigning,build");
    const s = f.log.indexOf("send:builder:assignment");
    assert.ok(i >= 0 && s > i, `board before send: ${f.log.join(" ")}`);
    assert.deepEqual(f.sent[0]?.message, { kind: "assignment", issue: 1, attempt: 1 });
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigning", "build"]);
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigned", "build"]);
    assert.equal(f.issues.get(1)?.assignee, "builder");
  });

  it("assign is refused for a role that does not exist, does not provide the stage, is not ready, or holds work", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    await f.board.create("t2", "b", "build");
    let r = await x.apply({ verb: "assign", issue: 1, role: "ghost" });
    assert.match(r.ok ? "" : r.reason, /ghost/);
    r = await x.apply({ verb: "assign", issue: 1, role: "reviewer" });
    assert.match(r.ok ? "" : r.reason, /reviewer.*build/);
    r = await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.match(r.ok ? "" : r.reason, /not ready/);
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    r = await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.equal(r.ok, true);
    r = await x.apply({ verb: "assign", issue: 2, role: "builder" });
    assert.match(r.ok ? "" : r.reason, /holds/);
  });

  it("assign is refused past the declared attempts, and a retry names the same role", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    f.issues.get(1)!.assignee = "builder";
    f.roleComment(1, "executor", "attempt 1 started for builder at build (branch at none)");
    f.roleComment(1, "executor", "attempt 2 started for builder at build (branch at none)");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    const r = await x.apply({ verb: "retry", issue: 1 });
    assert.match(r.ok ? "" : r.reason, /attempts/);
  });

  it("retry goes back to the role that had the task, with the previous outcome in the brief", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    f.issues.get(1)!.assignee = "builder";
    f.roleComment(1, "executor", "attempt 1 started for builder at build (branch at none)");
    f.roleComment(1, "builder", "outcome: failed\n\nthe tests would not compile");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    const r = await x.apply({ verb: "retry", issue: 1 });
    assert.equal(r.ok, true);
    assert.deepEqual(f.sent[0]?.message, { kind: "assignment", issue: 1, attempt: 2 });
    const brief = f.issues.get(1)?.thread.at(-1)?.body ?? "";
    assert.match(brief, /attempt 2 started for builder/);
    assert.match(brief, /the tests would not compile/);
  });

  it("when the actor never acks, the row stays assigning and the role is not free for another task", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    await f.board.create("t2", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    await x.settle();
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigning", "build"]);
    const r = await x.apply({ verb: "assign", issue: 2, role: "builder" });
    assert.equal(r.ok, false);
  });

  it("on start it reconciles: an assigning row an actor says it holds becomes assigned; one nobody holds is released", async () => {
    const f = fakes();
    await f.board.create("t", "b", "build");
    await f.board.create("t2", "b", "build");
    f.issues.get(1)!.labels = ["build", "assigning"]; f.issues.get(1)!.assignee = "builder";
    f.issues.get(2)!.labels = ["build", "assigning"]; f.issues.get(2)!.assignee = "reviewer";
    const x = new Executor({ declaration, workflow: "ship", ...f, reconcileTimeoutMs: 10 });
    const done = x.reconcile();
    x.heard("builder", { kind: "held", issues: [1] });
    x.heard("reviewer", { kind: "held", issues: [] });
    await done;
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigned", "build"]);
    assert.deepEqual(f.issues.get(2)?.labels.sort(), ["build"]);
    assert.equal(f.issues.get(2)?.assignee, null);
    assert.ok(f.sent.every((s) => s.message.kind === "reconcile"));
  });

  it("at reconciliation a liar cannot take a task: an answer never creates an assignment", async () => {
    const f = fakes();
    await f.board.create("t", "b", "build");
    const x = new Executor({ declaration, workflow: "ship", ...f, reconcileTimeoutMs: 10 });
    const done = x.reconcile();
    x.heard("builder", { kind: "held", issues: [1] });
    await done;
    assert.deepEqual(f.issues.get(1)?.labels, ["build"]);
    assert.equal(f.issues.get(1)?.assignee, null);
  });

  it("an actor that does not answer reconciliation is unknown: its assigning row stays and nothing is routed to it", async () => {
    const f = fakes();
    await f.board.create("t", "b", "build");
    f.issues.get(1)!.labels = ["build", "assigning"]; f.issues.get(1)!.assignee = "builder";
    const x = new Executor({ declaration, workflow: "ship", ...f, reconcileTimeoutMs: 10 });
    await x.reconcile();
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigning", "build"]);
    x.heard("builder", { kind: "ready", capabilities: ["build"] });
    await f.board.create("t2", "b", "build");
    const r = await x.apply({ verb: "assign", issue: 2, role: "builder" });
    assert.equal(r.ok, false);
  });

  it("a done outcome with a signed commit on the role's branch moves the issue to the next stage and frees the role", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "builder", "outcome: done\n\nall green");
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(1)?.labels, ["test"]);
    assert.equal(f.issues.get(1)?.assignee, null);
  });

  it("a done outcome without a commit is not done: the issue stays at its stage, unassigned, and the thread says why", async () => {
    const { x, f } = await executor();
    f.setCommits(0);
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "builder", "outcome: done\n\nall green");
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(1)?.labels, ["build"]);
    assert.match(f.issues.get(1)?.thread.at(-1)?.body ?? "", /no commit/);
  });

  it("the attempt comment records the branch's tip, and a done with no commit after it is not done even if earlier tasks left commits", async () => {
    const { x, f } = await executor();
    await f.board.create("first", "b", "build");
    await f.board.create("second", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.match(f.issues.get(1)?.thread[0]?.body ?? "", /^attempt 1 started for builder at build \(branch at tip0\)$/);
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "builder", "outcome: done\n\nfirst task");
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(1)?.labels, ["test"]);
    // The branch now carries the first task's commit; the second adds none.
    f.setCommits(0);
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 2, role: "builder" });
    assert.match(f.issues.get(2)?.thread[0]?.body ?? "", /\(branch at tip1\)$/);
    x.heard("builder", { kind: "ack", issue: 2 });
    await x.settle();
    f.roleComment(2, "builder", "outcome: done\n\nnothing new");
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(2)?.labels, ["build"]);
    assert.equal(f.issues.get(2)?.assignee, null);
  });

  it("attempts are counted per stage: a task that used its budget at build still has it at test, and the reviewer's first attempt is attempt 1", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    for (const attempt of [1, 2]) {
      x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
      assert.deepEqual(await x.apply({ verb: "assign", issue: 1, role: "builder" }), { ok: true });
      x.heard("builder", { kind: "ack", issue: 1 });
      await x.settle();
      f.roleComment(1, "builder", attempt === 1 ? "outcome: failed\n\nno" : "outcome: done\n\nyes");
      await x.checkOutcomes();
    }
    assert.deepEqual(f.issues.get(1)?.labels, ["test"]);
    // The same role serves the next stage, and its budget there is untouched.
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    assert.deepEqual(await x.apply({ verb: "assign", issue: 1, role: "builder" }), { ok: true });
    assert.match(f.issues.get(1)?.thread.at(-1)?.body ?? "", /^attempt 1 started for builder at test/);
  });

  it("a done outcome at the last stage closes the issue", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "review");
    x.heard("reviewer", { kind: "ready", capabilities: ["review"] });
    await x.apply({ verb: "assign", issue: 1, role: "reviewer" });
    x.heard("reviewer", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "reviewer", "outcome: done\n\nlgtm");
    await x.checkOutcomes();
    assert.equal(f.issues.get(1)?.state, "closed");
  });

  it("a blocked outcome labels the issue blocked and the role keeps it", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "builder", "outcome: blocked\n\nneeds the schema");
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigned", "blocked", "build"]);
    assert.equal(f.issues.get(1)?.assignee, "builder");
  });

  it("a failed outcome frees the role and leaves the issue for the decider to retry", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "builder", "outcome: failed\n\nno");
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(1)?.labels, ["build"]);
    assert.equal(f.issues.get(1)?.assignee, "builder");
  });

  it("block labels the issue and says what it waits on, and refuses an issue that does not exist", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    await f.board.create("t2", "b", "build");
    let r = await x.apply({ verb: "block", issue: 1, on: 2 });
    assert.equal(r.ok, true);
    assert.ok(f.issues.get(1)?.labels.includes("blocked"));
    assert.match(f.issues.get(1)?.thread.at(-1)?.body ?? "", /#2/);
    r = await x.apply({ verb: "block", issue: 1, on: 9 });
    assert.equal(r.ok, false);
  });

  it("push pushes only the role's own namespace and opens one pull request for it", async () => {
    const { x, f } = await executor();
    const r = await x.apply({ verb: "push", role: "builder" });
    assert.equal(r.ok, true);
    assert.deepEqual(f.log, ["push:builder/work", "pr:builder/work:builder/work"]);
    const bad = await x.apply({ verb: "push", role: "ghost" });
    assert.equal(bad.ok, false);
  });

  it("stop sends an abort to the role and keeps its assignment", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    const r = await x.apply({ verb: "stop", role: "builder" });
    assert.equal(r.ok, true);
    assert.deepEqual(f.sent.at(-1)?.message, { kind: "abort" });
    assert.equal(f.issues.get(1)?.assignee, "builder");
  });

  it("at the soft limit, assign is refused and running work is left to finish", async () => {
    const { x, f } = await executor();
    f.setTotal(950);
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    const r = await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.match(r.ok ? "" : r.reason, /soft limit/);
    assert.equal(x.routing(), false);
  });

  it("mirror pushes main and the record together", async () => {
    const { x, f } = await executor();
    await x.mirror();
    assert.deepEqual(f.log, ["mirror"]);
  });
});
